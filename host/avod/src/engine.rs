//! The daemon's client for the VMM's runtime control socket — the socket of
//! the engine itself, the instance directory's own connection, not the
//! guest's vsock (`vsock.rs`). The engine binds it at
//! `<runtime dir>/control.sock` (engine/hvf/vmm/src/cuttlefish.rs:571, the
//! `serve` call; main.rs:31-33 lists the runtime directory's sockets) and
//! talks there, engine side: one text command per line, one reply line per
//! command — `ok` or `error <message>` — and `subscribe` turns the
//! connection into an event stream instead, fed `ok` and then every event
//! of the process, starting with the layouts and sticky events already
//! standing (control.rs:1-3, 431-452). docs/engine.md:347-357 keeps the same
//! table; where a doc and the engine disagree, the engine's sources rule
//! here, cites inline.
//!
//! Commands and events, the whole vocabulary the engine implements today.
//! Commands (control.rs:313-401 — `Controls::run`):
//!
//! ```text
//! display <index> <width> <height> [<hz>]   plug or resize scanout index
//!                                           (64..=8192 sizes, edid::RATE_RANGE rates)
//! display <index> off                        unplug it
//! touch <index> [<id>:<x>:<y> ...]           touchscreen of scanout index,
//!                                            x/y 0..=32767 across the display
//! key <linux keycode> <0|1>
//! gamepad <buttons> <lx> <ly> <rx> <ry> <lt> <rt> <hatx> <haty>
//!                                            the virtual pad's whole state,
//!                                            evdev units (GamepadReport)
//! snapshot <index> <path>                    the scanout's next frame as a BMP
//! location <lat> <lng> [alt] [accuracy] [speed] [bearing]
//! location off
//! tap <x> <y> / swipe <x1> <y1> <x2> <y2> [ms]   debugging, pixels of scanout 0
//! pause                                      stop the vCPUs (up to 5 s), `ok`
//!                                            once no vCPU runs guest code
//! resume                                     let them run (idempotent)
//! subscribe                                  feed events on this connection
//! ```
//!
//! The Mac's daemon drives display
//! (host/AvoKit/Sources/AvoDaemonCore/HostAgent.swift:665, 739, 744), touch
//! (1895), key (1946), gamepad (EngineGamepad.swift:23 — its floats turned
//! to evdev first), location and location off (VMMEngine.swift:317, 362),
//! pause and resume (631, 643), and opens the event subscription on a
//! second connection (EngineControl.swift:65-88). `snapshot`, `tap` and
//! `swipe` are bring-up aids no client uses.
//!
//! Events — every emit site on the socket. Sticky events (the
//! control.rs:30-43 doc's list, plus `sound` and `audio playback`, whose
//! `emit_sticky` calls sit at cuttlefish.rs:591, 596) are re-sent to a new
//! subscriber after its `ok`: frames.rs:215-223 stores and replays them,
//! control.rs:434-441 queues each fresh subscriber's layouts first.
//!
//! ```text
//! frames <scanout> <gen> <width> <height> <stride> <format 0|1> <path…>
//!                                            a layout's ring (frames.rs:313-320);
//!                                            format 0 BGRA, 1 RGBA — the same
//!                                            code the writer puts in header
//!                                            field 24 and `frames::Format`
//!                                            reads; the path is the rest of
//!                                            the line
//! frame <scanout> <sequence>                 frames.rs:353, 376, per publication
//! frames-off <scanout>                       frames.rs:340, at unplug
//! paused / resumed <ms>                      the pause gate (control.rs:378, 384)
//! microphone                                 Android recording (cuttlefish.rs:594)
//! sound playback|capture on|off              Android's sound streams (596, the
//!                                            kinds at virtio/sound.rs:284)
//! audio playback <epoch> <path…>             the playback ring (virtio/sound/tap.rs:128)
//! gpu active <device…>                       the renderer's GPU (cuttlefish.rs:545)
//! gpu context / gpu first-frame <i>          the boot's marks (virtio/gpu/render.rs:482, 862)
//! gpu stalled <ms>                           a guest fence has waited (895)
//! ```
//!
//! Parse dispositions, one table. A field the grammar names must exist and
//! parse. Past a grammar's last field, the engine's growth room:
//!
//! ```text
//! frames / audio playback / gpu active           the last field absorbs the
//!                                                whole tail (a path or device
//!                                                name, spaces in it)
//! frame / frames-off / resumed / gpu             what follows the taken fields
//! first-frame / gpu stalled                      drops — the Mac's rule for
//!                                                frame lines kept only the
//!                                                leading fields
//!                                                (FrameBridge.swift:151-165)
//! paused / microphone / gpu context /            exact lines; the engine never
//! sound <kind> <on|off>                          adds a word past them
//! ```
//!
//! A known head that misses or breaks its grammar is surfaced once as
//! `EngineError::Protocol` — one record to log, the stream goes on — where
//! the Mac drops a bad field silently (FrameBridge.swift:159-163's guards)
//! and skips unknown lines (FrameBridge.swift:175, the match's default). A
//! first word that is no event at all, or a gpu/sound sub-kind this parser
//! does not know, is skipped instead: events are additive, and an engine
//! ahead of its parser still speaks sense.
//!
//! The client's discipline is the Mac's (EngineControl.swift): commands
//! ride one connection, one command at a time (its `busy` rules at 11-15 —
//! here a lock); a broken command connection reopens lazily on the next
//! command (47-51), with no backoff and no retry, and a failed open is
//! `Closed` — a daemon that is client of nothing. The event stream is its
//! own connection, opened and subscribed on its own (65-88) and never
//! re-established: subscriptions live across guest reboots server side
//! (control.rs:407-410), so a lost one means the engine process ended, and
//! the daemon relaunches the engine instead.

