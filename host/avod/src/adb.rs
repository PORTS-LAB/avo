//! The daemon's ADB relay: one local TCP endpoint per instance whose every
//! connection is piped, both directions, to the guest's adbd on vsock 5555
//! (docs/protocol.md: "ADB | 5555 | ADB wire protocol (adbd
//! `service.adb.listen_addrs=vsock:5555`) | adbd"). What this replaces is the
//! Mac's "ADB support" (System settings): AvoDaemonCore's ADBForwarder binds a
//! loopback TCP port while the setting is on and gives every accepted socket
//! one fresh guest connection, spliced both ways (ADBForwarder.swift:29-68).
//! From there the user's own adb drives Avo: AvoKit's status carries the
//! wording to type — "What to type: `adb connect 127.0.0.1:5555`"
//! (XPCInterface.swift:332) — and on the default port plain `adb devices`
//! finds the VM without any connect, because adb's server scans 5555–5585 for
//! emulators and lists it as emulator-5554 (ADBForwarder.swift:7-9;
//! VMConfig.swift's defaultADBPort). There is no `avo adb proxy`-style command
//! on the Mac; this module is the same endpoint, to be handed out by the
//! daemon's own wiring (docs/linux-port.md phase 3).
//!
//! The relay forwards bytes and nothing else. The Mac's verb is SocketSplice:
//! one thread per direction over two sockets and a 64 KiB buffer
//! (LoopbackListener.swift:120), where "Blocking reads and writes on two
//! threads give natural backpressure (an `adb push` of a large file never
//! piles up in memory)" (LoopbackListener.swift:85-88). The semantics that
//! survive here, each from the same code: when a direction ends its pump
//! "Pass[es] the end of the stream on; the other direction may still run" —
//! `shutdown(to, SHUT_WR)` after the pending data drained, since the pump
//! writes everything back before reading more — then `shutdown(from, SHUT_RD)`
//! (LoopbackListener.swift:119-144), so a client's half close reaches adbd and
//! the reverse direction finishes after it. When the guest's port answers
//! `ERROR connection refused` — the engine's socket-device half does that when
//! the guest resets a connect (engine/hvf/vmm/src/virtio/vsock.rs:557-560, so
//! src/vsock.rs maps it to ConnectionRefused) — the Mac closes the socket and
//! keeps accepting ("adb sees a closed connection while Android is off and
//! retries", ADBForwarder.swift:59, 66-68); this relay records the refusal in
//! `AdbRelay::failures` and does the same. Tearing down ends accepting and
//! cancels every live splice: the Mac's listener stops while "Connections
//! already accepted are not affected" (LoopbackListener.swift:44-47) and
//! ADBForwarder.update shuts its splices down on the way out
//! (ADBForwarder.swift:34-35) — the shutdowns from SocketSplice.cancel wake
//! pumps even when they stand blocked mid-read or mid-write
//! (LoopbackListener.swift:111-117). The thread shape is the Mac's, with one
//! relay thread per connection of one's own: its two direction threads are
//! joined inside it, and no byte crosses any shared state — the finished
//! counter the Mac closes both sockets behind (LoopbackListener.swift:136-143)
//! is here the joined pair of threads and the handles dropping after.
//!
//! What is deliberately absent: the Mac's own ADB *client* stack in
//! AvoKit/Sources/AvoADB — ADBConnection's CNXN/AUTH handshake over an RSA key
//! (ADBConnection.swift:60-73; ADBKey.swift:79-98), its WRTE/OKAY message
//! flow (:137-183), and ADBServices' shell v2, exec, sync-push and
//! `pm install-*` session wrappers (ADBServices.swift:18-203; docs/protocol.md's
//! "Installing a package"). The relay serves bytes to the user's own adb, and
//! the Mac reaches that client for repairs and installs with RSA-SHA1 signing
//! no std has and the crate takes on no crypto dependency (prost is its only
//! one). A later phase that installs from the Linux daemon without adb needs
//! that client for itself; this port stops at the relay.

use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use crate::vsock::Vsock;

/// The accept loop's idle tick: how long it sleeps over an empty accept queue
/// before re-checking the stop token.
const TICK: Duration = Duration::from_millis(1);

