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
use std::sync::{Arc, Mutex};
use std::sync::mpsc;
use std::time::Duration;

use crate::adb::{self, AdbRelay};
use crate::engine::{Engine, EngineError, Event};
use crate::notifications::{self, Presenter};
use crate::proto::{
    envelope, reply, Close, DismissNotification, Envelope, FocusDisplay, Launch, ListApps,
    Notification, OpenNotification, Reply, Resize, SetClipboard, SetDisplayVisibility,
    SetRefreshRate,
};
use crate::roles;
use crate::session::{ControlSession, Keepalive, SessionError};
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
            | Some(envelope::Payload::RoleGrant(_))
            | Some(envelope::Payload::Verb(_)) => Decision::Log(
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

    // The roles socket: the daemon's own door, where the Mac's XPC heard
    // its clients (Control Panel, shims, engine — XPCInterface.swift:4-5).
    // The engine's status rides the grants, read only when a RoleGrant is
    // built; the body tracks it by its own engine events. Its absence is
    // a log line like the relay's, and the loop carries on — the door is
    // the UI's convenience, the loop the daemon's spine. With the door
    // stands the verb bus: a post-grant `Verb` posts into the channel the
    // loop drains; the asker's own oneshot is the waiting.
    let statuses: Arc<Mutex<String>> = Arc::new(Mutex::new("running".to_string()));
    let (verb_post, verb_inbox) = mpsc::channel::<roles::Ask>();
    let mut roles_server: Option<roles::Server> = None;
    {
        let statuses_for_roles = Arc::clone(&statuses);
        let bus: roles::VerbBus = Arc::new(move |ask: roles::Ask| {
            let _ = verb_post.send(ask);
        });
        let door = config.runtime.join(roles::SOCKET_NAME);
        match roles::serve_with_verbs(door, move || statuses_for_roles.lock().expect("the status lock").clone(), bus) {
            Err(error) => eprintln!("avod: the roles socket stays off: {error}"),
            Ok(server) => roles_server = Some(server),
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
    // The daemon's own display-id counter: the next launch's display id
    // (the Mac's nextDisplayID at DaemonCore.swift:1313; display 0 is the
    // guest's "let it decide", never assigned).
    let mut next_display_id: u32 = 1;
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
            if let Some(code) = step(msg, &desk, relay.as_mut(), &mut roles_server, &statuses) {
                return code;
            }
        }

        // The session's envelopes, until the sink disconnects (its reader
        // thread exits when the wire or the session does).
        while let Ok(envelope) = session.events().recv_timeout(POLL) {
            if let Some(code) = step(BodyMsg::Session(envelope), &desk, relay.as_mut(), &mut roles_server, &statuses) {
                return code;
            }
        }

        // The session's end: one `()` when the keepalive is done — goodbye,
        // wire death, a broken gate, all the same signal.
        if session.when_ended().recv_timeout(POLL).is_ok() {
            if let Some(code) = step(BodyMsg::SessionEnded, &desk, relay.as_mut(), &mut roles_server, &statuses) {
                return code;
            }
        }

        // The door's verb asks: the bus posts, the loop settles, the door
        // answers its asker in the asker's id. Non-blocking on purpose —
        // a quiet door costs the round nothing; a lane ask pends on the
        // session's request slot for its own deadline, the loop single
        // as ever.
        for ask in verb_inbox.try_iter() {
            let verdict =
                settle_the_ask(&ask, &engine, &session, &mut next_display_id);
            let _ = ask.settle.send(verdict);
        }
    }
}

/// The session lanes' own wait: a launch on the Mac pends up to 6s in the
/// guest's scanout hunt (HostAgent.swift:651) — the door's wait rides the
/// same order of time. The keepalive lives on the session's own reader
/// thread, so a lane's block starves no liveness; the loop just does not
/// settle other asks while one pends, the Mac's serialized requests too.
const LANE_WAIT: Duration = Duration::from_secs(8);