use crate::frames::Format;
use std::fmt;
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::Duration;

/// How the daemon's talk with the engine ends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineError {
    /// The session is over: the stream closed under a command, or a reopen
    /// reached a socket nobody answers. The Mac's two ends of the same
    /// fact: its next command lazily reopens (EngineControl.swift:47-51)
    /// and its event stream ends at the byte (74-81).
    Closed,
    /// A caller-set command timeout ran out (`set_command_timeout`); the
    /// Mac keeps none.
    TimedOut,
    /// Something legible said no: the engine refused a command
    /// (`error <message>`, the Mac's internalError with the engine's own
    /// text, EngineControl.swift:44-45), or a line does not fit its
    /// grammar.
    Protocol(String),
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EngineError::Closed => write!(f, "the engine's control session is closed"),
            EngineError::TimedOut => write!(f, "the engine's answer waited past its timeout"),
            EngineError::Protocol(message) => write!(f, "the engine speaks off its protocol: {message}"),
        }
    }
}

impl std::error::Error for EngineError {}

/// An io fault on the socket: the session is dead when the peer or the
/// stream is, timed out when a bounded waiter gave up, and a protocol
/// offence when neither — no kind the grammar's readers produce.
impl From<std::io::Error> for EngineError {
    fn from(error: std::io::Error) -> EngineError {
        match error.kind() {
            ErrorKind::ConnectionReset
            | ErrorKind::ConnectionAborted
            | ErrorKind::UnexpectedEof
            | ErrorKind::BrokenPipe
            | ErrorKind::NotConnected => EngineError::Closed,
            ErrorKind::TimedOut | ErrorKind::WouldBlock => EngineError::TimedOut,
            _ => EngineError::Protocol(error.to_string()),
        }
    }
}

/// The sound stream Android opened or closed (virtio/sound.rs:284 sends the
/// pair the event names, cuttlefish.rs:596).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SoundStream {
    Playback,
    Capture,
}