/// What the relay can fail with. `Bind` and `Listen` are the listening side
/// (the Mac's user voice for a bound port is "Port N is already in use by
/// another app. Choose another port.", ADBForwarder.swift:47, and its log line
/// for the same shape runs "ADB support cannot listen on …", :49-50);
/// `GuestUnreachable` is per connection and never fatal — the loop keeps
/// accepting; `Closed` is a stop on a stop.
#[derive(Debug)]
pub enum RelayError {
    /// The local endpoint could not be bound. `bind` produces it; the cause
    /// is the io error, whose `AddrInUse` is the Mac's taken-port case.
    Bind(std::io::Error),
    /// The relay's listening machinery failed — a listener that cannot say
    /// its address or spawn its loop, a clone or thread out of some
    /// connection's setup. Accept-loop and per-connection ones surface in
    /// `AdbRelay::failures` and the loop lives on; only the loop's own spawn
    /// failing stops `relay` at all.
    Listen(std::io::Error),
    /// One accepted connection could not reach the guest — the engine's
    /// `ERROR connection refused` for an adbd that is not listening
    /// (engine/hvf/vmm/src/virtio/vsock.rs:557-560, by way of src/vsock.rs),
    /// or a guest transport that is not there. The Mac closes the socket and
    /// lets adb retry (ADBForwarder.swift:59, 66-68); `failures` carries it.
    GuestUnreachable(std::io::Error),
    /// The relay was already closed when a stop was asked of it.
    Closed,
}

/// A cause's copy. std's io::Error is neither `Clone` nor `PartialEq`, and the
/// relay needs both — `failures` hands its log out by value, and a caller
/// tasting a failure compares causes against each other. What a copy keeps is
/// what a cause's reader uses — the kind and the message: the kind is what
/// tests and callers branch on, and the message is the Display the daemon's
/// logging prints. The OS code inside the original is what nothing downstream
/// sees, and the original itself lives on wherever it was noted.
fn clone_of_cause(error: &std::io::Error) -> std::io::Error {
    std::io::Error::new(error.kind(), error.to_string())
}

impl Clone for RelayError {
    fn clone(&self) -> RelayError {
        match self {
            RelayError::Bind(cause) => RelayError::Bind(clone_of_cause(cause)),
            RelayError::Listen(cause) => RelayError::Listen(clone_of_cause(cause)),
            RelayError::GuestUnreachable(cause) => RelayError::GuestUnreachable(clone_of_cause(cause)),
            RelayError::Closed => RelayError::Closed,
        }
    }
}

impl PartialEq for RelayError {
    fn eq(&self, other: &RelayError) -> bool {
        match (self, other) {
            (RelayError::Bind(a), RelayError::Bind(b))
            | (RelayError::Listen(a), RelayError::Listen(b))
            | (RelayError::GuestUnreachable(a), RelayError::GuestUnreachable(b)) => {
                (a.kind(), a.to_string()) == (b.kind(), b.to_string())
            }
            (RelayError::Closed, RelayError::Closed) => true,
            _ => false,
        }
    }
}

impl Eq for RelayError {}

impl std::fmt::Display for RelayError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RelayError::Bind(error) => write!(out, "the relay's local port cannot be bound: {error}"),
            RelayError::Listen(error) => write!(out, "the relay cannot listen: {error}"),
            RelayError::GuestUnreachable(error) => write!(out, "the guest's adbd is unreachable: {error}"),
            RelayError::Closed => out.write_str("the relay is closed"),
        }
    }
}

impl std::error::Error for RelayError {}

/// Binds the relay's local endpoint: the Mac binds the loopback only, "so
/// nothing outside this Mac can connect" (LoopbackListener.swift:4-5), with
/// its v6 half tolerated off (LoopbackListener.swift:17-19). Port 0 asks the
/// OS for an ephemeral one, which is what the tests use; anything the kernel
/// refuses, a port already taken for instance, comes back as `Bind`.
pub fn bind(port: u16) -> Result<TcpListener, RelayError> {
    TcpListener::bind((Ipv4Addr::LOCALHOST, port)).map_err(RelayError::Bind)
}

