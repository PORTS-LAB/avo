//! The daemon's body: one process binding the engine's control socket, the
//! guest's control session, the ADB relay and the desktop's notification bus
//! into the loop the Mac runs across DaemonCore's decomposition
//! (host/AvoKit/Sources/AvoDaemonCore/DaemonCore.swift; its app-side half —
//! the menu bar, the Control Panel — is AvoDaemon/main.swift on the Mac and
//! phase 3's window-shim slices here).
//!
//! The routing law, one log line per class and never per frame:
//!
//! - `Notification` and `NotificationRemoved` are the presenter's calls
//!   (MacIntegrations.swift's `UserNotificationPresenter`; the notifications
//!   module is its local mirror). `app_name` carries the package raw: the Mac
//!   resolves display names through AvoKit's AppRegistry (AppRegistry.swift)
//!   and that registry is a later slice.
//! - The clipboard both ways is two later slices: the guest bridge is the
//!   avo-clipboard.jar the daemon's own ADB client pushes and drives
//!   (ClipboardHelper.swift:1 — the jar rides `app_process`, the later
//!   RSA-client slice), and the host side waits for the desktop clipboard
//!   API parked behind the Wayland/X11 open question in docs/linux-port.md.
//!   Both envelopes log their gap and move on.
//! - The control panel's and the shims' verbs (apps, displays, tasks,
//!   permissions, orientation) log as the named gaps they are: their
//!   consumers are phase 3's next slices.
//! - Any session end and any engine end is exit 2: the Mac's launchd keeps
//!   a failing daemon in rotation by restart (`KeepAlive
//!   { SuccessfulExit: false }`, host/Avo/LaunchAgents/dev.avo.daemon.plist;
//!   `RunAtLoad` for the load side), and systemd's `Restart=on-failure`
//!   restages this one the same way, so the body's only job is to die
//!   loudly enough for the restage to mean something.
//! - An engine nobody answers is exit 1: no crash loop without cause. The
//!   engine process's own spawn is the later, hardware-gated slice.
//!
//! The engine events fan out to log lines here and stop: the frame-ring
//! readers are the window shims' next phase, and the subscriber itself
//! stays open for their rings (engine.rs's header: rings are stateful per
//! subscription).
//!
//! The merged channel is this file's one concurrency claim: three sources
//! (the session's envelopes, the session's end, the engine's events) feed
//! one `mpsc` the loop reads, one forward thread per source. The forward
//! threads sit the process's whole uptime, which is fine: the process
//! `exit`s when the loop is done, and thread memory goes with it.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use crate::adb::{self, AdbRelay};
use crate::engine::{Engine, EngineError, Event};
use crate::notifications::{self, Presenter};
use crate::proto::{envelope, Envelope, Notification};
use crate::session::{ControlSession, Keepalive};
use crate::{ADB_PORT, CONTROL_PORT, vsock};

/// The daemon's own notion of where it lives. `runtime` is the engine's
/// socket directory (control.sock and vsock.sock siblings — the engine's
/// main.rs:32 lists them together and cuttlefish.rs:529 binds the vsock
/// one), `instance` the persistent data root, carried until the
/// app-registry and the state slices call for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub instance: PathBuf,
    pub runtime: PathBuf,
    pub adb_port: Option<u16>,
}

/// The defaults the flags may override: XDG as the repo already leans (the
/// GPUCache slice took the Mac's support dirs to XDG), and an honest error
/// when the session offers no `$XDG_RUNTIME_DIR` — a headless environment
/// gets no sockets directory of the daemon's invention; the packaging's
/// unit runs inside a session that sets it.
pub fn paths() -> Result<Config, String> {
    let home = std::env::var("HOME")
        .ok()
        .filter(|home| !home.is_empty())
        .ok_or("no $HOME and no --instance: where should the daemon put its data")?;
    let data = std::env::var("XDG_DATA_HOME")
        .ok()
        .filter(|data| !data.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(&home).join(".local/share"));
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|runtime| !runtime.is_empty())
        .map(PathBuf::from)
        .ok_or("no $XDG_RUNTIME_DIR and no --runtime: the daemon needs its sockets' directory")?;
    Ok(Config {
        instance: data.join("avo").join("default"),
        runtime: runtime.join("avod"),
        adb_port: None,
    })
}

const USAGE: &str = "usage: avod [--instance <dir>] [--runtime <dir>] [--adb-port <port>]";