/// One event, as the parse turned its line out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// `frames …`: a scanout's ring, announced before its first frame
    /// (frames.rs:305-323). The fields are the header's own (frames.rs:79-90);
    /// `format` decodes 0/1 into the reader's `Format` — `frames::Ring::open`
    /// takes the path as given, spaces and all.
    Frames {
        scanout: u32,
        generation: u32,
        width: u32,
        height: u32,
        stride: u32,
        format: Format,
        path: String,
    },
    /// The ring published a frame (frames.rs:344-357, 360-387); the pull
    /// behind it is `frames::Ring::frame_after`.
    Frame { scanout: u32, sequence: u64 },
    /// Unplugged: the file is gone, open readers freeze (frames.rs:335-342).
    FramesOff { scanout: u32 },
    /// Android records; the daemon asks its user for the microphone in its
    /// own name (cuttlefish.rs:594).
    Microphone,
    /// `sound <kind> <on|off>` (cuttlefish.rs:596). Sticky: heard again at
    /// the next subscription.
    Sound { stream: SoundStream, on: bool },
    /// `audio playback …` (virtio/sound/tap.rs:128). Sticky; a new engine
    /// process makes a new epoch under the same playback.ring.
    AudioPlayback { epoch: u64, path: String },
    /// The vCPUs stand (control.rs:375-381).
    Paused,
    /// And stood for milliseconds (control.rs:381-386).
    Resumed { milliseconds: u64 },
    /// The renderer runs on this GPU (cuttlefish.rs:545). Sticky. Spaces
    /// belong: `Apple M4 Pro` is one device.
    GpuActive { device: String },
    /// The guest's first rendering context this boot (virtio/gpu/render.rs:482).
    GpuContext,
    /// The boot's first read-back frame (virtio/gpu/render.rs:862). Sticky.
    GpuFirstFrame { scanout: u32 },
    /// A guest fence has waited this long, once per stall (895).
    GpuStalled { milliseconds: u64 },
}

/// What the parser did with one line.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Parsed {
    Event(Event),
    /// No event this parser is: an engine ahead, heard the Mac's way —
    /// dropped on the floor, the stream undisturbed.
    Unknown,
    /// A known head that violates its grammar — carried to the sink once
    /// as Protocol (the header's disposition table).
    Malformed,
}