/// Starts the relay on an already-listening `TcpListener`: the accept loop
/// runs as its own thread until the stop token (a `stop`, or a plain drop,
/// which stops), each accepted connection getting one relay thread of its
/// own. The loop's connection maker is its own `Vsock` handle — the threads
/// outlive this call, and a `Vsock` is the runtime directory's path by value
/// (src/vsock.rs `Vsock::at`), cheap to make a second of for the same
/// directory's control and input sessions. The Mac fetches the guest socket
/// the same way, one fresh connection per accepted socket, its `connectGuest`
/// closure firing per accept (ADBForwarder.swift:23-25, 53-68); the Linux
/// engine's side is the hybrid vsock's `CONNECT`/`OK` handshake, whose stream
/// is raw past it (src/vsock.rs:36-38) — the relay never reads the OK line's
/// assigned host port, the engine's bookkeeping (src/vsock.rs:26).
///
/// `relay` can only fail before anything is accepted: the bound listener
/// cannot say its address, or the loop's thread cannot be made, both as
/// `Listen`. Everything after runs to its stop.
pub fn relay(listener: TcpListener, vsock: Vsock) -> Result<AdbRelay, RelayError> {
    let local_addr = listener.local_addr().map_err(RelayError::Listen)?;
    let live = Arc::new(Shared {
        connections: Mutex::new(Roster {
            stopped: false,
            next_id: 0,
            entries: HashMap::new(),
        }),
        failures: Mutex::new(Vec::new()),
    });
    let running = Arc::new(AtomicBool::new(true));
    let acceptor = {
        let live = live.clone();
        let running = running.clone();
        std::thread::Builder::new()
            .name("avod-adb".into())
            .spawn(move || accept_loop(listener, vsock, live, running))
            .map_err(RelayError::Listen)?
    };
    Ok(AdbRelay { local_addr, live, running, acceptor: Some(acceptor) })
}

/// The relay's handle: the address it listens on, how many splices are live,
/// what failed per connection, the stop token, and the wait. Dropping it
/// stops the relay the same way `stop` does (it cannot join, since a drop
/// never blocks); `join` does the stopping and then waits for every relay
/// thread to be gone. The accept loop's thread handle lives in an `Option`
/// only because a wait is a by-value thing: `join` takes it out, and past a
/// `join` a relay just has no wait left to run.
pub struct AdbRelay {
    local_addr: SocketAddr,
    live: Arc<Shared>,
    running: Arc<AtomicBool>,
    acceptor: Option<std::thread::JoinHandle<Result<(), RelayError>>>,
}

impl AdbRelay {
    /// The local endpoint the caller bound, as the Mac's status names it to
    /// the user — "ADB support listening on 127.0.0.1:<port>"
    /// (ADBForwarder.swift:45).
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Splices through the port right now — the Mac's `sessionCount`, the
    /// number Pause When Idle keeps Android awake for (ADBForwarder.swift:
    /// 71-76). The Linux daemon's wiring reads the same count for the same
    /// reason.
    pub fn sessions(&self) -> usize {
        self.live.roster().entries.len()
    }

    /// The per-connection failures the accept side saw: the refusals, the
    /// accept loop's own spots, the machinery a connection could not make.
    /// This is the relay's log — the crate has no logging to call, and the
    /// Mac logs each kind the same way one connection at a time
    /// (ADBForwarder.swift:59, 66-68) — and the daemon's wiring surfaces it
    /// where its own logs go.
    pub fn failures(&self) -> Vec<RelayError> {
        self.live.failures.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
    }

    /// The stop token: stops accepting and shuts every live splice's sockets
    /// down — SocketSplice.cancel's deletes wake pumps standing blocked
    /// (LoopbackListener.swift:111-117), and the accepted-side know of the
    /// stop under the same lock the entries register under, so nothing starts
    /// past it. The Mac's own teardown shuts a listener whose accepted
    /// connections "are not affected" (LoopbackListener.swift:44-47) *and*
    /// cancels the splices (ADBForwarder.swift:34-35). A stop on a stop gets
    /// `Closed`.
    pub fn stop(&self) -> Result<(), RelayError> {
        if !self.running.swap(false, Ordering::SeqCst) {
            return Err(RelayError::Closed);
        }
        let mut roster = self.live.roster();
        roster.stopped = true;
        for splice in roster.entries.values() {
            let _ = splice.client.shutdown(Shutdown::Both);
            let _ = splice.guest.shutdown(Shutdown::Both);
        }
        Ok(())
    }

    /// Ends the relay completely: stops if need be, waits out the accept
    /// loop, then waits out every splice that was live at its stop. The
    /// connections still open at a stop get shut down there, so this is a
    /// bounded wait, not a wait on whoever happens to hold a socket. `join`
    /// stays on the handle — it does not consume it — and repeats as `Ok`
    /// without waiting: the first one spent the loop's thread handle, and
    /// everything it waited on is over. The result is the accept loop's own
    /// verdict, returned by the `join` that ran it — `Ok` whenever the loop
    /// ever came up, for the loop never dies of anything but its stop.
    pub fn join(&mut self) -> Result<(), RelayError> {
        self.stop().ok();
        let Some(acceptor) = self.acceptor.take() else {
            return Ok(()); // the first join's verdict stood; nothing left to wait
        };
        let result = match acceptor.join() {
            Ok(result) => result,
            Err(panic) => std::panic::resume_unwind(panic),
        };
        // No entry can register past its stop: the register path checks the
        // stop under the same lock. What is left was already shut down; the
        // joins here are the relay's last bytes of waiting.
        let mut roster = self.live.roster();
        let splices = std::mem::take(&mut roster.entries);
        drop(roster);
        for (_, splice) in splices {
            let _ = splice.thread.join();
        }
        result
    }
}