/// The flag pass over the defaults. std and nothing else holds the parser,
/// the way the crate holds everything else: no argument crate is pulled in
/// for three flags.
pub fn cli(args: Vec<String>) -> Result<Config, String> {
    let mut config = paths()?;
    let mut seen = args.into_iter().peekable();
    seen.next(); // the binary's own name
    while let Some(flag) = seen.next() {
        match flag.as_str() {
            "--instance" => {
                config.instance = seen
                    .next()
                    .ok_or_else(|| format!("--instance needs a value; {USAGE}"))?
                    .into();
            }
            "--runtime" => {
                config.runtime = seen
                    .next()
                    .ok_or_else(|| format!("--runtime needs a value; {USAGE}"))?
                    .into();
            }
            "--adb-port" => {
                let port = seen
                    .next()
                    .ok_or_else(|| format!("--adb-port needs a value; {USAGE}"))?;
                config.adb_port = Some(
                    port.parse()
                        .map_err(|_| format!("--adb-port wants 1-65535, not {port:?}; {USAGE}"))?,
                );
            }
            other => return Err(format!("{other} is not a flag this daemon knows; {USAGE}")),
        }
    }
    Ok(config)
}

/// Who the notifications' calls reach. The seam keeps the tests' recorder
/// out of the desktop bus and lets a busless desktop carry on with the
/// journal naming the absence once (the notifications module's own
/// disabled state, `Presenter::open`'s `Bus`).
pub trait Notifies: Send + Sync {
    fn show(&self, notification: &Notification, app_name: &str);
    fn remove(&self, key: &str);
}

/// The trait over the real presenter: `Presenter::show` answers a Result,
/// the body logs what failed and carries on — the Mac's presenter is
/// fire-and-forget with its own error surfacing (MacIntegrations.swift).
impl Notifies for Presenter {
    fn show(&self, notification: &Notification, app_name: &str) {
        if let Err(error) = Presenter::show(self, notification, app_name) {
            eprintln!("avod: the desktop notification did not post: {error}");
        }
    }
    fn remove(&self, key: &str) {
        if let Err(error) = Presenter::remove(self, key) {
            eprintln!("avod: the desktop notification did not close: {error}");
        }
    }
}

/// The null desktop: no session bus was reachable at open time (the journal
/// named it once), so a show or a remove is nothing from here on.
pub struct NotificationsOff;

impl Notifies for NotificationsOff {
    fn show(&self, _notification: &Notification, _app_name: &str) {}
    fn remove(&self, _key: &str) {}
}

/// The clipboard arm's line, named once in the code like a case number
/// instead of spelled twice.
const CLIPBOARD_GAP: &str =
    "avod: the clipboard waits two slices: the guest bridge is the jar the daemon's own ADB client drives (ClipboardHelper.swift:1), the host side the desktop clipboard API (the Wayland/X11 open question in docs/linux-port.md)";

/// What the loop is told: the session's envelopes, the engine's events, and
/// the two lifecycle ends.
#[derive(Debug)]
pub enum BodyMsg {
    Session(Envelope),
    Engine(Event),
    /// The engine said a line off its grammar (engine.rs's disposition
    /// table carries it once to the sink): logged, stream undisturbed.
    EngineFault(String),
    /// The engine's event stream ended at the byte (engine.rs's design —
    /// the Mac's EngineControl.swift:74-81, the same end twice).
    EngineEnded,
    /// The session's keepalive has left the wire for good — goodbye, wire
    /// death, a broken gate fold into this one signal
    /// (`ControlSession::when_ended`).
    SessionEnded,
}

/// What the loop does with a message. `Carry` is the silent arm: per-frame
/// sequence traffic is too hot to log and does nothing until the shim phase
/// reads it.
#[derive(Debug)]
pub enum Decision {
    Show(Notification, String),
    Remove(String),
    Log(String),
    Carry,
    Ends(i32),
}