/// The door's verb ask, settled by the loop over the engine's own
/// one-line grammar (`control.rs`'s `run` match): the first word the
/// engine asked for, the argument its remainder. The reply's wording is
/// the engine's own on a refusal; the verbs the engine does not say yet
/// name the state machine they wait for. The asker's role rides along
/// for the first per-role gates (the Mac checks per verb; nothing in v1
/// narrows by role — every granted caller may speak the engine's line
/// grammar).
///
/// The guest-bound set rides the session's request lanes instead — the
/// Mac's `controlSession().request(...)` at DaemonCore.swift:1308's open
/// display: the daemon assigns the display id, the guest's agent runs the
/// state machine, and the guest's own typed answer (DisplayReady on a
/// launch or resize, Reply elsewhere) passes through unopened. `launch`
/// assigns ids in the daemon's own counter; the rest address by the id
/// they were given.
fn settle_the_ask(
    ask: &roles::Ask,
    engine: &Engine,
    session: &ControlSession,
    next_display_id: &mut u32,
) -> Result<envelope::Payload, (reply::Status, String)> {
    if ask.name.contains('\n') || ask.argument.contains('\n') {
        return Err((
            reply::Status::InvalidArgument,
            "an ask is one line; the door does not say two".to_string(),
        ));
    }
    // The session lanes: typed, the guest's own answers.
    let words: Vec<&str> = ask.argument.split_whitespace().collect();
    let count = |need: usize| -> Result<(), (reply::Status, String)> {
        (words.len() >= need).then_some(()).ok_or((
            reply::Status::InvalidArgument,
            format!("{} wants {} words, got {}", ask.name, need, words.len()),
        ))
    };
    let number = |word: &str, what: &str| -> Result<u32, (reply::Status, String)> {
        word.parse().map_err(|_| {
            (
                reply::Status::InvalidArgument,
                format!("{what} is not a number: {word}"),
            )
        })
    };
    let lane = |payload: envelope::Payload| -> Result<envelope::Payload, (reply::Status, String)> {
        match session.request(payload, LANE_WAIT) {
            Ok(answer) => Ok(answer.payload.unwrap_or_else(|| {
                envelope::Payload::Reply(Reply {
                    status: reply::Status::Ok as i32,
                    message: String::new(),
                })
            })),
            Err(SessionError::TimedOut) => Err((
                reply::Status::Failed,
                "the guest's answer ran past the door's wait; the ask stands unspoken"
                    .to_string(),
            )),
            Err(error) => Err((
                reply::Status::Failed,
                format!("the session would not take the ask: {error}"),
            )),
        }
    };
    match ask.name.as_str() {
        "launch" => {
            count(4)?;
            let package = words[0].to_string();
            let width = number(words[1], "width")?;
            let height = number(words[2], "height")?;
            let dpi = number(words[3], "dpi")?;
            let refresh_rate = match words.get(4) {
                Some(word) => number(word, "refresh rate")?,
                None => 0,
            };
            // The display id is the daemon's own counter (the Mac's
            // nextDisplayID at DaemonCore.swift:1313); virtio-gpu modes
            // are 8-pixel aligned on the Mac's side (HostAgent.swift:661).
            let display_id = *next_display_id;
            *next_display_id += 1;
            return lane(envelope::Payload::Launch(Launch {
                package,
                display_id,
                width: width.max(64) / 8 * 8,
                height: height.max(64),
                dpi,
                component: String::new(),
                notification_key: String::new(),
                data_uri: String::new(),
                mime_type: String::new(),
                refresh_rate,
            }));
        }
        "resize" => {
            count(3)?;
            return lane(envelope::Payload::Resize(Resize {
                display_id: number(words[0], "display id")?,
                width: words[1].parse().map_err(|_| {
                    (reply::Status::InvalidArgument, "width is not a number".to_string())
                })?,
                height: words[2].parse().map_err(|_| {
                    (reply::Status::InvalidArgument, "height is not a number".to_string())
                })?,
                dpi: match words.get(3) {
                    Some(word) => number(word, "dpi")?,
                    None => 0,
                },
            }));
        }
        "close" => {
            count(1)?;
            return lane(envelope::Payload::Close(Close {
                display_id: number(words[0], "display id")?,
            }));
        }
        "open-notification" => {
            count(1)?;
            return lane(envelope::Payload::OpenNotification(OpenNotification {
                key: words[0].to_string(),
                display_id: match words.get(1) {
                    Some(word) => number(word, "display id")?,
                    None => 0,
                },
            }));
        }
        "dismiss-notification" => {
            count(1)?;
            return lane(envelope::Payload::DismissNotification(DismissNotification {
                key: words[0].to_string(),
            }));
        }
        "set-refresh-rate" => {
            count(2)?;
            return lane(envelope::Payload::SetRefreshRate(SetRefreshRate {
                display_id: number(words[0], "display id")?,
                fps: number(words[1], "fps")?,
            }));
        }
        "set-display-visibility" => {
            count(2)?;
            let visible = match words[1] {
                "on" => true,
                "off" => false,
                _ => {
                    return Err((
                        reply::Status::InvalidArgument,
                        "visibility is on or off".to_string(),
                    ))
                }
            };
            return lane(envelope::Payload::SetDisplayVisibility(SetDisplayVisibility {
                display_id: number(words[0], "display id")?,
                visible,
            }));
        }
        "focus-display" => {
            count(1)?;
            return lane(envelope::Payload::FocusDisplay(FocusDisplay {
                display_id: number(words[0], "display id")?,
            }));
        }
        // The clipboard's text is the argument whole — separators stay.
        "set-clipboard" if !ask.argument.trim().is_empty() => {
            return lane(envelope::Payload::SetClipboard(SetClipboard {
                text: ask.argument.trim().to_string(),
            }));
        }
        "list-apps" => {
            // `list-apps [icons on|off [system on|off]]` — the Mac's list
            // reads system apps by default; icons stay off until asked
            // (the proto.rs doc: the host omits them when it has them).
            let flags = |word: Option<&&str>, fallback: bool| -> Result<bool, (reply::Status, String)> {
                match word {
                    Some(w) if *w == "on" => Ok(true),
                    Some(w) if *w == "off" => Ok(false),
                    Some(w) => Err((
                        reply::Status::InvalidArgument,
                        format!("{w} is on or off"),
                    )),
                    None => Ok(fallback),
                }
            };
            let include_icons = flags(words.first(), false)?;
            let include_system = flags(words.get(1), true)?;
            return lane(envelope::Payload::ListApps(ListApps {
                include_icons,
                include_system,
            }));
        }
        _ => {}
    }
    match ask.name.as_str() {
        "pause" | "resume" | "touch" | "key" | "tap" | "swipe" | "display" | "location"
        | "snapshot" | "gamepad" => {
            let line = if ask.argument.is_empty() {
                ask.name.clone()
            } else {
                format!("{} {}", ask.name, ask.argument)
            };
            match engine.command(&line) {
                Ok(()) => Ok(envelope::Payload::Reply(Reply {
                    status: reply::Status::Ok as i32,
                    message: format!("the engine took {line}"),
                })),
                Err(EngineError::Protocol(what)) => Err((reply::Status::Failed, what)),
                Err(EngineError::TimedOut) => Err((
                    reply::Status::Failed,
                    "the engine's wait ran past its timeout; the ask stands unspoken".to_string(),
                )),
                Err(EngineError::Closed) => Err((
                    reply::Status::Failed,
                    "the engine's socket is gone".to_string(),
                )),
            }
        }
        other => Err((
            reply::Status::Unsupported,
            format!("{other} is not served by the door yet: the daemon's own state machines are the Mac's DaemonService.swift's, a later slice of the port"),
        )),
    }
}

