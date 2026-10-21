//! The daemon's end of the Control session (vsock 6000): the Hello gate, the
//! protocol version it settles, request ids and reply pairing, the keepalive,
//! and one inbound sink for everything a guest says unsolicited. The
//! semantics are the Mac's ControlSession.swift
//! (host/AvoKit/Sources/AvoDaemonCore), with its actor/waiting-Task shape
//! replaced by three std threads: the caller's, a reader that lives on the
//! transport until the session does, and the keepalive (`startKeepalive`
//! there) — one Ping every period, the miss limit at three unanswered in a
//! row ending the session, with no goodbye written on that death: only the
//! session's own `close` ever says goodbye, and the wire simply ends.

use std::collections::HashMap;
use std::io::ErrorKind;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::control::{envelope_of, read_envelope, write_envelope};
use crate::proto::{envelope, goodbye, Envelope, Goodbye, Hello, Ping, Pong, PROTOCOL_MIN_VERSION, PROTOCOL_VERSION};
use crate::vsock::VsockStream;

/// How long the guest has to answer the opening Hello. ControlSession.swift
/// takes `.seconds(10)` as `start`'s default; waiting forever on a bridge
/// that never came up would hang the daemon's boot instead of failing it.
pub const HELLO_TIMEOUT: Duration = Duration::from_secs(10);

/// Default wait for a request that passes no timeout. ControlSession.swift's
/// `request` takes `.seconds(30)` the same way.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// The keepalive's clocks, ControlSession.swift's `startKeepalive` numbers
/// straight: a Ping every `period` (the task sleeps `.seconds(5)` before its
/// first ping and between the rest, so the first one rides the period too),
/// each ping given `window` to be answered — what a miss is; the Swift's
/// per-ping `request` timeout is `.seconds(5)`, the same number as its
/// period — and the session ends on the `miss_limit`-th miss in a row (the
/// Swift counts with `misses >= 3`). `open` runs these; tests build one with
/// faster clocks.
struct Keepalive {
    period: Duration,
    window: Duration,
    miss_limit: u32,
}

impl Default for Keepalive {
    fn default() -> Self {
        Keepalive {
            period: Duration::from_secs(5),
            window: Duration::from_secs(5),
            miss_limit: 3,
        }
    }
}

/// What a session's calls can fail with. `Closed` covers both an explicit
/// `close` and a transport that died mid-anything; `Protocol` is the wire
/// breaking its own shape — the `control` module reports those as
/// `ErrorKind::InvalidData` (oversized frame, undecodable envelope) and they
/// map here with their wording intact.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionError {
    Closed,
    TimedOut,
    Protocol(String),
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SessionError::Closed => out.write_str("the control session is closed"),
            SessionError::TimedOut => out.write_str("the control session timed out"),
            SessionError::Protocol(what) => write!(out, "the control session's wire misbehaved: {what}"),
        }
    }
}

impl std::error::Error for SessionError {}

/// One request's reply slot. The reader posts the reply envelope in, or a
/// `SessionError` when the session ended before the answer did; the
/// requester polls it with a deadline in hand instead of per-request
/// timers, so there is nothing to cancel.
type Slot = mpsc::Sender<Result<Envelope, SessionError>>;

/// The session's shared side: what the reader thread and the session's
/// owner both reach. Field comments double as the concurrency contract.
struct Actor {
    /// The transport's write half. Reads belong to the reader thread's own
    /// handle, so every write — request, pong, goodbye — locks here to stay
    /// whole frames.
    writer: Mutex<UnixStream>,
    /// Reply slots by request id — the Swift session's `pending` map.
    /// Entries leave on delivery, timeout or shutdown, which is also why a
    /// late reply finds nothing: ids are never reused before their slot is
    /// gone (ControlSession.swift removes on every exit path the same way).
    pending: Mutex<HashMap<u64, Slot>>,
    /// Requester-owned ids, up-counting from 1. Envelope.request_id's doc in
    /// proto.rs: unique per connection and direction.
    next_request_id: AtomicU64,
    /// Set once the session ends. Past it, re-issues fail cold instead of
    /// writing anywhere, the reader's replies stop being looked for, and
    /// only the one transition wins the goodbye.
    closed: AtomicBool,
    /// Where the guest's unsolicited envelopes go — the Swift session
    /// creates its event stream at init (`AsyncStream.makeStream`) and hands
    /// out only the consume side (`events`); this picks the same shape with
    /// a channel: the session owns the sending end at `open`, the daemon's
    /// event loop takes `events()`'s receiving end wherever it runs. A bound
    /// callback (`Box<dyn FnMut(Envelope) + Send>`) would invert that: the
    /// reader thread would run the handler, and a slow handler would slow
    /// every reply in front of it.
    sink: mpsc::Sender<Envelope>,
}

impl Actor {
    /// One envelope onto the wire, the id in its header, whatever the closed
    /// flag says — the flag's check belongs to the caller (close()'s goodbye
    /// writes after it set the flag itself).
    fn enqueue(&self, request_id: u64, payload: envelope::Payload) -> Result<(), SessionError> {
        let mut out = envelope_of(payload);
        out.request_id = request_id;
        let mut writer = self.writer.lock().expect("the writer mutex is never poisoned");
        write_envelope(&mut *writer, &out).map_err(|error| wire_error(&error))
    }

    /// `enqueue` for everyone else: past close, nothing else belongs on the
    /// wire, so requests and pongs stop cold with `Closed`.
    fn post(&self, request_id: u64, payload: envelope::Payload) -> Result<(), SessionError> {
        if self.closed.load(Ordering::SeqCst) {
            return Err(SessionError::Closed);
        }
        self.enqueue(request_id, payload)
    }