/// The routing's pure core: a message in, a decision out, no I/O of its
/// own — every rule above lives here and the tests prove each by name.
fn decide(msg: BodyMsg) -> Decision {
    match msg {
        BodyMsg::SessionEnded => Decision::Ends(2),
        BodyMsg::EngineEnded => Decision::Ends(2),
        BodyMsg::EngineFault(what) => {
            Decision::Log(format!("avod: the engine speaks off its grammar: {what}"))
        }
        BodyMsg::Engine(event) => match event {
            // Hot: one arrival per guest frame. The shims' rings read it
            // when they exist.
            Event::Frame { .. } => Decision::Carry,
            Event::Frames {
                scanout,
                generation,
                width,
                height,
                stride,
                format,
                path,
            } => Decision::Log(format!(
                "avod: frame ring [{scanout}/{generation}] {width}x{height} stride {stride} format {format:?} at {path}"
            )),
            Event::FramesOff { scanout } => {
                Decision::Log(format!("avod: frame ring [{scanout}] unplugged"))
            }
            Event::Microphone => Decision::Log(
                "avod: Android records; the microphone's user prompt is the control panel's slice (cuttlefish.rs:594)"
                    .to_string(),
            ),
            Event::Sound { stream, on } => Decision::Log(format!(
                "avod: the engine turned {stream:?} sound {}",
                if on { "on" } else { "off" }
            )),
            Event::AudioPlayback { epoch, path } => {
                Decision::Log(format!("avod: playback epoch {epoch} at {path}"))
            }
            Event::Paused => Decision::Log("avod: the vCPUs stand".to_string()),
            Event::Resumed { milliseconds } => {
                Decision::Log(format!("avod: the vCPUs stood for {milliseconds} ms"))
            }
            Event::GpuActive { device } => Decision::Log(format!("avod: the renderer runs on {device}")),
            Event::GpuContext => {
                Decision::Log("avod: the guest's first rendering context this boot".to_string())
            }
            Event::GpuFirstFrame { scanout } => {
                Decision::Log(format!("avod: the boot's first read-back frame [{scanout}]"))
            }
            Event::GpuStalled { milliseconds } => {
                Decision::Log(format!("avod: a guest fence waited {milliseconds} ms"))
            }
        },
        BodyMsg::Session(env) => match env.payload {
            Some(envelope::Payload::Notification(notification)) => {
                let app_name = notification.package.clone();
                Decision::Show(notification, app_name)
            }
            Some(envelope::Payload::NotificationRemoved(removed)) => Decision::Remove(removed.key),
            Some(envelope::Payload::ClipboardChanged(_)) | Some(envelope::Payload::SetClipboard(_)) => {
                Decision::Log(CLIPBOARD_GAP.to_string())
            }
            // The guest's answer frames and its goodbye — the reader eats a
            // goodbye for the session's own dead mark (session.rs:256), so
            // this arm is an exhaustive belt, not a matter of record.
            Some(envelope::Payload::Hello(_))
            | Some(envelope::Payload::Ping(_))
            | Some(envelope::Payload::Pong(_))
            | Some(envelope::Payload::Reply(_))
            | Some(envelope::Payload::Goodbye(_))
            | Some(envelope::Payload::RoleInvite(_))
            | Some(envelope::Payload::RoleGrant(_)) => Decision::Log(
                "avod: the session carried a control frame on the event side; moved past".to_string(),
            ),
            // Phase 3's next slices consume these: the control panel reads
            // the apps' lists, the shims the displays and the tasks.
            Some(envelope::Payload::AppInstalled(_))
            | Some(envelope::Payload::AppRemoved(_))
            | Some(envelope::Payload::DisplayReady(_))
            | Some(envelope::Payload::TaskClosed(_))
            | Some(envelope::Payload::OrientationRequest(_))
            | Some(envelope::Payload::AppList(_))
            | Some(envelope::Payload::PermissionList(_))
            | Some(envelope::Payload::DisplayContentChanged(_))
            | Some(envelope::Payload::TaskStarted(_)) => Decision::Log(
                "avod: a session event for the control panel's and shims' consumers arrives before them; logged and carried"
                    .to_string(),
            ),
            // Host verbs on the event side: the guest cannot ask these; the
            // roles socket is the later slice that sends them properly.
            Some(envelope::Payload::Launch(_))
            | Some(envelope::Payload::Resize(_))
            | Some(envelope::Payload::Close(_))
            | Some(envelope::Payload::Install(_))
            | Some(envelope::Payload::Uninstall(_))
            | Some(envelope::Payload::ListApps(_))
            | Some(envelope::Payload::ForceStop(_))
            | Some(envelope::Payload::DeleteAppData(_))
            | Some(envelope::Payload::GetPermissions(_))
            | Some(envelope::Payload::SetPermission(_))
            | Some(envelope::Payload::ShareFiles(_))
            | Some(envelope::Payload::SetDisplayVisibility(_))
            | Some(envelope::Payload::OpenNotification(_))
            | Some(envelope::Payload::DismissNotification(_))
            | Some(envelope::Payload::SetRefreshRate(_))
            | Some(envelope::Payload::FocusDisplay(_)) => Decision::Log(
                "avod: a guest-bound request arrived on the event side; the daemon's own verb senders are the DaemonService state machines' port (the roles slice landed its socket's hello, not its verbs)"
                    .to_string(),
            ),
            None => Decision::Log("avod: an envelope without a payload".to_string()),
        },
    }
}

/// Whose desk the notification calls land on:
enum Desk<'a> {
    Given(&'a dyn Notifies),
    Owned(Presenter),
    Off,
}

impl Desk<'_> {
    fn show(&self, notification: &Notification, app_name: &str) {
        match self {
            Desk::Given(given) => given.show(notification, app_name),
            Desk::Owned(presenter) => presenter_show(presenter, notification, app_name),
            Desk::Off => NotificationsOff.show(notification, app_name),
        }
    }
    fn remove(&self, key: &str) {
        match self {
            Desk::Given(given) => given.remove(key),
            Desk::Owned(presenter) => presenter_remove(presenter, key),
            Desk::Off => NotificationsOff.remove(key),
        }
    }
}

/// The trait's own bodies, spelled as free fns so `Desk::Owned` can call
/// them on the concrete presenter without the trait object's dyn hop.
fn presenter_show(presenter: &Presenter, notification: &Notification, app_name: &str) {
    if let Err(error) = presenter.show(notification, app_name) {
        eprintln!("avod: the desktop notification did not post: {error}");
    }
}