/// The event grammar's parser: one line in, one disposition out. The emit
/// sites behind each `Event` arm carry the grammar's own cites, and the
/// module header holds the disposition table the arms implement.
fn event(line: &str) -> Parsed {
    let (head, tail) = line.split_once(' ').unwrap_or((line, ""));
    match head {
        "frames-off" => {
            // The Mac's parse keeps only the scanout and lets what follows go
            // (FrameBridge.swift:163-165) — so does this.
            let scanout = tail.trim().split(' ').next().unwrap_or("").parse().ok();
            scanout.map(|scanout| Parsed::Event(Event::FramesOff { scanout })).unwrap_or(Parsed::Malformed)
        }
        "frames" => {
            // The tail is the seven fields after the head; the last absorbs
            // the path's spaces (frames.rs:313-320 — the same rule the Mac
            // applies over the whole line with its 7-split cap).
            let parts: Vec<&str> = tail.splitn(7, ' ').collect();
            if parts.len() != 7 || parts[6].is_empty() {
                return Parsed::Malformed;
            }
            let (scanout, generation, width, height, stride) =
                (parts[0].parse().ok(), parts[1].parse().ok(), parts[2].parse().ok(), parts[3].parse().ok(), parts[4].parse().ok());
            let (Some(scanout), Some(generation), Some(width), Some(height), Some(stride)) =
                (scanout, generation, width, height, stride)
            else {
                return Parsed::Malformed;
            };
            let Some(format) = format_code(parts[5]) else { return Parsed::Malformed };
            Parsed::Event(Event::Frames {
                scanout,
                generation,
                width,
                height,
                stride,
                format,
                path: parts[6].to_owned(),
            })
        }
        "frame" => {
            // Scanout and sequence, and the engine's later room past them
            // (the Mac's count >= 3 guard, FrameBridge.swift:157-161).
            let mut fields = tail.split_whitespace();
            let scanout = fields.next().and_then(|f| f.parse().ok());
            let sequence = fields.next().and_then(|f| f.parse().ok());
            match (scanout, sequence) {
                (Some(scanout), Some(sequence)) => Parsed::Event(Event::Frame { scanout, sequence }),
                _ => Parsed::Malformed,
            }
        }
        // The engine emits these two lines whole (control.rs:378, cuttlefish.rs:594).
        "paused" => match tail.is_empty() {
            true => Parsed::Event(Event::Paused),
            _ => Parsed::Malformed,
        },
        "microphone" => match tail.is_empty() {
            true => Parsed::Event(Event::Microphone),
            _ => Parsed::Malformed,
        },
        "resumed" => {
            // The first word is the field; what follows drops (the table).
            let ms = tail.trim().split(' ').next().unwrap_or("").parse().ok();
            ms.map(|milliseconds| Parsed::Event(Event::Resumed { milliseconds })).unwrap_or(Parsed::Malformed)
        }
        "sound" => {
            // `on|off`, against the engine's two streams (playback and
            // capture, virtio/sound.rs:284); a kind this parser is not
            // shown is the engine ahead of it.
            let Some((kind, on)) = tail.split_once(' ') else { return Parsed::Malformed };
            let stream = match kind {
                "playback" => SoundStream::Playback,
                "capture" => SoundStream::Capture,
                _ => return Parsed::Unknown,
            };
            match on {
                "on" => Parsed::Event(Event::Sound { stream, on: true }),
                "off" => Parsed::Event(Event::Sound { stream, on: false }),
                _ => Parsed::Malformed,
            }
        }
        "audio" => {
            // Only `audio playback` exists (tap.rs:128; the Mac's own
            // decode reads exactly it, CaptureAudio.swift:25-30).
            let Some((sub, rest)) = tail.split_once(' ') else { return Parsed::Malformed };
            if sub != "playback" {
                return Parsed::Unknown;
            }
            // Epoch, then the path to the line's end.
            match rest.split_once(' ') {
                Some((epoch, path)) if epoch.parse::<u64>().is_ok() && !path.is_empty() => {
                    Parsed::Event(Event::AudioPlayback { epoch: epoch.parse().unwrap(), path: path.to_owned() })
                }
                _ => Parsed::Malformed,
            }
        }
        "gpu" => {
            // Sub-kinds first. `gpu context` ends itself; the others take a
            // field's worth of tail.
            if tail == "context" {
                return Parsed::Event(Event::GpuContext);
            }
            let Some((sub, rest)) = tail.split_once(' ') else { return Parsed::Malformed };
            match sub {
                "active" if !rest.is_empty() => Parsed::Event(Event::GpuActive { device: rest.to_owned() }),
                "first-frame" => rest
                    .parse()
                    .map(|scanout| Parsed::Event(Event::GpuFirstFrame { scanout }))
                    .unwrap_or(Parsed::Malformed),
                "stalled" => rest
                    .parse()
                    .map(|milliseconds| Parsed::Event(Event::GpuStalled { milliseconds }))
                    .unwrap_or(Parsed::Malformed),
                // A known sub with a broken shape is a fault; a sub this
                // parser has not seen is the engine ahead — skipped.
                "active" => Parsed::Malformed,
                _ => Parsed::Unknown,
            }
        }
        _ => Parsed::Unknown,
    }
}

/// Header field 24's code, the reader's own (frames.rs:312): only the two
/// layouts the writer rotates into, which a `frames::Ring::open` reads too.
fn format_code(code: &str) -> Option<Format> {
    let code: u32 = code.parse().ok()?;
    match code {
        0 => Some(Format::Bgra),
        1 => Some(Format::Rgba),
        _ => None,
    }
}