    /// Ends the session: flags it, then wakes every waiter with `Closed`.
    /// ControlSession.swift's `close(error:)` resumes its continuations in
    /// one pass; the flag swap makes the second caller a no-op, since the
    /// first one took the waiting slots already.
    fn mark_dead(&self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        self.drain();
    }

    /// Just the waiting slots, without touching the flag — close() sets it
    /// itself so its goodbye write runs between the two.
    fn drain(&self) {
        let mut pending = self.pending.lock().expect("the pending mutex is never poisoned");
        for (_, slot) in pending.drain() {
            let _ = slot.send(Err(SessionError::Closed));
        }
    }

    /// Ends a session the keepalive's way — the death ControlSession.swift's
    /// `startKeepalive` reaches with `close(error: guestUnavailable)`: the
    /// flag goes down, every waiter wakes with `Closed`, and the wire shuts
    /// with no goodbye written. That is the Swift's shape too — only the
    /// negotiation's refusal writes a goodbye there; a keepalive death lets
    /// the guest read the stream's end bare. The reader thread's blocked
    /// read comes back off the shutdown and it ends behind the same flag.
    fn sever(&self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Ok(writer) = self.writer.lock() {
            let _ = writer.shutdown(Shutdown::Both);
        }
        self.drain();
    }

    /// The session's `request`, thread-side: the keepalive sends its pings
    /// through the very same ids, pending slots and deadline waits the
    /// caller's requests use — ControlSession.swift's `startKeepalive`
    /// calls its own `request` there too, so one miss reads exactly like
    /// any other request that never got its reply.
    fn request(&self, payload: envelope::Payload, deadline: Duration) -> Result<Envelope, SessionError> {
        // An id was never issued for this connection yet; the Swift session
        // starts its counter at 1 and this keeps its shape.
        let request_id = self.next_request_id.fetch_add(1, Ordering::SeqCst);
        let (sender, reply) = mpsc::channel();
        // The slot is in before the envelope leaves, so a reply already on
        // its way cannot miss it (the Swift session plants its continuation
        // before the write task runs).
        self.pending.lock().expect("the pending mutex is never poisoned").insert(request_id, sender);
        match self.post(request_id, payload) {
            Ok(()) => {}
            Err(error) => {
                self.pending.lock().expect("the pending mutex is never poisoned").remove(&request_id);
                // A write the wire refused ends the session (the Swift
                // session's writeOrFail expires the request and the reading
                // task finds the break next); `Protocol` is the one local
                // refusal — the envelope never left — that leaves the
                // transport unharmed.
                if !matches!(error, SessionError::Protocol(_)) {
                    self.mark_dead();
                }
                return Err(error);
            }
        }
        match reply.recv_timeout(deadline) {
            Ok(answer) => answer,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // The slot comes out so the reply that eventually arrives is
                // unpaired — dropped in `route`, never to reach the next
                // request's slot (ControlSession.swift's `expire` removes
                // the map entry the same way).
                self.pending.lock().expect("the pending mutex is never poisoned").remove(&request_id);
                Err(SessionError::TimedOut)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(SessionError::Closed),
        }
    }

    /// One inbound envelope, routed as ControlSession.swift's `handle()`
    /// does: a non-zero id answers the pending request first; what is left
    /// stands on its payload.
    fn route(&self, incoming: Envelope) {
        if incoming.request_id != 0 {
            let slot = self.pending.lock().expect("the pending mutex is never poisoned").remove(&incoming.request_id);
            if let Some(slot) = slot {
                // The entry leaves the map before the reply lands in the
                // slot, so the id cannot be answered twice.
                let _ = slot.send(Ok(incoming));
                return;
            }
            // Unpaired: the id's requester timed out (its slot is off the
            // map) or the id was never asked for. ControlSession.swift lets
            // the payload through to the switch after this, where a stray
            // reply would end up in the events stream; here the switch runs
            // for pings only and a reply with no waiter is dropped — the
            // port's contract says a late reply is ignored, not delivered —
            // and the guest does not re-ask an answered request, so the map
            // cannot miss a real one.
            if let Some(envelope::Payload::Ping(ping)) = incoming.payload {
                // The pong is the session's own, same id, same nonce.
                if self.post(incoming.request_id, envelope::Payload::Pong(Pong { nonce: ping.nonce })).is_err() {
                    self.mark_dead();
                    return;
                }
            }
            return;
        }
        match incoming.payload {
            // A second Hello has no answer to serve; the Swift session parks
            // it in `receivedHello`, which nothing reads again.
            Some(envelope::Payload::Hello(_)) => {}
            // The guest ended the session (reason and wording belong to it);
            // Swift's case closes with guestUnavailable — or guestIncompatible
            // for the version reason — and its pending requests throw. The
            // port collapses both to `Closed` here, and answers nothing: the
            // goodbye means the peer will not read one.
            Some(envelope::Payload::Goodbye(_)) => self.mark_dead(),
            // The session posts this pong itself, even while a request of
            // ours is waiting (ControlSession.swift does it inside `handle`).
            Some(envelope::Payload::Ping(ping)) => {
                if self.post(incoming.request_id, envelope::Payload::Pong(Pong { nonce: ping.nonce })).is_err() {
                    self.mark_dead();
                }
            }
            // An event, or a stray frame — into the sink whole (the guest's
            // protocol version and id ride along).
            Some(_) => {
                let _ = self.sink.send(incoming);
            }
            // `case nil` in the Swift switch: nothing to serve.
            None => {}
        }
    }
}