impl Drop for AdbRelay {
    fn drop(&mut self) {
        // stop() without the waits: the loop's next tick takes the token, the
        // splices wake on their shutdowns, every thread ends on its own.
        let _ = self.stop();
    }
}

/// The relay's shared set: the live splices' registry and the failure log,
/// both plain data. The roster's lock rules one decision — a splice is under
/// the stop's sweep or it is not registered yet — so a stop and a connection
/// coming up can never fall past each other.
struct Shared {
    connections: Mutex<Roster>,
    failures: Mutex<Vec<RelayError>>,
}

struct Roster {
    /// Set by a stop under its own lock, and read only under a lock.
    stopped: bool,
    /// The connections' plain counter, spawning new thread names from it.
    next_id: u64,
    entries: HashMap<u64, Splice>,
}

/// One live connection's stop-side reach and wait: clones of the connection's
/// two sockets for the shutdown sweep (a shutdown on any clone reaches the
/// socket), and the connection's thread's join for the relay's wait.
struct Splice {
    client: TcpStream,
    guest: UnixStream,
    thread: std::thread::JoinHandle<()>,
}

impl Shared {
    /// Locked through a poison: the registry holds plain data, so a panicked
    /// thread leaves a lock the daemon keeps reading and writing through.
    fn roster(&self) -> MutexGuard<'_, Roster> {
        self.connections.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn note(&self, failure: RelayError) {
        self.failures.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(failure);
    }

    /// The connection done: its registration leaves while the stop side can
    /// no longer interrupt it — and the count `sessions` reads drops with it
    /// (the Mac's sessionCount, ADBForwarder.swift:73-76).
    fn retire(&self, id: u64) {
        if let Some(splice) = self.roster().entries.remove(&id) {
            drop(splice.thread); // the connection is over; the handle held only the join
        }
    }
}

/// The accept loop: "run until stop token". The Mac's accept is a
/// dispatch-source read of the listen fd, so a stop can be a plain drain
/// (LoopbackListener.swift:24-38); std cannot wake a blocking `accept()`
/// across threads, and it has no poll(2) to wait on the listener together
/// with a stop token, so the listener runs non-blocking and the loop wakes on
/// a 1 ms tick. `running` is the token; a stop lands within a tick, once the
/// loop is at that check.
fn accept_loop(
    listener: TcpListener,
    vsock: Vsock,
    live: Arc<Shared>,
    running: Arc<AtomicBool>,
) -> Result<(), RelayError> {
    listener.set_nonblocking(true).map_err(RelayError::Listen)?;
    while running.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((client, _)) => accepted(client, &vsock, &live),
            Err(error) if error.kind() == ErrorKind::WouldBlock => std::thread::sleep(TICK),
            Err(error) if error.kind() == ErrorKind::Interrupted => {} // retry at once
            Err(error) => {
                // accept(2)'s own spots (a spent backlog entry, an fd storm)
                // surface and retry after the tick; the loop does not die of them,
                // the way the Mac's dispatch source just returns from its handler
                // (LoopbackListener.swift:29).
                live.note(RelayError::Listen(error));
                std::thread::sleep(TICK);
            }
        }
    }
    Ok(())
}

/// The accept side's per-connection arm, the Mac's accepted(), one fresh
/// guest connection per socket (ADBForwarder.swift:53-68): a guest that is
/// not there closes the socket and is recorded per connection, never fatal,
/// and a stop that lands during the connect is seen in the same breath as
/// the registration, the Mac's guard listener != nil close-and-return
/// (ADBForwarder.swift:53-57).
fn accepted(client: TcpStream, vsock: &Vsock, live: &Arc<Shared>) {
    let guest = match vsock.connect_to(crate::ADB_PORT) {
        Ok(stream) => stream.into_inner(),
        Err(error) => {
            // "adb sees a closed connection while Android is off and retries"
            // (ADBForwarder.swift:59): the socket closes, the loop keeps
            // accepting, adb's server does the reconnecting.
            live.note(RelayError::GuestUnreachable(error));
            drop(client);
            return;
        }
    };
    let mut roster = live.roster();
    if roster.stopped {
        drop(client);
        drop(guest);
        return;
    }
    let Ok(stop_client) = client.try_clone() else {
        live.note(RelayError::Listen(std::io::Error::last_os_error()));
        drop(client);
        drop(guest);
        return;
    };
    let Ok(stop_guest) = guest.try_clone() else {
        live.note(RelayError::Listen(std::io::Error::last_os_error()));
        drop(client);
        drop(guest);
        return;
    };
    let id = roster.next_id;
    roster.next_id += 1;
    let shared = live.clone();
    match std::thread::Builder::new()
        .name(format!("avod-adb-{id}"))
        .spawn(move || splice(client, guest, shared, id))
    {
        Ok(thread) => {
            let splice = Splice { client: stop_client, guest: stop_guest, thread };
            roster.entries.insert(id, splice);
        }
        Err(error) => {
            // The spawn's closure goes with it (client and guest drop there),
            // leaving this one a stop-side pair nobody registers: gone.
            drop(stop_client);
            drop(stop_guest);
            live.note(RelayError::Listen(error));
        }
    }
}