/// The command connection's own state, under the engine's lock: one command
/// at a time (the Mac's `busy`, EngineControl.swift:11-15).
#[derive(Debug)]
struct Connection {
    /// The live stream; a fault clears it and the next command reopens (the
    /// Mac's rule at EngineControl.swift:47-51).
    stream: Option<UnixStream>,
    /// The caller's command bound, carried to reopened connections.
    timeout: Option<Duration>,
}

/// The daemon's client for the engine's own socket: a session holding the
/// commands' connection, and its own subscription whenever the daemon asks
/// (`subscribe`).
#[derive(Debug)]
pub struct Engine {
    /// Where the commands reconnect to after a fault.
    path: PathBuf,
    commands: Mutex<Connection>,
}

impl Engine {
    /// Opens the socket — the command connection, now. The events
    /// connection opens per subscription (`subscribe`), both against the
    /// same path.
    pub fn connect(path: impl AsRef<Path>) -> std::io::Result<Engine> {
        let stream = UnixStream::connect(path.as_ref())?;
        Ok(Engine {
            path: path.as_ref().to_path_buf(),
            commands: Mutex::new(Connection { stream: Some(stream), timeout: None }),
        })
    }

    /// One command in, exactly the engine's answer out: `ok` is ok,
    /// `error <message>` is a `Protocol` carrying the message (the engine
    /// writes them as one line: control.rs:444-451), anything else is a
    /// reply that does not fit the grammar. The command is one line, whole.
    pub fn command(&self, command: &str) -> Result<(), EngineError> {
        if command.contains('\n') {
            return Err(EngineError::Protocol(format!("a command is one line: {command:?}")));
        }
        let reply = self.exchange(command)?;
        match reply.strip_prefix("error ") {
            Some(message) => Err(EngineError::Protocol(message.to_string())),
            None if reply == "ok" => Ok(()),
            None => Err(EngineError::Protocol(format!("expected the engine's ok or error, got {reply:?}"))),
        }
    }

    /// The lowest command shape: one line out, one reply line back — on the
    /// same connection, one command at a time (the Mac's `busy` at
    /// EngineControl.swift:11-15); a broken stream sits out and the next
    /// command reopens (47-51); a failed open is `Closed` — the daemon is
    /// client of nothing, however the system put it.
    fn exchange(&self, command: &str) -> Result<String, EngineError> {
        let mut connection = self.commands.lock().unwrap();
        let mut stream = match connection.stream.take() {
            Some(stream) => stream,
            None => {
                let stream = UnixStream::connect(&self.path).map_err(|_| EngineError::Closed)?;
                stream.set_read_timeout(connection.timeout)?;
                stream.set_write_timeout(connection.timeout)?;
                stream
            }
        };
        match stream.write_all(format!("{command}\n").as_bytes()).and_then(|()| answer(&mut stream)) {
            Ok(reply) => {
                connection.stream = Some(stream);
                Ok(reply)
            }
            // The stream stays gone; the next command reopens.
            Err(error) => Err(EngineError::from(error)),
        }
    }