/// One message to its decision and the decision's effects; returns the
/// exit code when the decision is an end. The grant's `vm_state` follows
/// the body's own map of the engine and the ends (the Mac's VMStatus,
/// `DaemonHello`'s `status`, read from the closures only at grant time —
/// roles.rs's contract), so the track lands here, at the body's pace.
fn step(
    msg: BodyMsg,
    desk: &Desk,
    relay: Option<&mut AdbRelay>,
    roles: &mut Option<roles::Server>,
    statuses: &Mutex<String>,
) -> Option<i32> {
    match &msg {
        BodyMsg::Engine(Event::Paused) => *statuses.lock().expect("the status lock") = "paused".into(),
        BodyMsg::Engine(Event::Resumed { .. }) => *statuses.lock().expect("the status lock") = "running".into(),
        BodyMsg::EngineEnded | BodyMsg::SessionEnded => {
            *statuses.lock().expect("the status lock") = "stopped".into();
        }
        _ => {}
    }
    match decide(msg) {
        Decision::Carry => {}
        Decision::Log(line) => eprintln!("{line}"),
        Decision::Ends(code) => {
            eprintln!("avod: the daemon's run ends with {code}");
            if let Some(relay) = relay {
                let _ = relay.stop();
                let _ = relay.join();
            }
            if let Some(server) = roles.take() {
                server.stop();
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
        goodbye, AppList, ClipboardChanged, DisplayReady, Goodbye, Hello, NotificationRemoved, Pong,
        RoleGrant, RoleInvite, SetClipboard, TaskStarted, Verb, PROTOCOL_MIN_VERSION,
        PROTOCOL_VERSION, reply,
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
                // A parked script holds the wire open past its writes —
                // and answers the keepalive's Pings while it holds. A
                // parked guest that stays mute misses three pings and
                // ends the run at the blink clock; the parked leg means
                // "green until the test says otherwise," so the pong is
                // part of the pattern. The test's drop is still the
                // close: the loop outlives the wire either way.
                if let Some(parked) = parked {
                    loop {
                        match read_envelope(&mut stream) {
                            Ok(Some(envelope)) => {
                                // The pong echoes the ping's request id —
                                // session.rs's keepalive pairs on it; a
                                // ring with id 0 lands on the event side
                                // and the keepalive never hears it.
                                let reply = match envelope.payload {
                                    Some(envelope::Payload::Ping(ping)) => Envelope {
                                        request_id: envelope.request_id,
                                        protocol_version: envelope.protocol_version,
                                        payload: Some(envelope::Payload::Pong(Pong {
                                            nonce: ping.nonce,
                                        })),
                                    },
                                    // A lane ask from the daemon (any
                                    // request_id the door planted):
                                    // the agent's stand-in answers in
                                    // the ask's own id — a launch or a
                                    // resize says `DisplayReady` with
                                    // the ask's display id, anything
                                    // else the generic `Reply{Ok}`.
                                    // The parked leg stays green for
                                    // the keepalive either way.
                                    other => match other {
                                        Some(envelope::Payload::Launch(launch)) => Envelope {
                                            request_id: envelope.request_id,
                                            protocol_version: envelope.protocol_version,
                                            payload: Some(envelope::Payload::DisplayReady(
                                                DisplayReady {
                                                    display_id: launch.display_id,
                                                    package: launch.package,
                                                },
                                            )),
                                        },
                                        Some(envelope::Payload::ListApps(_)) => Envelope {
                                            request_id: envelope.request_id,
                                            protocol_version: envelope.protocol_version,
                                            payload: Some(envelope::Payload::AppList(AppList {
                                                apps: Vec::new(),
                                            })),
                                        },
                                        Some(envelope::Payload::Resize(resize)) => Envelope {
                                            request_id: envelope.request_id,
                                            protocol_version: envelope.protocol_version,
                                            payload: Some(envelope::Payload::DisplayReady(
                                                DisplayReady {
                                                    display_id: resize.display_id,
                                                    package: String::from("resized"),
                                                },
                                            )),
                                        },
                                        _ => Envelope {
                                            request_id: envelope.request_id,
                                            protocol_version: envelope.protocol_version,
                                            payload: Some(envelope::Payload::Reply(Reply {
                                                status: reply::Status::Ok as i32,
                                                message: String::from("the guest took the ask"),
                                            })),
                                        },
                                    },
                                };
                                if write_envelope(&mut stream, &reply).is_err() {
                                    break;
                                }
                            }
                            // The wire is gone: the park is over.
                            _ => break,
                        }
                    }
                    // The semaphore's last nod, for the record: the test's
                    // drop ends the parked leg as it always did.
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
                // The command leg: the body holds it silently to open, and
                // from the verb slice on, SPEAKS into it — one line, one
                // reply (`ok`, possibly `error ...`), exactly the
                // engine's `run()` shape. The leg answers whatever comes
                // and dies when the wire does.
                let (command, _) = listener.accept().unwrap();
                std::thread::spawn(move || {
                    let mut command = command;
                    while let Some(_line) = read_line(&mut command) {
                        if command.write_all(b"ok\n").is_err() {
                            break;
                        }
                    }
                });
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

        /// The paused-line variant under the test's own gate: subscribed
        /// and held, then one `paused` line when the gate1 arrives, then
        /// held until the gate2 ends the wire. The grants' vm_state reads
        /// both stages deterministically. Both returns are senders: the
        /// test speaks the pause, and speaks the end by dropping it.
        pub(super) fn start_gated(runtime: &Path) -> (mpsc::Sender<()>, mpsc::Sender<()>) {
            let path = runtime.join("control.sock");
            let listener = UnixListener::bind(&path).unwrap();
            let (gate_write, write_gate) = mpsc::channel::<()>();
            let (gate_end, end_gate) = mpsc::channel::<()>();
            std::thread::spawn(move || {
                let _command = listener.accept().unwrap();
                let mut sub = listener.accept().unwrap().0;
                assert_eq!(read_line(&mut sub).as_deref(), Some("subscribe"));
                sub.write_all(b"ok\n").unwrap();
                // Hold until the test asks for the pause to be spoken.
                let _ = write_gate.recv();
                sub.write_all(b"paused\n").unwrap();
                // Hold until the test asks for the wire to end.
                let _ = end_gate.recv();
                drop(sub);
            });
            (gate_write, gate_end)
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

    /// One door conversation: connect, invite, take the grant, hang up.
    /// Two grants need two conversations — the door's grammar allows one
    /// invite per connection, the granted repeat falls to the catch-all.
    fn invite(runtime: &Path) -> RoleGrant {
        let mut stream = UnixStream::connect(runtime.join("daemon.sock")).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        write_envelope(
            &mut stream,
            &envelope_of(envelope::Payload::RoleInvite(RoleInvite {
                role: crate::proto::roles::Role::ControlPanel as i32,
                package: String::new(),
                client_version: "the body's battery".into(),
            })),
        )
        .unwrap();
        let envelope = read_envelope(&mut stream).unwrap().unwrap();
        match envelope.payload {
            Some(envelope::Payload::RoleGrant(grant)) => grant,
            _ => panic!("the door answered with something other than a grant"),
        }
    }

    /// The roles door live under its real mount gate: a 0700 dir lets
    /// `daemon.sock` bind, a real client's invite earns a RoleGrant whose
    /// `vm_state` is the body's own engine reading — "running" before the
    /// engine's line, "paused" after it — and the run's end takes the
    /// door's file down with it.
    #[test]
    fn the_roles_door_up_and_the_vm_state_rides_the_grant() {
        use std::os::unix::fs::PermissionsExt;
        let dir = fresh("roles-door");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

        let (gate_write, gate_end) = engine_fake::start_gated(&dir);
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

        // The door comes up inside the body's own flight; probe until it
        // is bound (a blink apart, bounded), then speak for real.
        let mut grant = None;
        for _ in 0..40 {
            match UnixStream::connect(dir.join(roles::SOCKET_NAME)) {
                Ok(stream) => {
                    drop(stream);
                    grant = Some(invite(&dir));
                    break;
                }
                Err(_) => std::thread::sleep(Duration::from_millis(50)),
            }
        }
        let grant = grant.expect("the door never came up under the 0700 dir");
        assert_eq!(grant.vm_state, "running");
        assert_eq!(grant.protocol_version, PROTOCOL_VERSION);
        assert_eq!(grant.min_supported, PROTOCOL_MIN_VERSION);
        assert!(
            !grant.daemon_version.is_empty(),
            "the grant names its daemon"
        );

        // The gate speaks the engine's pause; the body's next poll applies
        // it, and the second conversation's grant carries the new reading.
        gate_write.send(()).unwrap();
        std::thread::sleep(Duration::from_millis(400));
        let grant = invite(&dir);
        assert_eq!(grant.vm_state, "paused");

        // The engine's wire end ends the run with 2 — and takes the door
        // down: the server's stop unlinks its socket file.
        drop(gate_end);
        let code = run
            .1
            .recv_timeout(Duration::from_secs(5))
            .expect("the run hung instead of ending on the engine's end");
        assert_eq!(code, 2, "an engine end is exit 2");
        assert!(
            !dir.join(roles::SOCKET_NAME).exists(),
            "the door's file went with the run"
        );
        drop(park);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The door's verb, whole: a grant, then a post-grant ask whose line
    /// the engine's own command leg answers, its reply carrying the loop's
    /// verdict — `the engine took pause` — and an ask the vocabulary
    /// does not serve, answered by its own naming. The engine fake's
    /// command leg answers `ok` to every line (engine.rs's one-line
    /// shape); the live ` Pause'd ` event never races this read.
    #[test]
    fn a_verb_rides_the_loop_and_the_engine_takes_the_line() {
        use std::os::unix::fs::PermissionsExt;
        let dir = fresh("verb-door");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

        let _hold = engine_fake::start(&dir);
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

        // The door: probe until bound, then a granted conversation.
        for _ in 0..40 {
            match UnixStream::connect(dir.join(roles::SOCKET_NAME)) {
                Ok(stream) => {
                    drop(stream);
                    break;
                }
                Err(_) => std::thread::sleep(Duration::from_millis(50)),
            }
        }
        let mut asker = UnixStream::connect(dir.join(roles::SOCKET_NAME)).unwrap();
        asker
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        write_envelope(
            &mut asker,
            &envelope_of(envelope::Payload::RoleInvite(RoleInvite {
                role: crate::proto::roles::Role::ControlPanel as i32,
                package: String::new(),
                client_version: "the battery's asker".into(),
            })),
        )
        .unwrap();
        read_envelope(&mut asker).unwrap().unwrap();

        // The ask the engine takes: the loop's line lands, the verdict
        // says so, and the reply pairs the asker's id.
        write_envelope(
            &mut asker,
            &envelope_of(envelope::Payload::Verb(Verb {
                name: String::from("pause"),
                argument: String::new(),
            })),
        )
        .unwrap();
        let answer = read_envelope(&mut asker).unwrap().unwrap();
        assert_eq!(answer.request_id, 0, "the ask rode envelope_of's id");
        match answer.payload {
            Some(envelope::Payload::Reply(the_reply)) => {
                assert_eq!(the_reply.status, reply::Status::Ok as i32);
                assert_eq!(the_reply.message, "the engine took pause");
            }
            _ => panic!("a verb's verdict was expected"),
        }

        // The ask the vocabulary does not serve: it names its own way out.
        let mut sound = envelope_of(envelope::Payload::Verb(Verb {
            name: String::from("sound"),
            argument: String::from("playback on"),
        }));
        sound.request_id = 77;
        write_envelope(&mut asker, &sound).unwrap();
        let answer = read_envelope(&mut asker).unwrap().unwrap();
        assert_eq!(answer.request_id, 77, "the refusal pairs the asker's id");
        match answer.payload {
            Some(envelope::Payload::Reply(the_reply)) => {
                assert_eq!(the_reply.status, reply::Status::Unsupported as i32);
                assert!(
                    the_reply.message.contains("sound is not served"),
                    "the refusal names the ask: {}",
                    the_reply.message
                );
            }
            _ => panic!("a refusal was expected"),
        }

        drop(park);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The session lanes, whole: a grant, then four asks whose payloads
    /// the guest's agent stand-in answers in kind — a launch (the daemon's
    /// own display id 1) answered `DisplayReady` with the counter's id and
    /// the package through, a resize answered `DisplayReady` again, a
    /// close answered the generic `Reply{Ok}`, `list-apps` answered an
    /// `AppList`. Typed answers pass through the door unopened.
    #[test]
    fn a_launch_lane_rides_the_session_and_the_answers_pass_through() {
        use std::os::unix::fs::PermissionsExt;
        let dir = fresh("lane-door");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

        let _hold = engine_fake::start(&dir);
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

        // The door: probe until bound, then a granted conversation.
        for _ in 0..40 {
            match UnixStream::connect(dir.join(roles::SOCKET_NAME)) {
                Ok(stream) => {
                    drop(stream);
                    break;
                }
                Err(_) => std::thread::sleep(Duration::from_millis(50)),
            }
        }
        let mut asker = UnixStream::connect(dir.join(roles::SOCKET_NAME)).unwrap();
        asker
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        write_envelope(
            &mut asker,
            &envelope_of(envelope::Payload::RoleInvite(RoleInvite {
                role: crate::proto::roles::Role::ControlPanel as i32,
                package: String::new(),
                client_version: "the battery's asker".into(),
            })),
        )
        .unwrap();
        read_envelope(&mut asker).unwrap().unwrap();

        /// One flat ask on the lane, in the id the test tracks.
        fn say_line(stream: &mut UnixStream, request_id: u64, name: &str, argument: &str) {
            let mut ask = envelope_of(envelope::Payload::Verb(Verb {
                name: String::from(name),
                argument: String::from(argument),
            }));
            ask.request_id = request_id;
            write_envelope(stream, &ask).unwrap();
        }

        // Launch: the first display id is the daemon's own counter's.
        say_line(&mut asker, 11, "launch", "com.avo.notes 1080 2400 420 60");
        let answer = read_envelope(&mut asker).unwrap().unwrap();
        assert_eq!(answer.request_id, 11, "the lane's answer pairs the asker's id");
        match answer.payload {
            Some(envelope::Payload::DisplayReady(ready)) => {
                assert_eq!(ready.display_id, 1, "the daemon's own counter assigned");
                assert_eq!(ready.package, "com.avo.notes");
            }
            _ => panic!("a launch's answer was DisplayReady expected"),
        }

        // Resize: by the id the launch was given, guest's answer through.
        say_line(&mut asker, 12, "resize", "1 400 300");
        let answer = read_envelope(&mut asker).unwrap().unwrap();
        match answer.payload {
            Some(envelope::Payload::DisplayReady(ready)) => {
                assert_eq!(ready.display_id, 1);
                assert_eq!(ready.package, "resized");
            }
            _ => panic!("a resize's answer was DisplayReady expected"),
        }

        // Close and a listing: the generic and typed answers alike.
        say_line(&mut asker, 13, "close", "1");
        let answer = read_envelope(&mut asker).unwrap().unwrap();
        match answer.payload {
            Some(envelope::Payload::Reply(the_reply)) => {
                assert_eq!(the_reply.status, reply::Status::Ok as i32);
            }
            _ => panic!("a close's answer was a reply expected"),
        }
        say_line(&mut asker, 14, "list-apps", "");
        let answer = read_envelope(&mut asker).unwrap().unwrap();
        match answer.payload {
            Some(envelope::Payload::AppList(list)) => assert!(list.apps.is_empty()),
            _ => panic!("list-apps's answer was an AppList expected"),
        }

        drop(park);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