/// One connection's relay thread (one per connection): splices the pair both
/// ways exactly as the Mac's SocketSplice does, one thread per direction and
/// a 64 KiB buffer between them, and ends the connection when both
/// directions have — the Mac's finished counter reaching two and closing
/// both sockets (LoopbackListener.swift:99-105, 136-143) is exactly these
/// two joins followed by the handles dropping.
fn splice(client: TcpStream, guest: UnixStream, live: Arc<Shared>, id: u64) {
    let (client_read, client_write) = match (client.try_clone(), client.try_clone()) {
        (Ok(read), Ok(write)) => (read, write),
        (first, second) => {
            std::mem::drop(second);
            let cause = std::io::Error::last_os_error();
            drop(first);
            setup_failed(&live, id, cause, client, guest);
            return;
        }
    };
    let (guest_read, guest_write) = match (guest.try_clone(), guest.try_clone()) {
        (Ok(read), Ok(write)) => (read, write),
        (first, second) => {
            std::mem::drop(second);
            let cause = std::io::Error::last_os_error();
            drop(first);
            setup_failed(&live, id, cause, client, guest);
            return;
        }
    };
    // The direction threads' names carry the Mac's splice idea into the
    // process's thread list (its splice threads are queued as
    // "dev.avo.adb.splice", LoopbackListener.swift:101-103).
    let forward = std::thread::Builder::new()
        .name(format!("avod-adb-{id}-forward"))
        .spawn(move || pump(End::Client(client_read), End::Guest(guest_write)));
    let back = std::thread::Builder::new()
        .name(format!("avod-adb-{id}-back"))
        .spawn(move || pump(End::Guest(guest_read), End::Client(client_write)));
    match (forward, back) {
        (Ok(forward), Ok(back)) => {
            // Any direction ends by its own read; the socket shutdowns a stop
            // sweeps in (or the peers' ends) arrive as reads waking. A panic
            // in a pump only ends its connection; its cleanup is this join.
            let _ = forward.join();
            let _ = back.join();
            drop(client);
            drop(guest);
        }
        (forward, back) => {
            // One direction thread did not start (fd or thread limits). The
            // running one waits forever on an end nobody reads, so both
            // sockets shut down first — the same shutdowns
            // SocketSplice.cancel uses to end its threads
            // (LoopbackListener.swift:111-117) — and whatever did start is
            // joined out of the way.
            let _ = client.shutdown(Shutdown::Both);
            let _ = guest.shutdown(Shutdown::Both);
            if let Ok(thread) = forward {
                let _ = thread.join();
            }
            if let Ok(thread) = back {
                let _ = thread.join();
            }
            let cause = std::io::Error::last_os_error();
            drop(client);
            drop(guest);
            live.note(RelayError::Listen(cause));
            live.retire(id);
        }
    }
    live.retire(id);
}

/// A connection whose machinery could not be built, before any direction ran:
/// the pieces close and the failure is noted, with the registration leaving
/// the same way the Mac's accept path leaves a failed fetch — the socket
/// closes, the loop keeps on (ADBForwarder.swift:66-68).
fn setup_failed(live: &Shared, id: u64, cause: std::io::Error, client: TcpStream, guest: UnixStream) {
    live.failures.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).push(RelayError::Listen(cause));
    drop(client);
    drop(guest);
    live.retire(id);
}