/// The reader thread: frames in from the transport one at a time, each one
/// routed, until the session or the transport ends — the Swift session's
/// reading task, which ends its own session with `guestUnavailable` on
/// anything but a delivered frame.
fn read_loop(mut read_half: UnixStream, actor: Arc<Actor>) {
    while !actor.closed.load(Ordering::SeqCst) {
        match read_envelope(&mut read_half) {
            Ok(Some(incoming)) => actor.route(incoming),
            // read_envelope's Ok arm is always Some; treat the rest as the
            // transport ending anyway so the thread can only leave, not spin.
            Ok(None) => break,
            // EOF or error: the session is over. `Closed` is what the
            // requesters see (ControlSession.swift closes on the reading
            // task's error the same way).
            Err(_) => break,
        }
    }
    actor.mark_dead();
    // The thread ends here; its handles drop, the sink's last sender goes
    // with them, and `events()` reads a disconnect after whatever it held.
}

/// The Mac's keepalive, ControlSession.swift's `startKeepalive` task spelled
/// out in a thread: sleep one period, check the session still is, send one
/// Ping as a plain request (a real id and a pending slot, like every other
/// request — the Swift calls `self.request(...)` with the ping too, so ids
/// are spent and slots planted by the keepalive the same way), count a miss
/// on any error the attempt throws up — the window passing being what a
/// silent peer makes one — and start the count over on every hit. The miss
/// limit reached, the session ends itself: `close(error:
/// guestUnavailable)` in the Swift, `sever` here, no goodbye on the wire.
/// The `try? sleep`'s cancellation the Swift task eats is the flag check
/// here — the flag is what `close` and every other end trip it with.
fn keepalive_loop(actor: Arc<Actor>, keepalive: Keepalive) {
    let mut nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as u64)
        .unwrap_or(0x9E37_79B9_7F4A_7C15)
        .max(1);
    let mut misses = 0;
    while !actor.closed.load(Ordering::SeqCst) {
        std::thread::sleep(keepalive.period);
        // The Swift's `guard let self, await self.isOpen` stands between
        // the sleep and the ping.
        if actor.closed.load(Ordering::SeqCst) {
            return;
        }
        nonce = ping_nonce(nonce);
        match actor.request(envelope::Payload::Ping(Ping { nonce }), keepalive.window) {
            // A hit is whatever the guest answered with; the count starts
            // over. A miss is any failure — the window's `TimedOut` above
            // all, writes the transport refused alongside the rest.
            Ok(_) => misses = 0,
            Err(_) => {
                misses += 1;
                if misses >= keepalive.miss_limit {
                    actor.sever();
                    return;
                }
            }
        }
    }
}

/// The pings' nonces. The Swift draws its from `UInt64.random(in:
/// 1...UInt64.max)`; std has no runner for that, so an xorshift64*
/// seeded once off the wall clock fills the same shape — a state the
/// range's zero cannot leak into (nonzero in stays nonzero out, the
/// multiplier is odd), never the same number twice running.
fn ping_nonce(mut state: u64) -> u64 {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    state.wrapping_mul(0x2545_F491_4F6C_DD1D)
}

impl ControlSession {
    /// The session's start: the Hello exchange, then the reader and
    /// keepalive threads.
    ///
    /// Writes the daemon's Hello (`PROTOCOL_VERSION`, `PROTOCOL_MIN_VERSION`,
    /// this build's `software_version`, request id 0, nothing for
    /// capabilities — the Linux port advertises none yet), reads the guest's,
    /// settles the protocol version by AvoProtocol.swift's `negotiate`: the
    /// lower of the two maxima, and both sides' floors must accept it. A
    /// floor that fails gets `Goodbye{IncompatibleVersion}` with the
    /// negotiation's wording (ControlSession.swift sends the same message)
    /// and `Protocol` comes back instead of a session.
    pub fn open(stream: VsockStream, software_version: &str) -> Result<ControlSession, SessionError> {
        ControlSession::open_on(stream, software_version, Keepalive::default())
    }