fn presenter_remove(presenter: &Presenter, key: &str) {
    if let Err(error) = presenter.remove(key) {
        eprintln!("avod: the desktop notification did not close: {error}");
    }
}

/// The production entry: the Mac's keepalive numbers sit under the loop
/// (`ControlSession::open` runs ControlSession.swift's `startKeepalive`),
/// the desk is the desktop's real presenter or its off state by the bus.
/// `notifies` is the tests' injection: `None` opens the real one.
/// Returns the exit code `main` hands to the process.
pub fn running(config: Config, notifies: Option<&dyn Notifies>) -> i32 {
    running_on(config, notifies, Keepalive::default())
}

/// The same body under a caller's clock. Nothing in the wiring changes:
/// only the keepalive's rhythm does, and only for the end-then-die path the
/// body's tests watch.
fn running_on(config: Config, notifies: Option<&dyn Notifies>, clock: Keepalive) -> i32 {
    // The engine first: without it there is nothing to be a daemon about,
    // and the code 1 (the spawn slice owns bringing an engine up later).
    let engine_sock = config.runtime.join("control.sock");
    let engine = match Engine::connect(&engine_sock) {
        Ok(engine) => engine,
        Err(error) => {
            eprintln!(
                "avod: no engine at {}: {error} — the engine process spawning itself is the later, hardware-gated slice, so this is a clean exit",
                engine_sock.display()
            );
            return 1;
        }
    };
    // The subscription: the events connection against the same path, the
    // backlog `ok`-delimited per engine.rs. The sink is the body's own
    // making; the forward thread below becomes its only consumer.
    let (engine_sink, engine_events) = mpsc::channel();
    if let Err(error) = engine.subscribe(engine_sink) {
        eprintln!("avod: the engine refused its subscription: {error} — clean exit");
        return 1;
    }
    // The guest's transport next: the hybrid-vsock handshake before the
    // control session's own (vsock.rs: the CONNECT dance, the bytes raw
    // past the OK). A guest not yet up is the code 1: the daemon has no
    // loop without a bridge to hear.
    let transport_path = config.runtime.join("vsock.sock");
    let transport = vsock::Vsock::at(&transport_path);
    let stream = match transport.connect_to(CONTROL_PORT) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!(
                "avod: no guest bridge at {}: {error} — the guest is not up, clean exit",
                transport_path.display()
            );
            return 1;
        }
    };
    let session = match ControlSession::open_on(stream, "avod 0", clock) {
        Ok(session) => session,
        Err(error) => {
            eprintln!("avod: the guest's control session never opened: {error} — clean exit");
            return 1;
        }
    };

    // The desktop's desk: injected, else the real presenter with its off
    // state named once. Every failure here is survivable — notifications
    // are the daemon's nicety, not its spine.
    let desk: Desk;
    match notifies {
        Some(given) => desk = Desk::Given(given),
        None => match Presenter::open() {
            Ok(presenter) => desk = Desk::Owned(presenter),
            Err(notifications::Error::Bus) => {
                eprintln!("avod: the session bus is not reachable — desktop notifications are off; the daemon carries on (the notifications module's documented null)");
                desk = Desk::Off;
            }
            Err(notifications::Error::Wire(what)) => {
                eprintln!("avod: the notification bus misbehaved ({what}) — desktop notifications are off; the daemon carries on");
                desk = Desk::Off;
            }
        },
    }

    // The ADB relay last and least: its absence is a log line, the loop
    // carries on (the Mac surfaces port-in-use the same way —
    // ADBForwarder's port arm).
    let mut relay: Option<AdbRelay> = None;
    {
        let port = config.adb_port.unwrap_or(ADB_PORT as u16);
        match adb::bind(port) {
            Err(error) => eprintln!("avod: the adb relay stays off: {error}"),
            Ok(listener) => match adb::relay(listener, vsock::Vsock::at(&transport_path)) {
                Err(error) => eprintln!("avod: the adb relay stays off: {error}"),
                Ok(started) => relay = Some(started),
            },
        }
    }

    // The loop, and the reason there are no forwarding threads for it.
    // mpsc's `Receiver` is not Sync, and the `ControlSession` owns two —
    // any shared handle across threads is a compile error; `std` has no
    // select. So the body's loop owns them where they sit and rounds
    // three receivers on one poll tick: the session's envelopes, the
    // session's keepalive end, the engine's events. The session stays on
    // this one thread (a plain `Send` handle), nothing is shared, and the
    // end's latency is bounded by `POLL` — for a daemon whose ends ask
    // only systemd to restage it, that read is the business.
    const POLL: Duration = Duration::from_millis(250);
    loop {
        // The engine's events, until the byte ends the subscription —
        // engine.rs's Err(Closed) folded to its body shape here.
        let heard = match engine_events.recv_timeout(POLL) {
            Ok(Ok(event)) => Some(BodyMsg::Engine(event)),
            Ok(Err(EngineError::Closed)) => Some(BodyMsg::EngineEnded),
            Ok(Err(EngineError::TimedOut)) => Some(BodyMsg::EngineFault(
                "an engine wait ran past its timeout; logged and carried".to_string(),
            )),
            Ok(Err(EngineError::Protocol(what))) => Some(BodyMsg::EngineFault(what)),
            Err(mpsc::RecvTimeoutError::Disconnected) => Some(BodyMsg::EngineEnded),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
        };
        if let Some(msg) = heard {
            if let Some(code) = step(msg, &desk, relay.as_mut()) {
                return code;
            }
        }

        // The session's envelopes, until the sink disconnects (its reader
        // thread exits when the wire or the session does).
        while let Ok(envelope) = session.events().recv_timeout(POLL) {
            if let Some(code) = step(BodyMsg::Session(envelope), &desk, relay.as_mut()) {
                return code;
            }
        }

        // The session's end: one `()` when the keepalive is done — goodbye,
        // wire death, a broken gate, all the same signal.
        if session.when_ended().recv_timeout(POLL).is_ok() {
            if let Some(code) = step(BodyMsg::SessionEnded, &desk, relay.as_mut()) {
                return code;
            }
        }
    }
}