/// One direction's copy loop, the Mac's SocketSplice.pump: read from one
/// socket, write the whole read into the other, repeat; the 64 KiB buffer is
/// the Mac's own size and "blocking reads and writes ... give natural
/// backpressure (an `adb push` of a large file never piles up in memory)"
/// (LoopbackListener.swift:85-88, 119-122). At the pump's end the direction
/// passes the end of the stream on: write side of the destination off first,
/// then the source's read side, so the reverse direction still runs after it
/// (LoopbackListener.swift:133-135).
fn pump(mut source: End, mut dest: End) {
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        match source.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                // Everything read goes down all the way before the next read:
                // no pending bytes anywhere, the backpressure being the write
                // itself. write_all works through Interrupted on its own, and
                // an end here lands where the Mac's inner write loop lands
                // (LoopbackListener.swift:125-131): the pump's end.
                if dest.write_all(&buffer[..count]).is_err() {
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => {} // retry at once
            Err(_) => break, // the Mac's guard count > 0 else break (LoopbackListener.swift:124)
        }
    }
    // Pass the end of the stream on; the other direction may still run.
    dest.shutdown(Shutdown::Write);
    source.shutdown(Shutdown::Read);
}

/// One side of a splice: the TCP client's socket or the guest's raw vsock.
/// The wire crosses unchanged either way — the Mac's splice holds plain raw
/// descriptors too (LoopbackListener.swift:89-105).
enum End {
    Client(TcpStream),
    Guest(UnixStream),
}

impl Read for End {
    fn read(&mut self, into: &mut [u8]) -> std::io::Result<usize> {
        match self {
            End::Client(stream) => stream.read(into),
            End::Guest(stream) => stream.read(into),
        }
    }
}

impl Write for End {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        match self {
            End::Client(stream) => stream.write(bytes),
            End::Guest(stream) => stream.write(bytes),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            End::Client(stream) => stream.flush(),
            End::Guest(stream) => stream.flush(),
        }
    }
}