    /// `open` with the keepalive's clocks handed over — the tests' way in;
    /// `open` itself runs ControlSession.swift's `startKeepalive` numbers.
    fn open_on(
        stream: VsockStream,
        software_version: &str,
        keepalive: Keepalive,
    ) -> Result<ControlSession, SessionError> {
        // vsock.rs: past the engine's `OK` line the bytes are the raw vsock
        // stream. Reads keep the one handle; writes go through the duplicate,
        // so the reader thread blocks on nothing the requests write.
        let mut read_half = stream.into_inner();
        let write_half = read_half.try_clone().map_err(|error| wire_error(&error))?;
        let (sink, events) = mpsc::channel();
        let actor = Arc::new(Actor {
            writer: Mutex::new(write_half),
            pending: Mutex::new(HashMap::new()),
            next_request_id: AtomicU64::new(1),
            closed: AtomicBool::new(false),
            sink,
        });
        // The keepalive thread lets go of its loop with a signal, so the
        // tests can wait for its end instead of counting the process's
        // threads. The Mac's session holds its task in `tasks` and
        // cancels it in `close`; a closed flag does the tripwire work
        // here, and the signal reads back through the handle.
        let (keepalive_send, keepalive_gone) = mpsc::channel();

        // The Swift session writes its Hello first and only then settles in
        // to wait; a guest that answered during the write is handled next
        // loop trip there, and simply first read here.
        actor
            .post(
                0,
                envelope::Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION,
                    min_protocol_version: PROTOCOL_MIN_VERSION,
                    software_version: software_version.to_string(),
                    ..Default::default()
                }),
            )
            .map_err(|error| {
                actor.mark_dead();
                error
            })?;

        // The socket's read deadline is what makes the gate's ten seconds
        // exist; the timeout lives on the open file description, so the
        // reader thread's handle would carry it too — the deadline is off
        // again below, before any thread may read.
        read_half
            .set_read_timeout(Some(HELLO_TIMEOUT))
            .map_err(|error| wire_error(&error))?;
        let peer = loop {
            match read_envelope(&mut read_half) {
                Ok(Some(incoming)) => {
                    if let Some(envelope::Payload::Hello(peer)) = incoming.payload {
                        break peer;
                    }
                    // Everything else routes like the reader will, but with
                    // no negotiated session to sit behind the sink and the
                    // gate: pongs and sink posts still work, and a goodbye
                    // means no Hello is coming.
                    match incoming.payload {
                        Some(envelope::Payload::Ping(ping)) => {
                            if actor.post(incoming.request_id, envelope::Payload::Pong(Pong { nonce: ping.nonce })).is_err() {
                                return Err(SessionError::Closed);
                            }
                        }
                        Some(envelope::Payload::Goodbye(_)) => return Err(SessionError::Closed),
                        Some(_) => {
                            let _ = actor.sink.send(incoming);
                        }
                        None => {}
                    }
                }
                // Ok(None) does not happen from read_envelope; treat it as
                // the transport ending so the loop cannot spin.
                Ok(None) => return Err(SessionError::Closed),
                Err(error) => {
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) {
                        // The gate's ten seconds.
                        return Err(SessionError::TimedOut);
                    }
                    return Err(wire_error(&error));
                }
            }
        };
        read_half.set_read_timeout(None).map_err(|error| wire_error(&error))?;

        // AvoProtocol.swift's negotiate: agreed = min(both maxima); below
        // either minimum is the failure the descriptions name.
        let raised = PROTOCOL_VERSION.min(peer.protocol_version);
        let refusal = if raised < PROTOCOL_MIN_VERSION {
            Some(format!(
                "The Android image speaks protocol {} but Avo needs at least {}. Update the Android image.",
                peer.protocol_version, PROTOCOL_MIN_VERSION
            ))
        } else if raised < peer.min_protocol_version {
            Some(format!(
                "Avo speaks protocol {} but the Android image needs at least {}. Update Avo.",
                PROTOCOL_VERSION, peer.min_protocol_version
            ))
        } else {
            None
        };
        if let Some(message) = refusal {
            // ControlSession.swift's failure case: the goodbye sails out and
            // the error is thrown, the session closed behind it.
            let _ = actor.enqueue(
                0,
                envelope::Payload::Goodbye(Goodbye {
                    reason: goodbye::Reason::IncompatibleVersion as i32,
                    message: message.clone(),
                }),
            );
            return Err(SessionError::Protocol(message));
        }

        let reader_actor = Arc::clone(&actor);
        std::thread::spawn(move || read_loop(read_half, reader_actor));

        // The keepalive starts on the negotiated success, the way
        // ControlSession.swift's `start` reaches `startKeepalive()` only
        // inside the switch's success case — a gate that refused its peer
        // never pings it.
        let keepalive_actor = Arc::clone(&actor);
        std::thread::spawn(move || {
            keepalive_loop(keepalive_actor, keepalive);
            let _ = keepalive_send.send(());
        });

        Ok(ControlSession { actor, negotiated_version: raised, events, keepalive_gone })
    }

    /// The session's settled version (the Swift session's
    /// `negotiatedVersion`): the lower of the two Hellos' maxima, which the
    /// gate proved clears both floors.
    pub fn negotiated_version(&self) -> u32 {
        self.negotiated_version
    }

    /// The inbound sink's receiving end. The session created the channel at
    /// `open`, its reader thread is the only sender — past `close`, the sink
    /// empties and disconnects, which is the Swift event stream's finish.
    pub fn events(&self) -> &mpsc::Receiver<Envelope> {
        &self.events
    }

    /// Sends a request and waits for the reply that carries its id. `None`
    /// times out at `REQUEST_TIMEOUT` — any envelope with the id answers,
    /// typed response or `Reply` (proto.rs: the guest answers with either),
    /// and the caller reads statuses out of what comes back.
    pub fn request(&self, payload: envelope::Payload, timeout: impl Into<Option<Duration>>) -> Result<Envelope, SessionError> {
        self.actor.request(payload, timeout.into().unwrap_or(REQUEST_TIMEOUT))
    }

    /// Sends without waiting for an answer (ControlSession.swift's `send`).
    /// request id 0 — the guest's events do the same the other way.
    pub fn send(&self, payload: envelope::Payload) -> Result<(), SessionError> {
        self.actor.post(0, payload)
    }

    /// Ends the session: `Goodbye{Shutdown}` out first, then both halves of
    /// the socket shut — the guest reads the goodbye and then EOF, and the
    /// reader thread's own blocking read comes back. Waiting requests wake
    /// with `Closed`; a second close is nothing.
    pub fn close(&self) {
        if self.actor.closed.swap(true, Ordering::SeqCst) {
            // The reader thread, the transport, the keepalive or a caller
            // already ended it; the goodbye is theirs or nobody's — a
            // keepalive death writes none — and the waiting slots are
            // already emptied.
            return;
        }
        let _ = self.actor.enqueue(
            0,
            envelope::Payload::Goodbye(Goodbye {
                reason: goodbye::Reason::Shutdown as i32,
                message: String::new(),
            }),
        );
        if let Ok(writer) = self.actor.writer.lock() {
            let _ = writer.shutdown(Shutdown::Both);
        }
        self.actor.drain();
    }
}