/// One message to its decision and the decision's effects; returns the
/// exit code when the decision is an end.
fn step(msg: BodyMsg, desk: &Desk, relay: Option<&mut AdbRelay>) -> Option<i32> {
    match decide(msg) {
        Decision::Carry => {}
        Decision::Log(line) => eprintln!("{line}"),
        Decision::Ends(code) => {
            eprintln!("avod: the daemon's run ends with {code}");
            if let Some(relay) = relay {
                let _ = relay.stop();
                let _ = relay.join();
            }
            return Some(code);
        }
        Decision::Show(notification, app_name) => {
            desk.show(&notification, &app_name);
        }
        Decision::Remove(key) => {
            desk.remove(&key);
        }
    }
    None
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{read_envelope, write_envelope};
    use crate::proto::{
        goodbye, ClipboardChanged, Goodbye, Hello, NotificationRemoved, SetClipboard, TaskStarted,
        PROTOCOL_MIN_VERSION, PROTOCOL_VERSION,
    };
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::Arc;
    use std::sync::Mutex;
    use std::time::Duration;
    use std::time::Instant;

    /// The tests' keepalive: a blink, so a session's end is felt in
    /// milliseconds instead of the Mac's five seconds.
    fn clock() -> Keepalive {
        Keepalive::clocks(
            Duration::from_millis(25),
            Duration::from_millis(25),
            3,
        )
    }

    /// One envelope off the pattern: id 0, the protocol version, payload.
    fn envelope_of(payload: envelope::Payload) -> Envelope {
        Envelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: 0,
            payload: Some(payload),
        }
    }

    /// A notification with its two names filled.
    fn notification(package: &str, key: &str) -> Notification {
        Notification {
            package: package.into(),
            key: key.into(),
            ..Default::default()
        }
    }

    /// Decision::Log's text out for assertions, named as used.
    trait LogText {
        fn and_log(self) -> String;
    }
    impl LogText for Decision {
        fn and_log(self) -> String {
            match self {
                Decision::Log(line) => line,
                other => panic!("a log was expected: {other:?}"),
            }
        }
    }

    // ---------------------------------------------------------------

    // ---------------------------------------------------------------
    // The guest-side fake: the body connects `config.runtime/vsock.sock`
    // itself (running_on'w transport line), so the fake binds THE REAL
    // PATH — a unique temp-name socket would make the run exit 1 before
    // any event flowed. One serve call = one accept, the CONNECT/OK dance
    // answered, the script run, then an optional park holding the wire.
    // session.rs's pattern, retyped for a body that owns its connects.

    mod guest {
        use super::*;

        /// One step of the guest's script, in wire order.
        pub(super) enum Step {
            Write(Envelope),
            /// Consumes the session's opening Hello, read and dropped.
            Read,
        }

        /// Reads one newline-terminated line, or gives up at the wire's end.
        fn read_line(stream: &mut UnixStream) -> Option<String> {
            let mut bytes = Vec::new();
            let mut one = [0u8; 1];
            while bytes.len() < 256 {
                if stream.read_exact(&mut one).is_err() {
                    break;
                }
                if one[0] == b'\n' {
                    break;
                }
                bytes.push(one[0]);
            }
            (!bytes.is_empty()).then(|| String::from_utf8_lossy(&bytes).into_owned())
        }

        /// Serves the body's control session at `<runtime>/vsock.sock`
        /// (vsock.rs's convention): one accept, the CONNECT line asserted
        /// and OK'd, the script run, and the park.
        pub(super) fn serve(runtime: &Path, script: Vec<Step>, parked: Option<mpsc::Receiver<()>>) {
            let path = runtime.join("vsock.sock");
            let listener = UnixListener::bind(&path).unwrap();
            std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                let line = read_line(&mut stream).unwrap();
                assert!(
                    line.starts_with("CONNECT "),
                    "the transport's handshake is the CONNECT line: {line:?}"
                );
                stream.write_all(b"OK 1\n").unwrap();
                for step in script {
                    match step {
                        Step::Write(envelope) => write_envelope(&mut stream, &envelope).unwrap(),
                        Step::Read => {
                            read_envelope(&mut stream).unwrap().unwrap();
                        }
                    }
                }
                // A parked script holds the wire open past its writes: the
                // session stays up until the test drops the matching
                // sender, and only then is the wire gone.
                if let Some(parked) = parked {
                    let _ = parked.recv();
                }
            });
        }

        /// The green gate: the body's Hello consumed, the guest's Hello
        /// answered — the script opener every full-path test starts with.
        pub(super) fn hello_green() -> Vec<Step> {
            vec![
                Step::Read,
                Step::Write(envelope_of(envelope::Payload::Hello(Hello {
                    protocol_version: PROTOCOL_VERSION,
                    min_protocol_version: PROTOCOL_MIN_VERSION,
                    software_version: "bridge image".into(),
                    ..Default::default()
                }))),
            ]
        }
    }
    // The engine-side fake, engine.rs's scripted shape rewritten by hand:
    // the body opens the command connection first (silent, held) and the
    // subscription second, so the fake takes BOTH accepts — the first one
    // spoken to by nobody, the second one saying `ok` and then parked or
    // ended. Missing the first accept would hang the body's connect (the
    // fake's read of a line that never comes), so this shape is load-bearing.

    mod engine_fake {
        use super::*;
        use std::os::unix::net::UnixListener;

        /// Reads one newline-terminated line, or gives up at the wire's end.
        fn read_line(stream: &mut UnixStream) -> Option<String> {
            let mut bytes = Vec::new();
            let mut one = [0u8; 1];
            while bytes.len() < 256 {
                if stream.read_exact(&mut one).is_err() {
                    break;
                }
                if one[0] == b'\n' {
                    break;
                }
                bytes.push(one[0]);
            }
            (!bytes.is_empty()).then(|| String::from_utf8_lossy(&bytes).into_owned())
        }

        /// The subscription's shape: accept the command connection first
        /// and hold it silent (the body never commands in this slice), then
        /// the subscription — `ok` out, then parked. The returned `Sender`
        /// IS the hold: the test drops it, the park's recv errs, the wire
        /// ends, and the body hears EngineEnded.
        pub(super) fn start(runtime: &Path) -> mpsc::Sender<()> {
            let path = runtime.join("control.sock");
            let listener = UnixListener::bind(&path).unwrap();
            let (hold, park_rx) = mpsc::channel::<()>();
            std::thread::spawn(move || {
                let _command = listener.accept().unwrap();
                let mut sub = listener.accept().unwrap().0;
                assert_eq!(read_line(&mut sub).as_deref(), Some("subscribe"));
                sub.write_all(b"ok\n").unwrap();
                let _ = park_rx.recv();
                // The park released: the wire ends.
                drop(sub);
            });
            hold
        }

        /// The EngineEnded path in the raw: subscribed, then the wire ends
        /// at once, no hold to wait on.
        pub(super) fn start_dying(runtime: &Path) {
            let hold = start(runtime);
            // The channel is buffered: the sign arrives whenever the fake's
            // thread reaches its park, which is after the body's subscribe
            // has had its `ok`.
            hold.send(()).unwrap();
            drop(hold);
        }
    }

    /// The recorder desk: what the loop told, in arrival order.
    struct Recorder(Mutex<Vec<String>>);
    impl Notifies for Recorder {
        fn show(&self, shown: &Notification, app_name: &str) {
            self.0
                .lock()
                .unwrap()
                .push(format!("show {} {app_name}", shown.package));
        }
        fn remove(&self, removed: &str) {
            self.0.lock().unwrap().push(format!("remove {removed}"));
        }
    }

    impl Recorder {
        fn until(&self, wanted: usize) -> Vec<String> {
            for _ in 0..400 {
                if self.0.lock().unwrap().len() >= wanted {
                    return self.0.lock().unwrap().clone();
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            panic!("the desk saw {:?}, wanted {wanted}", self.0.lock().unwrap());
        }
    }

    fn config(runtime: &Path) -> Config {
        Config {
            instance: runtime.to_path_buf(),
            runtime: runtime.to_path_buf(),
            adb_port: None,
        }
    }

    fn fresh(fixture: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("avod-body-{fixture}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_paths_fall_to_their_xdg_roots() {
        // One serial test holds the whole env surface: every case runs in
        // this fn, so no unsafe-set value races another test's read.
        unsafe {
            std::env::set_var("HOME", "/home/t");
            std::env::remove_var("XDG_DATA_HOME");
            std::env::remove_var("XDG_RUNTIME_DIR");
            let error = paths().unwrap_err();
            assert!(error.contains("XDG_RUNTIME_DIR"), "{error}");
            std::env::set_var("XDG_RUNTIME_DIR", "/run/t");
            let config = paths().unwrap();
            assert_eq!(config.runtime, Path::new("/run/t/avod"));
            assert_eq!(config.instance, Path::new("/home/t/.local/share/avo/default"));
            std::env::set_var("XDG_DATA_HOME", "/data/t");
            let config = paths().unwrap();
            assert_eq!(config.instance, Path::new("/data/t/avo/default"));
        }
    }

    #[test]
    fn the_cli_carries_the_flags_over_the_defaults() {
        unsafe {
            std::env::set_var("HOME", "/home/t");
            std::env::set_var("XDG_DATA_HOME", "/data/t");
            std::env::set_var("XDG_RUNTIME_DIR", "/run/t");
        }
        let config = cli(vec![
            "avod".into(),
            "--instance".into(),
            "/i".into(),
            "--runtime".into(),
            "/r".into(),
            "--adb-port".into(),
            "5556".into(),
        ])
        .unwrap();
        assert_eq!(config.instance, Path::new("/i"));
        assert_eq!(config.runtime, Path::new("/r"));
        assert_eq!(config.adb_port, Some(5556));
        assert!(cli(vec!["avod".into(), "--runtime".into()]).is_err());
        assert!(cli(vec!["avod".into(), "--sounds".into()]).is_err());
    }

    #[test]
    fn decide_routes_the_real_events_by_name() {
        // A notification rides to the desk with the package as app name.
        match decide(BodyMsg::Session(envelope_of(envelope::Payload::Notification(
            notification("com.avo.notes", "|app|9"),
        )))) {
            Decision::Show(shown, app_name) => {
                assert_eq!(shown.package, "com.avo.notes");
                assert_eq!(app_name, "com.avo.notes");
            }
            other => panic!("a notification is a show: {other:?}"),
        }
        // A removal, key intact.
        match decide(BodyMsg::Session(envelope_of(envelope::Payload::NotificationRemoved(
            NotificationRemoved { key: "|app|9".into() },
        )))) {
            Decision::Remove(removed) => assert_eq!(removed, "|app|9"),
            other => panic!("a removal is a remove: {other:?}"),
        }
        // Both clipboard envelopes carry their named gap: the jar on the
        // guest (the ADB client's slice), the desktop API on the host.
        for payload in [
            envelope::Payload::ClipboardChanged(ClipboardChanged { text: "hello".into() }),
            envelope::Payload::SetClipboard(SetClipboard { text: "hello".into() }),
        ] {
            let logged = decide(BodyMsg::Session(envelope_of(payload))).and_log();
            assert!(logged.contains("clipboard"), "{logged}");
            assert!(logged.contains("ADB client"), "{logged}");
        }
        // The shim-consumer class logs its one line.
        let later = decide(BodyMsg::Session(envelope_of(envelope::Payload::TaskStarted(
            TaskStarted {
                package: "com.avo.notes".into(),
                task_id: 3,
            },
        ))))
        .and_log();
        assert!(later.contains("shims' consumers"), "{later}");
        // And a payload-less envelope is a log, not a crash.
        let empty = decide(BodyMsg::Session(Envelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: 0,
            payload: None,
        }));
        assert!(empty.and_log().contains("without a payload"));
    }

    #[test]
    fn decide_keeps_the_engine_events_by_class() {
        // Per-frame traffic stays silent until the shims read it.
        assert!(matches!(
            decide(BodyMsg::Engine(Event::Frame { scanout: 0, sequence: 12 })),
            Decision::Carry
        ));
        // A ring's layout speaks once, with its shape.
        let ring = decide(BodyMsg::Engine(Event::Frames {
            scanout: 0,
            generation: 1,
            width: 720,
            height: 1280,
            stride: 1440,
            format: crate::frames::Format::Bgra,
            path: "/run/avod/frames/0".into(),
        }))
        .and_log();
        assert!(ring.contains("720x1280"), "{ring}");
        // Sound and GPU speak by class too; assert two, trust the match.
        let sound = decide(BodyMsg::Engine(Event::Sound {
            stream: crate::engine::SoundStream::Playback,
            on: true,
        }))
        .and_log();
        assert!(sound.contains("sound on"), "{sound}");
        let gpu = decide(BodyMsg::Engine(Event::GpuActive {
            device: "Apple M4 Pro".into(),
        }))
        .and_log();
        assert!(gpu.contains("Apple M4 Pro"), "{gpu}");
        // And the ends are ends.
        assert!(matches!(decide(BodyMsg::EngineEnded), Decision::Ends(2)));
        assert!(matches!(decide(BodyMsg::SessionEnded), Decision::Ends(2)));
    }

    /// The full path's happy run: engine subscribed (parked), guest hello,
    /// one notification shown and one removed, then a goodbye. The loop's
    /// desk sees both letters in arrival order, and the run's exit is 2.
    #[test]
    fn a_live_run_shows_and_removes_then_dies_with_two() {
        let dir = fresh("happy");
        let hold = engine_fake::start(&dir);
        guest::serve(
            &dir,
            {
                let mut script = guest::hello_green();
                script.extend([
                    guest::Step::Write(envelope_of(envelope::Payload::Notification(notification(
                        "com.avo.notes",
                        "|app|1",
                    )))),
                    guest::Step::Write(envelope_of(envelope::Payload::NotificationRemoved(
                        NotificationRemoved { key: "|app|1".into() },
                    ))),
                    guest::Step::Write(envelope_of(envelope::Payload::Goodbye(Goodbye {
                        reason: goodbye::Reason::Shutdown as i32,
                        message: "the guest is off".into(),
                    }))),
                ]);
                script
            },
            None,
        );

        let recorder: Arc<Recorder> = Arc::new(Recorder(Mutex::new(Vec::new())));
        let run = mpsc::channel();
        {
            let sender = run.0.clone();
            let dir = dir.clone();
            let recorder = Arc::clone(&recorder);
            std::thread::spawn(move || {
                sender
                    .send(running_on(config(&dir), Some(recorder.as_ref()), clock()))
                    .unwrap();
            });
        }
        let seen = recorder.until(2);
        assert_eq!(seen[0], "show com.avo.notes com.avo.notes");
        assert_eq!(seen[1], "remove |app|1");
        drop(hold);
        let code = run
            .1
            .recv_timeout(Duration::from_secs(5))
            .expect("the loop hung instead of ending on the goodbye");
        assert_eq!(code, 2, "a goodbye (or any session end) is exit 2");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The engine's wire ends while the guest's holds green: the loop must
    /// exit with 2 on the engine's end instead of hanging on its silence.
    /// The park keeps the session alive the whole test, so the engine's end
    /// is the run's ONLY end.
    #[test]
    fn an_engine_wire_end_ends_the_run_with_two() {
        let dir = fresh("engine-end");
        engine_fake::start_dying(&dir);
        let (park, parked) = mpsc::channel::<()>();
        guest::serve(&dir, guest::hello_green(), Some(parked));

        let recorder: Arc<Recorder> = Arc::new(Recorder(Mutex::new(Vec::new())));
        let run = mpsc::channel();
        {
            let sender = run.0.clone();
            let dir = dir.clone();
            let recorder = Arc::clone(&recorder);
            std::thread::spawn(move || {
                sender
                    .send(running_on(config(&dir), Some(recorder.as_ref()), clock()))
                    .unwrap();
            });
        }
        let started = Instant::now();
        let code = run
            .1
            .recv_timeout(Duration::from_secs(5))
            .expect("the body hung on the engine's end instead of exiting");
        assert_eq!(code, 2, "an engine end is exit 2");
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "the engine's end went through the keepalive's blink, not the Mac's five seconds"
        );
        drop(park);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An engine nobody answers: the body's first open fails, and the exit
    /// is a clean 1 in a blink — no crash loop without cause.
    #[test]
    fn an_absent_engine_exits_one_fast() {
        let dir = fresh("absent");
        let started = Instant::now();
        let code = running_on(config(&dir), None, clock());
        assert_eq!(code, 1, "no engine is a clean 1");
        assert!(started.elapsed() < Duration::from_secs(2));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A relay port already taken: the relay stays off with its log line
    /// and the loop carries to the guest's own end. The Mac surfaces
    /// port-in-use the same way (ADBForwarder's port arm).
    #[test]
    fn a_taken_port_leaves_the_loop_whole() {
        let dir = fresh("relay-taken");
        let held = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).unwrap();
        let taken = held.local_addr().unwrap().port();
        let hold = engine_fake::start(&dir);
        guest::serve(
            &dir,
            {
                let mut script = guest::hello_green();
                script.push(guest::Step::Write(envelope_of(envelope::Payload::Goodbye(
                    Goodbye {
                        reason: goodbye::Reason::Shutdown as i32,
                        message: String::new(),
                    },
                ))));
                script
            },
            None,
        );

        let recorder: Arc<Recorder> = Arc::new(Recorder(Mutex::new(Vec::new())));
        let run = mpsc::channel();
        {
            let sender = run.0.clone();
            let dir = dir.clone();
            let recorder = Arc::clone(&recorder);
            std::thread::spawn(move || {
                let mut mine = config(&dir);
                mine.adb_port = Some(taken);
                sender.send(running_on(mine, Some(recorder.as_ref()), clock())).unwrap();
            });
        }
        let code = run
            .1
            .recv_timeout(Duration::from_secs(5))
            .expect("a port conflict must not kill the run");
        assert_eq!(code, 2, "the relay's absence is a log, the end is the guest's");
        drop(hold);
        drop(held);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