impl End {
    /// Both ends shut the same way; the pump passes a direction's end on with
    /// these (LoopbackListener.swift:133-135).
    fn shutdown(&self, which: Shutdown) {
        match self {
            End::Client(stream) => {
                let _ = stream.shutdown(which);
            }
            End::Guest(stream) => {
                let _ = stream.shutdown(which);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::sync::mpsc;
    use std::time::Instant;

    /// One newline-terminated line, at most 64 bytes, read whole: the vsock
    /// tests' reader (src/vsock.rs's `line`), minus the empty-at-None shape —
    /// a handshake ledger is the only use here.
    fn line(stream: &mut UnixStream) -> String {
        let mut bytes = Vec::new();
        loop {
            if bytes.len() >= 64 {
                break;
            }
            let mut byte = [0u8; 1];
            match stream.read(&mut byte) {
                Ok(count) if count > 0 => bytes.push(byte[0]),
                _ => break,
            }
            if bytes.last() == Some(&b'\n') {
                break;
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// The engine's socket-device half as a test stands it up (the engine's
    /// own binds and takes every stream: engine/hvf/vmm/src/virtio/
    /// vsock.rs:195-201): one socket path per `FakeGuest`, one accept thread
    /// per `expect`. The handshake's `CONNECT` line comes back through the
    /// channel before the script owns the raw stream, so a test asserts the
    /// wire itself rather than a stand-in's behaviour.
    struct FakeGuest {
        path: PathBuf,
        listener: UnixListener,
    }

    impl FakeGuest {
        fn new() -> FakeGuest {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
            let path = std::env::temp_dir().join(format!(
                "avod-adb-guest-{}-{}.sock",
                std::process::id(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            FakeGuest {
                path: path.clone(),
                listener: UnixListener::bind(&path).unwrap(),
            }
        }

        fn vsock(&self) -> Vsock {
            Vsock::at(&self.path)
        }

        /// One connection's handler, run on its own thread: the accepted
        /// stream's `CONNECT` line goes to the channel first, then `script`
        /// speaks the handshake's answer — `OK <port>\n` or `ERROR …\n` — and
        /// the raw phase.
        fn expect(&self, script: impl FnOnce(&mut UnixStream) + Send + 'static) -> mpsc::Receiver<String> {
            let listener = self.listener.try_clone().unwrap();
            let (sender, receiver) = mpsc::channel();
            std::thread::Builder::new()
                .name("avod-adb-test-guest".into())
                .spawn(move || {
                    let (mut stream, _) = listener.accept().unwrap();
                    sender.send(line(&mut stream)).expect("a test waits on its handshake line");
                    script(&mut stream);
                })
                .unwrap();
            receiver
        }
    }

    /// Bounded wait for a state the accept loop's own thread changes: the
    /// registration and the ledger are that thread's, so a test polls at the
    /// tick's pace and fails rather than hangs when nothing lands.
    fn wait_for(what: &str, until: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !until() {
            if Instant::now() > deadline {
                panic!("the relay never {what}");
            }
            std::thread::sleep(TICK);
        }
    }

    /// A guest that answers the handshake and then reads to the bitter end —
    /// the pump's own shutdown of that direction arrives as this read's end,
    /// whatever ends it, so a test can watch even a teardown's ...
    fn echo_handshake_ok(stream: &mut UnixStream) {
        stream.write_all(b"OK 1024\n").unwrap();
    }

    #[test]
    fn bytes_flow_both_ways_until_a_half_close_ends_the_connection() {
        let guest = FakeGuest::new();
        let (bytes_sender, bytes_taken) = mpsc::channel();
        let handshake = guest.expect(move |stream| {
            echo_handshake_ok(stream);
            // The client's whole send, then the relay's half close: read to
            // the end, not to a chunk size, because a split among the pumps'
            // reads is the relay's own business.
            let mut taken = Vec::new();
            stream.read_to_end(&mut taken).unwrap();
            bytes_sender.send(taken).unwrap();
            // The reply rides the reverse direction, which the Mac's splice
            // keeps alive for exactly this case: the client already half
            // closed. Dropping the stream ends it.
            stream.write_all(b"hello from the guest\n").unwrap();
        });
        let mut relay = relay(bind(0).unwrap(), guest.vsock()).unwrap();
        let mut client = TcpStream::connect(relay.local_addr()).unwrap();
        client.write_all(b"hi from the client\n").unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        // A client's connect is what sends the relay to the guest: its
        // CONNECT line comes back through that connection's handler.
        assert_eq!(handshake.recv_timeout(Duration::from_secs(5)).unwrap(), "CONNECT 5555\n");
        let mut back = Vec::new();
        client.read_to_end(&mut back).unwrap();
        assert_eq!(back, b"hello from the guest\n");
        assert_eq!(bytes_taken.recv_timeout(Duration::from_secs(5)).unwrap(), b"hi from the client\n");
        relay.join().unwrap();
        assert_eq!(relay.sessions(), 0);
        assert!(relay.failures().is_empty());
    }

    #[test]
    fn concurrent_connections_keep_their_own_guest_streams() {
        let guest = FakeGuest::new();
        // Both handlers echo: whatever that connection alone carried comes
        // back down that same connection, so any mixing shows up as a
        // client's own echo carrying another client's bytes.
        let echo = |stream: &mut UnixStream| {
            echo_handshake_ok(stream);
            let mut taken = Vec::new();
            stream.read_to_end(&mut taken).unwrap();
            stream.write_all(&taken).unwrap();
        };
        let first_handshake = guest.expect(move |stream| echo(stream));
        let second_handshake = guest.expect(move |stream| echo(stream));
        let mut relay = relay(bind(0).unwrap(), guest.vsock()).unwrap();
        let mut first = TcpStream::connect(relay.local_addr()).unwrap();
        let mut second = TcpStream::connect(relay.local_addr()).unwrap();
        first.write_all(b"first\n").unwrap();
        second.write_all(b"second\n").unwrap();
        first.shutdown(Shutdown::Write).unwrap();
        second.shutdown(Shutdown::Write).unwrap();
        let mut back = Vec::new();
        first.read_to_end(&mut back).unwrap();
        assert_eq!(back, b"first\n");
        let mut back = Vec::new();
        second.read_to_end(&mut back).unwrap();
        assert_eq!(back, b"second\n");
        assert_eq!(first_handshake.recv_timeout(Duration::from_secs(5)).unwrap(), "CONNECT 5555\n");
        assert_eq!(second_handshake.recv_timeout(Duration::from_secs(5)).unwrap(), "CONNECT 5555\n");
        relay.join().unwrap();
        assert_eq!(relay.sessions(), 0);
        assert!(relay.failures().is_empty());
    }

    #[test]
    fn a_refused_guest_is_surfaced_per_connection_and_the_loop_keeps_accepting() {
        let guest = FakeGuest::new();
        // Both refusals are the engine's exact line when the guest has reset
        // the connect (engine/hvf/vmm/src/virtio/vsock.rs:557-560), which
        // src/vsock.rs maps to ConnectionRefused.
        let refuse = |stream: &mut UnixStream| stream.write_all(b"ERROR connection refused\n").unwrap();
        let first_handshake = guest.expect(move |stream| refuse(stream));
        let second_handshake = guest.expect(move |stream| refuse(stream));
        let mut relay = relay(bind(0).unwrap(), guest.vsock()).unwrap();
        let mut first = TcpStream::connect(relay.local_addr()).unwrap();
        wait_for("note the first refusal", || relay.failures().len() == 1);
        // The first client saw a closed connection, not an error or a wire
        // half message: the socket just closes (ADBForwarder.swift:66-68).
        let mut taken = Vec::new();
        first.read_to_end(&mut taken).unwrap();
        assert!(taken.is_empty());
        // The loop lives through refusals: the second connect is processed
        // with the ledger at one, so no stop was ever asked for between them.
        let mut second = TcpStream::connect(relay.local_addr()).unwrap();
        wait_for("note the second refusal", || relay.failures().len() == 2);
        let mut taken = Vec::new();
        second.read_to_end(&mut taken).unwrap();
        assert!(taken.is_empty());
        assert_eq!(first_handshake.recv_timeout(Duration::from_secs(5)).unwrap(), "CONNECT 5555\n");
        assert_eq!(second_handshake.recv_timeout(Duration::from_secs(5)).unwrap(), "CONNECT 5555\n");
        relay.join().unwrap();
        let failures = relay.failures();
        assert_eq!(failures.len(), 2);
        for failure in &failures {
            let RelayError::GuestUnreachable(cause) = failure else {
                panic!("a refusal is GuestUnreachable, not {failure:?}");
            };
            assert_eq!(cause.kind(), ErrorKind::ConnectionRefused);
        }
        assert_eq!(relay.sessions(), 0);
    }

    #[test]
    fn a_stop_token_and_a_drop_end_the_relay_and_its_threads() {
        // Part one, the stop token: a splice stands open — a fake adbd that
        // reads until the end and a client holding its socket — and no
        // peer's own end will ever relieve it.
        let guest = FakeGuest::new();
        let (ended_sender, ended) = mpsc::channel();
        let handshake = guest.expect(move |stream| {
            echo_handshake_ok(stream);
            let mut byte = [0u8; 1];
            loop {
                if let Ok(0) | Err(_) = stream.read(&mut byte) {
                    break;
                }
            }
            // The relay's shutdown of that direction arrives here as this
            // end; the fake's own thread leaving proves the connection came
            // down, not just the relay's side of it.
            ended_sender.send(()).unwrap();
        });
        let mut held = relay(bind(0).unwrap(), guest.vsock()).unwrap();
        let mut client = TcpStream::connect(held.local_addr()).unwrap();
        // The client's connect is what sends the relay to the guest.
        assert_eq!(handshake.recv_timeout(Duration::from_secs(5)).unwrap(), "CONNECT 5555\n");
        wait_for("enter the splice", || held.sessions() == 1);
        assert_eq!(held.stop(), Ok(()));
        assert_eq!(held.stop(), Err(RelayError::Closed));
        let started = Instant::now();
        assert_eq!(held.join(), Ok(()));
        assert!(started.elapsed() < Duration::from_secs(5));
        // The client reads the relay's shut write side as its own end.
        let mut taken = Vec::new();
        client.read_to_end(&mut taken).unwrap();
        assert!(taken.is_empty());
        ended.recv_timeout(Duration::from_secs(5)).unwrap();

        // Part two, the same teardown from a plain drop: the stop runs, the
        // splice's shutdowns land, and the port goes away — none of it
        // hanging the test, since a drop cannot join anything.
        let guest = FakeGuest::new();
        let (ended_sender, ended) = mpsc::channel();
        let _handshake = guest.expect(move |stream| {
            echo_handshake_ok(stream);
            let mut byte = [0u8; 1];
            loop {
                if let Ok(0) | Err(_) = stream.read(&mut byte) {
                    break;
                }
            }
            ended_sender.send(()).unwrap();
        });
        let mut dropped = relay(bind(0).unwrap(), guest.vsock()).unwrap();
        let address = dropped.local_addr();
        let _client = TcpStream::connect(address).unwrap();
        wait_for("enter the splice", || dropped.sessions() == 1);
        drop(dropped);
        // The loop's listener goes with the drop: connecting lands on nothing.
        wait_for("wait the port shut", || {
            matches!(TcpStream::connect(address), Err(ref error) if error.kind() == ErrorKind::ConnectionRefused)
        });
        // The live splice's sockets went down with the same sweep: the fake's
        // reads end.
        ended.recv_timeout(Duration::from_secs(5)).unwrap();
    }

    #[test]
    fn a_taken_port_fails_to_bind() {
        // The taken port is the Mac's own user voice — "Port N is already in
        // use by another app. Choose another port." (ADBForwarder.swift:47).
        let taken = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = taken.local_addr().unwrap().port();
        let error = bind(port).unwrap_err();
        let RelayError::Bind(cause) = &error else {
            panic!("a taken port is Bind, not {error:?}");
        };
        assert_eq!(cause.kind(), ErrorKind::AddrInUse);
        assert!(error.to_string().contains("cannot be bound"));
    }
}