/// The one session handle: the shared `Actor`, its reader thread holding a
/// clone of it alive, and the bits the gate's start left for callers — the
/// keepalive's goodnight signal among them, a fresh `()` when its thread
/// has left the wire for good, however the session ended.
pub struct ControlSession {
    actor: Arc<Actor>,
    negotiated_version: u32,
    events: mpsc::Receiver<Envelope>,
    keepalive_gone: mpsc::Receiver<()>,
}

/// `control`'s read/write io errors split two ways: `ErrorKind::InvalidData`
/// is the wire breaking shape — oversized frame, undecodable envelope — and
/// is protocol; every other kind is the transport going away, which is all
/// `Closed` needs to be.
fn wire_error(error: &std::io::Error) -> SessionError {
    if error.kind() == ErrorKind::InvalidData {
        SessionError::Protocol(error.to_string())
    } else {
        SessionError::Closed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{read_envelope, write_envelope};
    use crate::proto::{envelope, reply, Hello, Launch, Ping, Reply, TaskStarted};
    use crate::vsock::Vsock;
    use std::io::Read as _;
    use std::io::Write as _;
    use std::os::unix::net::UnixListener;
    use std::thread;

    /// The tests' own generous wait: not a protocol deadline, only the
    /// ceiling a broken transport or a stray reply's silence gets to fail
    /// inside. The injected deadlines are the 50ms ones each test carries.
    const CEILING: Duration = Duration::from_secs(5);

    /// vsock.rs's tests' `engine` helper, cut to one connection: the fake
    /// engine answers the `CONNECT` line with `OK` and hands the now-raw
    /// accepted stream back as the guest's end of the wire. That dance is
    /// the only thing that can build a `VsockStream`, so the session's
    /// tests play the engine too.
    fn fake_engine()
    -> (Vsock, mpsc::Receiver<UnixStream>) {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "avod-session-{}-{}.sock",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&path).unwrap();
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = Vec::new();
            loop {
                let mut byte = [0u8; 1];
                stream.read_exact(&mut byte).unwrap();
                line.push(byte[0]);
                if byte[0] == b'\n' {
                    break;
                }
            }
            assert!(line.starts_with(b"CONNECT "), "the engine's handshake line is the CONNECT one: {line:?}");
            stream.write_all(b"OK 1\n").unwrap();
            let _ = sender.send(stream);
        });
        (Vsock::at(&path), receiver)
    }

    /// One step of the guest's script, in wire order.
    enum Step {
        Write(Envelope),
        Read,
        /// Sits the script out; the reads after it keep serving.
        Wait(Duration),
    }

    /// The script thread: writes and reads with the framing built right in,
    /// each read posted to `report` for the test's own assertions.
    fn run_script(mut stream: UnixStream, steps: Vec<Step>, report: mpsc::Sender<Envelope>) {
        for step in steps {
            match step {
                Step::Write(out) => write_envelope(&mut stream, &out).unwrap(),
                Step::Read => {
                    let read = read_envelope(&mut stream).unwrap().unwrap();
                    report.send(read).expect("the test is still alive while the script runs");
                }
                Step::Wait(duration) => thread::sleep(duration),
            }
        }
    }

    /// The session over a scripted guest: the test drives the session's
    /// calls, the script lays the wire down ahead of them.
    fn played(script: Vec<Step>) -> (Result<ControlSession, SessionError>, mpsc::Receiver<Envelope>) {
        let (vsock, accepted) = fake_engine();
        let (sender, receiver) = mpsc::channel();
        // The script thread waits on the engine's delivered stream while
        // open runs the CONNECT dance and the Hello gate on this thread.
        thread::spawn(move || run_script(accepted.recv().unwrap(), script, sender));
        let opened = ControlSession::open(vsock.connect_to(crate::CONTROL_PORT).unwrap(), "avod 0");
        (opened, receiver)
    }

    /// `played` with the keepalive's own clocks handed over — the test's
    /// way to watch the pings without the default's five seconds in front
    /// of the first one.
    fn played_on(script: Vec<Step>, keepalive: Keepalive) -> (Result<ControlSession, SessionError>, mpsc::Receiver<Envelope>) {
        let (vsock, accepted) = fake_engine();
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || run_script(accepted.recv().unwrap(), script, sender));
        let opened = ControlSession::open_on(vsock.connect_to(crate::CONTROL_PORT).unwrap(), "avod 0", keepalive);
        (opened, receiver)
    }

    /// Any session's opening exchange, at the version floors given: read our
    /// Hello out, answer with the guest's.
    fn hello_script(version: u32, min: u32) -> Vec<Step> {
        vec![
            Step::Read,
            Step::Write(envelope_of(envelope::Payload::Hello(Hello {
                protocol_version: version,
                min_protocol_version: min,
                software_version: "bridge image".into(),
                ..Default::default()
            }))),
        ]
    }

    /// A peer whose gates agree with ours; the returned session is up.
    fn started() -> (ControlSession, mpsc::Receiver<Envelope>) {
        let (opened, receiver) = played(hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION));
        (opened.unwrap(), receiver)
    }

    /// The opening frame: ours off the guest's read, id 0 and our version.
    fn read_hello(wire: &mpsc::Receiver<Envelope>) -> Hello {
        let heard = wire.recv().unwrap();
        assert_eq!(heard.request_id, 0, "the Hello is an unasked frame");
        assert_eq!(heard.protocol_version, PROTOCOL_VERSION);
        match heard.payload {
            Some(envelope::Payload::Hello(hello)) => hello,
            other => panic!("the opening frame is not a Hello: {other:?}"),
        }
    }

    /// One reply envelope: Ok, stamped with the id it answers.
    fn reply_ok(request_id: u64) -> Envelope {
        Envelope {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            payload: Some(envelope::Payload::Reply(Reply { status: reply::Status::Ok as i32, message: String::new() })),
        }
    }

    #[test]
    fn the_hello_gate_agrees_the_version() {
        let (session, wire) = started();
        let hello = read_hello(&wire);
        assert_eq!(hello.protocol_version, PROTOCOL_VERSION);
        assert_eq!(hello.min_protocol_version, PROTOCOL_MIN_VERSION);
        assert_eq!(hello.software_version, "avod 0");
        // The guest opened as 1/1 — the lower of the two maxima, which both
        // floors accept, and what the session settles to.
        assert_eq!(session.negotiated_version(), PROTOCOL_VERSION);
        session.close();
    }

    #[test]
    fn a_reply_is_matched_by_its_id_between_events_and_a_ping() {
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        script.extend([
            Step::Read,                    // our request: id 1's first ever
            Step::Write(reply_ok(1)),
            // The guest's say-so passing while the request waits.
            Step::Write(envelope_of(envelope::Payload::TaskStarted(TaskStarted {
                package: "com.avo.notes".into(),
                task_id: 3,
            }))),
            Step::Write(envelope_of(envelope::Payload::Ping(Ping { nonce: 12 }))),
            Step::Read,                    // our own Pong back, the ping's nonce
        ]);
        let (opened, wire) = played(script);
        let session = opened.unwrap();
        let answered = session
            .request(
                envelope::Payload::Launch(Launch {
                    package: "com.avo.notes".into(),
                    display_id: 1,
                    width: 720,
                    height: 1280,
                    dpi: 320,
                    ..Default::default()
                }),
                Some(CEILING),
            )
            .unwrap();
        // The pairing is by id: the reply's own stamp is back, its payload
        // is whatever the guest answered with.
        assert_eq!(answered.request_id, 1);
        assert!(matches!(answered.payload, Some(envelope::Payload::Reply(_))));
        // On the guest's wire: our Hello, then the request, then the pongs.
        let hello = read_hello(&wire);
        assert_eq!(hello.software_version, "avod 0");
        let launch = wire.recv().unwrap();
        assert_eq!(launch.request_id, 1);
        assert!(matches!(launch.payload, Some(envelope::Payload::Launch(_))));
        let pong = wire.recv().unwrap();
        assert_eq!(pong.payload, Some(envelope::Payload::Pong(Pong { nonce: 12 })));
        // The unrelated event reached the sink and nothing else did — no
        // reply-shaped strays between the two requests.
        let event = session.events().recv().unwrap();
        assert_eq!(event.payload, Some(envelope::Payload::TaskStarted(TaskStarted {
            package: "com.avo.notes".into(),
            task_id: 3,
        })));
        assert!(session.events().try_recv().is_err(), "nothing extra belongs in the sink");
        session.close();
    }

    #[test]
    fn an_incompatible_peer_gets_a_goodbye_and_no_session() {
        // Her max is below our floor: min(1, 0) is 0, and our minimum of 1
        // refuses it — AvoProtocol.swift's `guestTooOld` branch.
        let mut script = hello_script(0, 1);
        script.push(Step::Read); // then the refusal, on the guest's behalf
        let (opened, wire) = played(script);
        let refusal = match opened {
            Err(refusal) => refusal,
            Ok(_) => panic!("a peer below the version floor is refused"),
        };
        let SessionError::Protocol(message) = &refusal else {
            panic!("a version mismatch is a protocol refusal: {refusal:?}");
        };
        assert_eq!(
            message,
            "The Android image speaks protocol 0 but Avo needs at least 1. Update the Android image."
        );
        // The refusal went out on the wire before open gave up, behind the
        // Hello the gate read first.
        let hello = read_hello(&wire);
        assert_eq!(hello.software_version, "avod 0");
        let heard = wire.recv().unwrap();
        assert_eq!(heard.request_id, 0);
        assert_eq!(heard.payload, Some(envelope::Payload::Goodbye(Goodbye {
            reason: goodbye::Reason::IncompatibleVersion as i32,
            message: message.clone(),
        })));
    }

    #[test]
    fn a_timed_out_request_leaves_its_late_reply_unpaired() {
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        script.extend([
            Step::Read,                                       // our first request
            Step::Wait(Duration::from_millis(150)),           // its answer beats the deadline
            Step::Write(reply_ok(1)),                         // the late reply
            Step::Read,                                       // our second request, fresh id
            Step::Write(reply_ok(2)),
        ]);
        let (opened, wire) = played(script);
        let session = opened.unwrap();
        let missed = session
            .request(
                envelope::Payload::Ping(Ping { nonce: 5 }),
                Some(Duration::from_millis(50)),
            )
            .unwrap_err();
        assert_eq!(missed, SessionError::TimedOut);
        // The first try stopped at the deadline; its id is spent and the
        // next one is fresh, not recycled.
        let second = session
            .request(
                envelope::Payload::Launch(Launch {
                    package: "com.avo.notes".into(),
                    display_id: 1,
                    width: 720,
                    height: 1280,
                    dpi: 320,
                    ..Default::default()
                }),
                Some(CEILING),
            )
            .unwrap();
        assert_eq!(second.request_id, 2);
        assert!(matches!(second.payload, Some(envelope::Payload::Reply(_))));
        // The late reply's slot was gone when it landed: dropped rather than
        // delivered, and nothing stray reached the sink for it.
        let opening = wire.recv().unwrap();
        assert_eq!(opening.request_id, 0);
        let first_request = wire.recv().unwrap();
        assert_eq!(first_request.request_id, 1);
        let second_request = wire.recv().unwrap();
        assert_eq!(second_request.request_id, 2);
        assert!(session.events().try_recv().is_err(), "the late reply is unpaired, not sunk");
        session.close();
    }

    #[test]
    fn close_announces_shutdown_and_then_refuses_requests() {
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        script.extend([
            Step::Read,           // our request
            Step::Write(reply_ok(1)),
            Step::Read,           // our Goodbye{Shutdown}
        ]);
        let (session, wire) = played(script);
        let session = session.unwrap();
        let first = session
            .request(
                envelope::Payload::Launch(Launch {
                    package: "com.avo.notes".into(),
                    display_id: 1,
                    width: 720,
                    height: 1280,
                    dpi: 320,
                    ..Default::default()
                }),
                Some(CEILING),
            )
            .unwrap();
        assert_eq!(first.request_id, 1);
        session.close();
        // The session's own goodbye is the last frame on the wire, behind
        // the gate's Hello and the request's frame.
        read_hello(&wire);
        let launch = wire.recv().unwrap();
        assert_eq!(launch.request_id, 1);
        let heard = wire.recv().unwrap();
        assert_eq!(heard.payload, Some(envelope::Payload::Goodbye(Goodbye {
            reason: goodbye::Reason::Shutdown as i32,
            message: String::new(),
        })));
        // Past close, anything is a refusal — wire or no wire.
        let again = session
            .request(envelope::Payload::Ping(Ping { nonce: 6 }), Some(CEILING))
            .unwrap_err();
        assert_eq!(again, SessionError::Closed);
    }

    #[test]
    fn a_transport_that_dies_wakes_the_waiting_request() {
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        script.extend([
            Step::Read,        // our request — read, and never answered
            // The guest's half closes; the reader's next read comes back and the
            // waiting request ends with the session.
        ]);
        let (opened, wire) = played(script);
        let session = opened.unwrap();
        let ended = session
            .request(
                envelope::Payload::Launch(Launch {
                    package: "com.avo.notes".into(),
                    display_id: 1,
                    width: 720,
                    height: 1280,
                    dpi: 320,
                    ..Default::default()
                }),
                Some(CEILING),
            )
            .unwrap_err();
        assert_eq!(ended, SessionError::Closed);
        wire.recv().unwrap();
        session.close();
    }

    /// The keepalive's numbers at test speed, shrunk by the same ratio all
    /// the ways it has: 120ms between the pings, half a second for each
    /// answer, three misses to end the session.
    fn fast_keepalive() -> Keepalive {
        Keepalive {
            period: Duration::from_millis(120),
            window: Duration::from_millis(500),
            miss_limit: 3,
        }
    }

    /// The wire's Ping, its id and nonce off the script's reported read.
    fn ping_of(report: &Envelope) -> (u64, u64) {
        match &report.payload {
            Some(envelope::Payload::Ping(ping)) if report.request_id != 0 => (report.request_id, ping.nonce),
            other => panic!("the keepalive's ping is not on the wire: {other:?}"),
        }
    }

    #[test]
    fn the_keepalive_pings_its_period_and_survives_the_answers() {
        // Four answered rounds, then the session proves itself once more on
        // a real request. Ids ride the one counter the calls and pings
        // share — the gate spends 0, the pings 1..=4, the caller 5, because
        // the test's request goes out inside the period the keepalive's
        // sleep bought it (ControlSession.swift spends Ping ids exactly so).
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        for id in 1..=4 {
            script.extend([Step::Read, Step::Write(reply_ok(id))]);
        }
        script.extend([
            Step::Read,
            Step::Write(reply_ok(5)),
            // The wire stays open through the session's own close beneath.
            Step::Wait(Duration::from_millis(300)),
        ]);
        let (opened, wire) = played_on(script, fast_keepalive());
        let session = opened.unwrap();
        read_hello(&wire);
        let first_ping = std::time::Instant::now();
        let mut nonces = Vec::new();
        for id in 1..=4 {
            let report = wire.recv().unwrap();
            let (pinged, nonce) = ping_of(&report);
            assert_eq!(pinged, id, "the ping's id walks the one counter");
            assert_ne!(nonce, 0, "zero cannot leak into the pings' state");
            nonces.push(nonce);
        }
        for pair in nonces.windows(2) {
            assert_ne!(pair[0], pair[1], "the pings' nonces never repeat back to back");
        }
        // Four sleeps of the period sat between the sends, and not one of
        // them came early.
        assert!(first_ping.elapsed() >= Duration::from_millis(400), "the pings rode out four periods");
        // Four rounds later the session lives on: one more call round-trips,
        // id 5, the answer the script's last Write carries.
        let answered = session
            .request(
                envelope::Payload::Launch(Launch {
                    package: "com.avo.notes".into(),
                    display_id: 1,
                    width: 720,
                    height: 1280,
                    dpi: 320,
                    ..Default::default()
                }),
                Some(CEILING),
            )
            .unwrap();
        assert_eq!(answered.request_id, 5);
        session.close();
        // The keepalive's thread lets go without help; the signal is the
        // proof (the loop wakes inside one period, sees the flag, leaves).
        session.keepalive_gone.recv_timeout(Duration::from_secs(2)).unwrap();
    }

    #[test]
    fn the_miss_limit_ends_a_silent_guest_and_the_requests_know() {
        // One ping read, never answered; the guest sits silent but keeps
        // the stream. The window passes on each — the miss counts up — and
        // the limit reaches itself with no goodbye written first (the
        // sever's shape: the Swift's guestUnavailable close never sent
        // Goodbye, and the guest reads the stream's end bare).
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        script.extend([
            Step::Read,
            // ∞ far past two windows: the death is the keepalive's own.
            Step::Wait(Duration::from_millis(1500)),
        ]);
        let (opened, wire) = played_on(
            script,
            Keepalive {
                period: Duration::from_millis(80),
                window: Duration::from_millis(60),
                miss_limit: 2,
            },
        );
        let session = opened.unwrap();
        read_hello(&wire);
        let (pinged, _) = ping_of(&wire.recv().unwrap());
        assert_eq!(pinged, 1, "the first ping spends the counter's first id");
        // The keepalive ends itself — two misses at the window, then the
        // sever — and its thread's own signal is the test's poll: bounded
        // at two seconds, far past the ~280ms the two windows earn.
        session.keepalive_gone.recv_timeout(Duration::from_secs(2)).unwrap();
        // After the death a call reads the truth: Closed, and fast — the
        // request never hangs on a wire nobody serves.
        let ended = session
            .request(envelope::Payload::Ping(Ping { nonce: 6 }), Some(CEILING))
            .unwrap_err();
        assert_eq!(ended, SessionError::Closed);
    }

    #[test]
    fn a_close_during_the_keepalive_ends_its_thread_without_leaks() {
        // A peer answering pings, the miss limit far past the test's reach:
        // any end the session meets during this test is the test's own
        // close, so the thread's signal reads back as the close's doing —
        // the Swift's cancel of its startKeepalive task, spelled with a
        // flag the loop checks between its sleeps.
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        for id in 1..=2 {
            script.extend([Step::Read, Step::Write(reply_ok(id))]);
        }
        script.push(Step::Wait(Duration::from_millis(900)));
        let (opened, wire) = played_on(
            script,
            Keepalive {
                period: Duration::from_millis(60),
                window: Duration::from_millis(400),
                miss_limit: 10,
            },
        );
        let session = opened.unwrap();
        read_hello(&wire);
        for id in 1..=2 {
            let (pinged, _) = ping_of(&wire.recv().unwrap());
            assert_eq!(pinged, id);
        }
        session.close();
        // The thread leaves inside one period of the close, and a call
        // after answers Closed like any ended session.
        session.keepalive_gone.recv_timeout(Duration::from_secs(2)).unwrap();
        let ended = session
            .request(envelope::Payload::Ping(Ping { nonce: 9 }), Some(CEILING))
            .unwrap_err();
        assert_eq!(ended, SessionError::Closed);
    }

    #[test]
    fn keepalive_pings_never_confuse_a_callers_own_requests() {
        // The calls and the pings interleave on the one counter and the one
        // pending map (the Swift's Ping rides `request` too): the caller's
        // first call sends inside the keepalive's first sleep, the second
        // inside the sleep its first ping's answer bought — so the ids walk
        // 1, 2, 3, 4 in wire order and no reply meets the wrong slot.
        let mut script = hello_script(PROTOCOL_VERSION, PROTOCOL_MIN_VERSION);
        script.extend([
            // The caller's first request, before the keepalive wakes.
            Step::Read,
            Step::Write(reply_ok(1)),
            // The keepalive's first ping — the id one after the call's.
            Step::Read,
            Step::Write(reply_ok(2)),
            // The caller's second, inside the period just bought.
            Step::Read,
            Step::Write(reply_ok(3)),
            // The keepalive's second ping.
            Step::Read,
            Step::Write(reply_ok(4)),
            Step::Wait(Duration::from_millis(400)),
        ]);
        let (opened, wire) = played_on(script, fast_keepalive());
        let session = opened.unwrap();
        read_hello(&wire);
        let launch = || {
            envelope::Payload::Launch(Launch {
                package: "com.avo.notes".into(),
                display_id: 1,
                width: 720,
                height: 1280,
                dpi: 320,
                ..Default::default()
            })
        };
        let first = session.request(launch(), Some(CEILING)).unwrap();
        assert_eq!(first.request_id, 1, "the caller's first call spends the first id");
        // The script's Reads report our own envelopes back too: the first
        // one is the gate's hello, the next the call the script is about
        // to answer.
        let heard = wire.recv().unwrap();
        assert_eq!(heard.request_id, first.request_id);
        let (pinged, _) = ping_of(&wire.recv().unwrap());
        assert_eq!(pinged, 2);
        let second = session.request(launch(), Some(CEILING)).unwrap();
        assert_eq!(second.request_id, 3, "the ping's id spent between the calls");
        let heard = wire.recv().unwrap();
        assert_eq!(heard.request_id, second.request_id);
        let (pinged, _) = ping_of(&wire.recv().unwrap());
        assert_eq!(pinged, 4);
        session.close();
    }
}