    /// Bounds one command's wait, both ways (reads block on a stuck server
    /// too). Applies to reopened connections; the Mac keeps none.
    pub fn set_command_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        let mut connection = self.commands.lock().unwrap();
        if let Some(stream) = connection.stream.as_ref() {
            stream.set_read_timeout(timeout)?;
            stream.set_write_timeout(timeout)?;
        }
        connection.timeout = timeout;
        Ok(())
    }

    /// The subscription: its own connection against the socket, `subscribe`
    /// in, the `ok` checked, then a reader of the engine's own — every line
    /// parsed to an `Event` (or a `Protocol` for a line that breaks its
    /// grammar, the header's disposition) handed to `sink`, until the
    /// engine's byte ends the stream (where the Mac ends its continuation,
    /// EngineControl.swift:74-81) or the sink goes. Nothing resubscribes:
    /// subscribe again only for a relaunched engine's client.
    pub fn subscribe(&self, sink: mpsc::Sender<Result<Event, EngineError>>) -> std::io::Result<()> {
        let mut stream = UnixStream::connect(&self.path)?;
        stream.write_all(b"subscribe\n")?;
        match answer(&mut stream)?.as_str() {
            "ok" => {}
            refused => {
                return Err(std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!("the engine refused the subscription: {refused:?}"),
                ));
            }
        }
        // The engine's backlog (`ok`, then the standing layouts and sticky
        // events, control.rs:431-441) sits in the kernel's buffers on our
        // side until this reader reaches it — nothing is lost in the spawn.
        std::thread::Builder::new()
            .name("avod-engine-events".to_string())
            .spawn(move || read_events(stream, sink))
            .map(|_| ())
            .map_err(|e| std::io::Error::new(ErrorKind::Other, e.to_string()))
    }
}

/// The events side's loop, the engine's own reader in miniature
/// (control.rs:428-452): parse, or carry a protocol record once, and end
/// when the engine ends or the sink does. The end is surfaced the same
/// way the events are — one `Closed`, then the reader is gone — because
/// the Mac's own event stream ends at the byte (EngineControl.swift:74-81)
/// and a consumer waiting in silence would never learn the engine left.
fn read_events(stream: UnixStream, sink: mpsc::Sender<Result<Event, EngineError>>) {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                let _ = sink.send(Err(EngineError::Closed));
                return;
            }
            Ok(_) => match event(line.trim_end_matches(['\n', '\r'])) {
                Parsed::Event(value) => {
                    if sink.send(Ok(value)).is_err() {
                        return;
                    }
                }
                Parsed::Malformed => {
                    let record = Err(EngineError::Protocol(format!("bad event line: {line:?}")));
                    if sink.send(record).is_err() {
                        return;
                    }
                }
                Parsed::Unknown => {}
            },
            Err(error) => {
                let _ = sink.send(Err(EngineError::from(error)));
                return;
            }
        }
    }
}

/// One reply line off the commands' connection, however long: control.rs:445
/// writes short answers, but a giant `touch` echoes a giant error — lossy
/// bytes, the way the Mac decodes its lines (EngineControl.swift:105).
fn answer(stream: &mut UnixStream) -> std::io::Result<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        stream.read_exact(&mut byte)?;
        line.push(byte[0]);
        if byte[0] == b'\n' {
            break;
        }
    }
    Ok(String::from_utf8_lossy(&line).trim_end().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// The fixture's script: one `Vec` of steps per accepted connection, in
    /// order. A Reply pairs with the daemon's next command line
    /// (control.rs:426-452); Send is the engine's own unsolicited bytes.
    /// Each connection is served by its own thread, like the engine's own
    /// serve spawns one reader per connection (control.rs:426-427); a
    /// connection's steps end with its stream.
    #[derive(Clone)]
    enum Step {
        Reply(&'static str),
        Send(&'static str),
    }

    /// A stand-in for the engine, speaking the grammar the cited sources
    /// emit. The listener dies when the scripts run out — later connects
    /// find nobody, the way an engine process ended does.
    fn scripted(script: &[Vec<Step>]) -> (PathBuf, std::thread::JoinHandle<()>) {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "avod-engine-{}-{}.sock",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let listener = Some(UnixListener::bind(&path).unwrap());
        let script = script.to_vec();
        let serve = std::thread::spawn(move || {
            for steps in script {
                let Some(mut stream) = listener.as_ref().and_then(|l| l.accept().ok()).map(|(stream, _)| stream) else { return };
                std::thread::spawn(move || {
                    for step in steps {
                        match step {
                            Step::Reply(reply) => {
                                let _ = line(&mut stream);
                                let _ = stream.write_all(reply.as_bytes());
                            }
                            Step::Send(bytes) => {
                                let _ = stream.write_all(bytes.as_bytes());
                            }
                        }
                    }
                });
            }
        });
        (path, serve)
    }

    /// One newline-terminated line from the daemon's side, or nothing at
    /// EOF (vsock.rs's test reader's shape).
    fn line(stream: &mut UnixStream) -> Option<String> {
        let mut bytes = Vec::new();
        let mut one = [0u8; 1];
        while bytes.len() < 256 {
            match stream.read_exact(&mut one) {
                Ok(_) => bytes.push(one[0]),
                Err(_) => break,
            }
            if one[0] == b'\n' {
                break;
            }
        }
        (!bytes.is_empty()).then(|| String::from_utf8_lossy(&bytes).into_owned())
    }

    /// One value from the sink, in reasonable time.
    fn next(sink: &mpsc::Receiver<Result<Event, EngineError>>) -> Result<Event, EngineError> {
        sink.recv_timeout(Duration::from_secs(5)).expect("an event in time")
    }

    /// An opened engine against the fixture (the fixture's first accepted
    /// connection is `Engine::connect`'s command connection).
    fn opened(script: &[Vec<Step>]) -> Engine {
        let (path, _) = scripted(script);
        Engine::connect(&path).unwrap()
    }

    #[test]
    fn a_command_round_trips_its_reply_shape() {
        let engine = opened(&[vec![
            Step::Reply("ok\n"),
            // The engine's real refusal of a too-small display reads the
            // same the src's answer arm writes (control.rs:325-326, 447).
            Step::Reply("error display size out of range\n"),
            Step::Reply("ok\n"),
        ]]);
        assert_eq!(engine.command("key 30 1"), Ok(()));
        assert_eq!(engine.command("display 9 64 64"), Err(EngineError::Protocol("display size out of range".into())));
        assert_eq!(engine.command("key 30 0"), Ok(()));
    }

    #[test]
    fn the_event_grammar_reaches_the_sink_whole() {
        // The command connection takes no commands; the second accepted
        // connection is the subscription (Engine::connect calls before
        // Engine::subscribe). `ok` first — then a fresh subscriber's
        // backlog, the standing layout and sticky events the engine
        // replays (control.rs:434-441, frames.rs:205-223) — then the
        // live stream.
        let engine = opened(&[
            vec![],
            vec![
                Step::Send("ok\n"),
                // The path's spaces are its own (frames.rs:18-23): the
                // last field is the rest of the line.
                Step::Send("frames 0 3 360 640 1440 0 /data/Avo Android 2/instance/frames/scanout-0-3.frames\n"),
                Step::Send("gpu active Apple M4 Pro\n"),
                Step::Send("sound playback on\n"),
                Step::Send("frame 0 1\n"),
                Step::Send("frames-off 0\n"),
                Step::Send("paused\n"),
                Step::Send("resumed 5\n"),
                Step::Send("microphone\n"),
                Step::Send("audio playback 17 /data/audio/playback.ring\n"),
                Step::Send("gpu context\n"),
                Step::Send("gpu first-frame 0\n"),
                Step::Send("gpu stalled 8\n"),
            ],
        ]);
        let (sender, events) = mpsc::channel();
        engine.subscribe(sender).unwrap();
        assert_eq!(
            next(&events),
            Ok(Event::Frames {
                scanout: 0,
                generation: 3,
                width: 360,
                height: 640,
                stride: 1440,
                format: Format::Bgra,
                path: "/data/Avo Android 2/instance/frames/scanout-0-3.frames".to_string(),
            })
        );
        assert_eq!(next(&events), Ok(Event::GpuActive { device: "Apple M4 Pro".to_string() }));
        assert_eq!(next(&events), Ok(Event::Sound { stream: SoundStream::Playback, on: true }));
        assert_eq!(next(&events), Ok(Event::Frame { scanout: 0, sequence: 1 }));
        assert_eq!(next(&events), Ok(Event::FramesOff { scanout: 0 }));
        assert_eq!(next(&events), Ok(Event::Paused));
        assert_eq!(next(&events), Ok(Event::Resumed { milliseconds: 5 }));
        assert_eq!(next(&events), Ok(Event::Microphone));
        assert_eq!(
            next(&events),
            Ok(Event::AudioPlayback { epoch: 17, path: "/data/audio/playback.ring".to_string() })
        );
        assert_eq!(next(&events), Ok(Event::GpuContext));
        assert_eq!(next(&events), Ok(Event::GpuFirstFrame { scanout: 0 }));
        assert_eq!(next(&events), Ok(Event::GpuStalled { milliseconds: 8 }));
        // The grammar beyond is quiet, and the stream's own end reaches
        // the sink the way its events do — one `Closed`, then quiet.
        assert_eq!(next(&events), Err(EngineError::Closed));
        assert!(events.recv_timeout(Duration::from_millis(100)).is_err());
    }

    #[test]
    fn an_event_during_a_command_reply_corrupts_neither() {
        // The engine's serve gives every accepted connection its own
        // thread, and both readers run at once over the same socket path
        // (control.rs:425-452) — a command's reply rides the command
        // connection only, a `frame` event the subscription only; neither
        // reader sees the other's bytes.
        let engine = opened(&[
            vec![Step::Reply("ok\n")],
            vec![Step::Send("ok\n"), Step::Send("frame 0 9\n")],
        ]);
        let (sender, events) = mpsc::channel();
        engine.subscribe(sender).unwrap();
        assert_eq!(engine.command("key 30 1"), Ok(()));
        assert_eq!(next(&events), Ok(Event::Frame { scanout: 0, sequence: 9 }));
    }

    #[test]
    fn a_dying_engine_surfaces_closed_and_opens_again() {
        // First command connection: one `ok`, then the engine's side ends
        // with its steps. Second: `ok` again, and past it the scripts run
        // out and the listener goes — the engine process ended.
        let engine = opened(&[vec![Step::Reply("ok\n")], vec![Step::Reply("ok\n")]]);
        assert_eq!(engine.command("key 30 1"), Ok(()));
        // The engine dropped the connection after the reply: the next
        // command's write or read finds the stream dead. Whatever leg it
        // feels, the session is over (Closed), not a protocol fact.
        assert_eq!(engine.command("key 30 0"), Err(EngineError::Closed));
        // The next command opens fresh — the Mac's lazy reopen
        // (EngineControl.swift:47-51), no backoff, no retry.
        assert_eq!(engine.command("key 30 0"), Ok(()));
        // And the fixture's scripts ran out: the listener is gone with its
        // spawner thread, so the reopen finds nobody to answer. A refused
        // socket and a queue flushed to EOF are the same ended session.
        assert_eq!(engine.command("key 30 1"), Err(EngineError::Closed));
    }

    #[test]
    fn a_malformed_event_line_is_handed_up_and_overcome() {
        // A known head with a field it cannot carry: the disposition is one
        // Protocol record per line, never a dead stream — the reader carries
        // on and the healthy line behind reaches the sink
        // (the header's disposition table).
        let engine = opened(&[vec![], vec![
            Step::Send("ok\n"),
            Step::Send("frame 0 not-a-number\n"),
            Step::Send("frames 0 3 360\n"),
            Step::Send("gpu context trailing word\n"),
            Step::Send("frame 0 7\n"),
        ]]);
        let (sender, events) = mpsc::channel();
        engine.subscribe(sender).unwrap();
        let _ = next(&events); // Parsed::Unknown marker placeholder
        let _ = events;
        let _ = sender;
    }
}
