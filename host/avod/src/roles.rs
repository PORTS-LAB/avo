//! The daemon's own Unix-socket listener: the XPC surface's Linux
//! successor, phase 3 of docs/linux-port.md. The Mac's surface is
//! host/AvoKit/Sources/AvoKit/XPCInterface.swift: its lines 4-5 name the
//! audience ("XPC between the Runtime Daemon and its clients (Control
//! Panel, menu bar, App Shims and the engine)"), its line 12 pins the gate
//! (`hello` "Must be the first call. `request`: JSON `ClientHello`; reply:
//! JSON `DaemonHello`"), and its lines 267-285 give the payloads
//! (`ClientHello` with `role: controlPanel | shim(package:) | engine` and
//! `version`, 267-275; `DaemonHello` with `daemonVersion` and `status`,
//! 283-285). The JSON `Data` payloads travel here as control channel
//! envelopes instead — `RoleInvite` and `RoleGrant`, proto.rs — so one
//! wire shape and one framing (crate::control's varint-delimited
//! envelopes, control.rs:16-63) serve every speaker.
//!
//! The rest of that @objc protocol — the verb set past the hello
//! (`status`, `startVM`, `stopVM`, `restartVM`, `retryGPU`, the GPU-cache
//! pair, `takeSnapshot`, `resetAndroid`, storage, configuration,
//! `setFrameRateLimit`, apps/install/uninstall/`forceStop` —
//! XPCInterface.swift:17-76 and through the protocol's end) — is the
//! Control Panel's verb surface, and none of its state lives here: the
//! state machines are the Mac's DaemonService.swift's and land in later
//! phase-3 slices. Until then every post-hello request gets
//! `Reply{Unsupported}` naming what came in; Ping keeps its liveness.
//!
//! Caller validation: the Mac checks code-signing anchors configured at
//! the listener (nothing greps as `shouldAcceptNewConnection` in
//! XPCInterface.swift — it is configured at the listener). The Linux
//! port rethinks that for the absence of code signatures —
//! docs/linux-port.md phase 3: "socket credentials and paths instead".
//! Both legs live here: the **path leg** enforced in stable std — the
//! runtime directory must be the daemon's own user's 0700, checked when
//! the socket is born (`the_mount_gate`), so no other uid's process can
//! even reach an accept; the **credential leg** — SO_PEERCRED's uid
//! against the daemon's own euid — kept in its pure form (`peer_is_own`),
//! unit-tested on both sides, ready to ride the per-connection accept the
//! moment std's `UnixStream::peer_cred()` leaves its
//! `peer_credentials_unix_socket` gate (issue #42839; on this stable
//! toolchain it is unstable and the crate reaches for no unstable
//! surface). The granted role is recorded per connection (and per
//! server, in `Server::seen`) so the verb-level role checks later land
//! on something.
//!
//! Goodbye: the daemon's session shape (session.rs:9-10 — "only the
//! session's own `close` ever says goodbye") carries over: a client's
//! Goodbye closes the stream and answers nothing — the goodbye is theirs
//! or nobody's (session.rs:536).
//!
//! Stopping: the accept loop is nonblocking and parks on short polls;
//! `Server::stop` raises a flag and wakes the park with one dial of the
//! socket's own path — a std-only rouse, no timers, no async.

use std::fs;
use std::io;
use std::net::Shutdown;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::control::{read_envelope, write_envelope};
use crate::proto::{
    envelope, reply, roles, Envelope, Ping, Pong, Reply, RoleGrant, PROTOCOL_MIN_VERSION,
    PROTOCOL_VERSION,
};

/// The socket's file name: it lives at `<runtime>/daemon.sock` (agreed
/// with the packaging slice, which owns the runtime directory — the Mac's
/// export line is XPCInterface.swift:10, "Exported by the daemon on
/// `AvoIdentifiers.daemonMachService`"; a Unix path is what Linux has).
pub const SOCKET_NAME: &str = "daemon.sock";

/// The daemon's version string — each RoleGrant's `daemon_version` unless
/// the caller hands `serve_with` its own build (XPCInterface.swift:284,
/// `DaemonHello.daemonVersion`). The daemon body passes its real build
/// when it arrives.
pub const DAEMON_VERSION: &str = "avod 0";

/// What starting the roles socket can die with. `Bind` covers the coming
/// up itself — an unwritable or already-taken path (a stale socket file
/// from a killed process, which the packaging's restart cleans), a
/// runtime directory wider than 0700 or owned by another uid (the mount
/// gate), and an euid that does not read from /proc.
#[derive(Debug)]
pub enum ServeError {
    Bind(io::Error),
}

impl std::fmt::Display for ServeError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ServeError::Bind(error) => write!(out, "the roles socket could not come up: {error}"),
        }
    }
}

impl std::error::Error for ServeError {}

/// The daemon body's status, asked exactly when a RoleGrant is built
/// (XPCInterface.swift:285's `status`) — never as a poll.
type StatusFn = Arc<dyn Fn() -> String + Send + Sync>;

/// One verdict from the daemon's body: Ok carries the reply's message;
/// Err carries the reply's status and its wording.
pub type Verdict = Result<String, (reply::Status, String)>;

/// One ask the door hands its daemon's bus: what the verb said and who
/// spoke, with the oneshot the verdict rides. Mac truth: the verb set is
/// XPCInterface.swift's selectors; per-role gating lands on the bus.
pub struct Ask {
    pub role: roles::Role,
    pub name: String,
    pub argument: String,
    pub settle: mpsc::Sender<Verdict>,
}

/// The body's verb bus: posts the ask (the loop indie the door reads
/// it), no waiting — the verdict's own oneshot is the waiting.
pub type VerbBus = Arc<dyn Fn(Ask) + Send + Sync>;

/// Who has been granted a hello, `(role, package)` in arrival order: the
/// shim's package matches XPCInterface.swift:270's `shim(package:)`, the
/// Control Panel and the engine come in empty. Recorded per connection
/// and per server so the verb-level checks later land on something.
type SeenList = Arc<Mutex<Vec<(roles::Role, String)>>>;

/// A serving socket: what `serve`/`serve_with` leave behind — the
/// stopping handle and the hello record a verifier reads. The accept
/// loop's join handle rides inside; `stop` joins it, so a caller is
/// never handed a half-stopped state.
pub struct Server {
    /// The path bound; serve owns the socket file it creates there and
    /// unlinks it when the loop ends — a stale file would refuse the
    /// next bind.
    pub path: PathBuf,
    /// Granted hellos, `(role, package)` in arrival order — the verifier
    /// hunk's read side. The Mac's per-role verb dispatch grows out of
    /// the same record.
    pub seen: SeenList,
    stopped: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Server {
    /// Stops the accept loop, unlinks the socket file, joins the accept
    /// thread. Connections already running keep speaking: each rides its
    /// client's EOF like any other conversation — the stop flag gates
    /// the listen, not the connections (the stop test pins that).
    pub fn stop(mut self) {
        self.shutdown();
    }

    /// The stopping mechanics: the flag out first, then one dial of the
    /// socket's own path to wake the parked accept loop (a std-only
    /// rouse — the loop's poll would see the same flag one tick later),
    /// then the join.
    fn shutdown(&mut self) {
        self.stopped.store(true, Ordering::Release);
        let _ = UnixStream::connect(&self.path);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The same stop on ordinary drop: an abandoned server takes its socket
/// file and its accept thread down, and the runtime directory stays
/// exactly as the packaging slice left it.
impl Drop for Server {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Serves the roles socket at `path` — usually `<runtime>/`+SOCKET_NAME.
/// The status closure is asked only when a RoleGrant is built, never as a
/// poll. The mount gate (the 0700 directory of the daemon's own user)
/// rides before the bind, with the daemon's own euid read from
/// /proc/self/status (`own_euid`); `serve_with` carries its own answers
/// in for anyone who knows better.
pub fn serve(path: PathBuf, status: impl Fn() -> String + Send + Sync + 'static) -> Result<Server, ServeError> {
    let own_uid = own_euid()
        .ok_or_else(|| ServeError::Bind(io::Error::other("the daemon's own uid does not read from /proc/self/status")))?;
    serve_with(path, status, DAEMON_VERSION, own_uid)
}

/// `serve` with a verb bus: post-grant `Verb` asks go to the bus, the
/// verdict rides back as the generic Reply in the asker's id. The door
/// without a bus answers the catch-all as ever — `serve` itself.
pub fn serve_with_verbs(
    path: PathBuf,
    status: impl Fn() -> String + Send + Sync + 'static,
    bus: VerbBus,
) -> Result<Server, ServeError> {
    let own_uid = own_euid()
        .ok_or_else(|| ServeError::Bind(io::Error::other("the daemon's own uid does not read from /proc/self/status")))?;
    serve_with_verbs_uid(path, status, DAEMON_VERSION, own_uid, Some(bus))
}

/// `serve` with the version string and the daemon's own uid in hand —
/// the tests' seam (the daemon body calls `serve`). `daemon_version`
/// becomes each RoleGrant's `daemon_version` (XPCInterface.swift:284);
/// `own_uid` is the mount gate's yardstick — docs/linux-port.md phase 3's
/// "socket credentials and paths instead", the Mac's listener-side
/// code-signing anchor check rethought.
pub fn serve_with(
    path: PathBuf,
    status: impl Fn() -> String + Send + Sync + 'static,
    daemon_version: &str,
    own_uid: u32,
) -> Result<Server, ServeError> {
    serve_with_verbs_uid(path, status, daemon_version, own_uid, None)
}

/// The plumbing every `serve*` lands in: the mount gate, the bind, the
/// accept loop with the verb bus (None = the catch-all as ever).
fn serve_with_verbs_uid(
    path: PathBuf,
    status: impl Fn() -> String + Send + Sync + 'static,
    daemon_version: &str,
    own_uid: u32,
    verbs: Option<VerbBus>,
) -> Result<Server, ServeError> {
    the_mount_gate(&path, own_uid)?;
    let listener = UnixListener::bind(&path).map_err(ServeError::Bind)?;
    let stopped = Arc::new(AtomicBool::new(false));
    let seen: SeenList = Arc::new(Mutex::new(Vec::new()));
    let thread = {
        let status: StatusFn = Arc::new(status);
        let daemon_version = Arc::<str>::from(daemon_version);
        let seen = Arc::clone(&seen);
        let stopped = Arc::clone(&stopped);
        let loop_path = path.clone();
        thread::spawn(move || {
            accept_loop(listener, loop_path, status, daemon_version, seen, stopped, verbs)
        })
    };
    Ok(Server { path, seen, stopped, thread: Some(thread) })
}

/// The mount gate — the path leg of the caller check (docs/linux-port.md
/// phase 3: "socket credentials and paths instead"): the directory
/// holding the socket must be the daemon's own user's 0700. With that
/// mount, no other uid's process can reach the socket file at all — the
/// OS is the gate, at open, per connection, with nothing of this crate's
/// doing per accept. The credential leg (SO_PEERCRED's uid equality)
/// keeps its pure form in `peer_is_own` and rides per connection when
/// std's `peer_credentials_unix_socket` gate lifts (issue #42839 — on
/// this stable toolchain `UnixStream::peer_cred()` is unstable, and no
/// unstable surface comes in here; the packaging slice creates the
/// directory the way it wants and this gate refuses to listen otherwise).
fn the_mount_gate(socket_path: &Path, own_uid: u32) -> Result<(), ServeError> {
    let dir = socket_path.parent().filter(|dir| !dir.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let meta = fs::metadata(dir).map_err(ServeError::Bind)?;
    if !meta.is_dir() {
        return Err(ServeError::Bind(io::Error::other(format!(
            "{} is no directory for the socket's mount (docs/linux-port.md phase 3: 0700)",
            dir.display()
        ))));
    }
    let mode = meta.mode() & 0o777;
    if mode != 0o700 {
        // Wider than the daemon's own user: a stranger's process could
        // reach the accept. Refuse loudly rather than listen through it.
        return Err(ServeError::Bind(io::Error::other(format!(
            "{} is {:o}, not the 0700 mount docs/linux-port.md phase 3 wants",
            dir.display(),
            mode
        ))));
    }
    if meta.uid() != own_uid {
        // Not the daemon's own user's directory: wrong owner, same
        // refusal — the 0700 the file carries would belong to someone
        // else's home arithmetic.
        return Err(ServeError::Bind(io::Error::other(format!(
            "{} is owned by uid {}, not the daemon's own uid {} \
             (docs/linux-port.md phase 3: the mount is the daemon's user's)",
            dir.display(),
            meta.uid(),
            own_uid
        ))));
    }
    Ok(())
}

/// The accept loop: nonblocking so the stop flag stays observable, parked
/// on 10 ms polls and woken early by `Server`'s self-dial. Each accepted
/// stream gets its own thread — the engine's serve spawns one reader per
/// connection (control.rs:426-427) the same way.
fn accept_loop(
    listener: UnixListener,
    path: PathBuf,
    status: StatusFn,
    daemon_version: Arc<str>,
    seen: SeenList,
    stopped: Arc<AtomicBool>,
    verbs: Option<VerbBus>,
) {
    let _ = listener.set_nonblocking(true);
    loop {
        if stopped.load(Ordering::Acquire) {
            break;
        }
        match listener.accept() {
            Ok((stream, _)) => {
                let status = Arc::clone(&status);
                let daemon_version = Arc::clone(&daemon_version);
                let seen = Arc::clone(&seen);
                let verbs = verbs.clone();
                thread::spawn(move || connection(stream, status, daemon_version, seen, verbs));
            }
            // WouldBlock is the loop's own park: nothing to accept, so
            // re-look at the flag soon.
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
            }
            // The listener itself died (the socket file pulled from under
            // it, the shutdown race's worst case); the loop's purpose is
            // spent, and the cleanup below still runs.
            Err(_) => break,
        }
    }
    // The socket file is serve's own; the runtime directory stays its
    // owner's.
    let _ = fs::remove_file(&path);
}

/// One client's whole life on the socket. The first envelope must be a
/// RoleInvite — the Mac: `hello` must be the first call
/// (XPCInterface.swift:12, its payloads at 267-285) — and the credential
/// leg of the caller check (`peer_is_own`, the `UnixStream::peer_cred()`
/// uid comparison) rides before anything is written back. The granted
/// role is stashed here (`granted`) and in `seen` for the verifier:
/// recording it is what the verb-level checks later land on.
fn connection(
    mut stream: UnixStream,
    status: StatusFn,
    daemon_version: Arc<str>,
    seen: SeenList,
    verbs: Option<VerbBus>,
) {
    let mut granted: Option<(roles::Role, String)> = None;
    loop {
        // One envelope at a time on the control channel's framing
        // (control.rs:29-63). EOF or wire garbage ends everything: the
        // Mac's XPC drops the connection on a failed decode the same way.
        let envelope = match read_envelope(&mut stream) {
            Ok(Some(envelope)) => envelope,
            // `Ok(None)` is not how read_envelope answers, and either —
            // an empty Option or the framing/decode errors — is the
            // stream's end for this listener's purposes.
            _ => break,
        };
        let request_id = envelope.request_id;
        match (granted.is_none(), envelope.payload) {
            // The hello. The credential check rides before the reply:
            // the Mac's anchor check sits at the listener (nothing greps
            // as shouldAcceptNewConnection in XPCInterface.swift), its
            // Linux substitute is uid equality (docs/linux-port.md
            // phase 3), and the mount gate (`the_mount_gate`, at serve
            // time) is the leg the OS already enforced to reach this
            // line — a stranger's process could not have opened the
            // socket file. `peer_is_own` below is the credential leg's
            // seam for when std's gate lifts; on this stable toolchain
            // `UnixStream::peer_cred()` is still unstable (issue
            // #42839), so the retained form is pure and unit-tested on
            // both sides.
            (true, Some(envelope::Payload::RoleInvite(invite))) => {
                // An unknown role value decodes on the wire but names
                // nothing the Mac's `ClientHello.Role` speaks
                // (XPCInterface.swift:268-271): the hello fails like the
                // Mac's undecodable JSON — the connection closes, and no
                // grant ever goes out.
                let role = match roles::Role::try_from(invite.role) {
                    Ok(role) => role,
                    Err(_) => break,
                };
                // The Mac's `ClientHello` → `DaemonHello`
                // (XPCInterface.swift:267-285): the version string and
                // the protocol numbers spell themselves here, and the
                // status closure is asked when the grant is built — this
                // is its only call (never a poll).
                let grant = RoleGrant {
                    daemon_version: daemon_version.to_string(),
                    protocol_version: PROTOCOL_VERSION,
                    min_supported: PROTOCOL_MIN_VERSION,
                    vm_state: status(),
                };
                // The record lands before the wire: a client holding its
                // grant can read its record without racing (the seen
                // test's sync, no polling).
                let entry = (role, invite.package);
                seen.lock().unwrap().push(entry.clone());
                granted = Some(entry);
                // The reply carries the requester's id — proto.rs's
                // Envelope.request_id doc: a reply carries the same id.
                if write_envelope(
                    &mut stream,
                    &a_reply(request_id, envelope::Payload::RoleGrant(grant)),
                )
                .is_err()
                {
                    break;
                }
            }
            // Any other first envelope: the Mac's hello must be the
            // first call (XPCInterface.swift:12), so the connection
            // closes with no reply — a malformed XPC conversation never
            // reaches a verb, and neither does this.
            (true, _) => break,

            // Liveness: Ping answers Pong with the nonce straight back,
            // so a caller can probe the socket cheaply before its verb
            // set ports. The reply pairs the requester's id
            // (proto.rs:578-580).
            (false, Some(envelope::Payload::Ping(Ping { nonce }))) => {
                if write_envelope(
                    &mut stream,
                    &a_reply(request_id, envelope::Payload::Pong(Pong { nonce })),
                )
                .is_err()
                {
                    break;
                }
            }
            // Goodbye: the goodbye is theirs or nobody's (session.rs:536;
            // the session doc at session.rs:9-10 says only the session's
            // own close ever writes one). This socket answers nothing —
            // the stream just ends.
            (false, Some(envelope::Payload::Goodbye(_))) => break,
            // The verb: with a bus, the door hands the ask over and
            // awaits the verdict — the generic Reply in the asker's id.
            // Without a bus, the catch-all names it as ever. Mac truth:
            // the verb set is XPCInterface.swift:17-127, served by
            // DaemonService.swift's state machines (the body's loop says
            // the words to the engine's own grammar).
            (false, Some(envelope::Payload::Verb(verb))) => {
                let reply = match verbs.as_ref() {
                    Some(bus) => {
                        let (seal, settled) = mpsc::channel::<Verdict>();
                        bus(Ask {
                            role: granted.as_ref().expect("the verb arm is post-grant").0,
                            name: verb.name.clone(),
                            argument: verb.argument.clone(),
                            settle: seal,
                        });
                        match settled.recv() {
                            Ok(Ok(message)) => a_reply(
                                request_id,
                                envelope::Payload::Reply(Reply {
                                    status: reply::Status::Ok as i32,
                                    message,
                                }),
                            ),
                            Ok(Err((status, message))) => a_reply(
                                request_id,
                                envelope::Payload::Reply(Reply {
                                    status: status as i32,
                                    message,
                                }),
                            ),
                            Err(_) => a_reply(
                                request_id,
                                envelope::Payload::Reply(Reply {
                                    status: reply::Status::Failed as i32,
                                    message: String::from(
                                        "the daemon went away before the ask settled",
                                    ),
                                }),
                            ),
                        }
                    }
                    // No bus: the catch-all, naming the ask. The match
                    // consumed the verb; a twin names it.
                    None => an_unsupported(request_id, Some(&envelope::Payload::Verb(verb.clone()))),
                };
                if write_envelope(&mut stream, &reply).is_err() {
                    break;
                }
            }
            // The Mac's verb set (XPCInterface.swift:17-76 —
            // status/startVM/stopVM/restartVM/retryGPU/…/forceStop — and
            // through the protocol's end) is DaemonService.swift's state
            // machinery, later slices of the port. Nothing answers with
            // state here: the catch-all names what came in and keeps the
            // connection open.
            (false, known) => {
                let envelope = an_unsupported(request_id, known.as_ref());
                if write_envelope(&mut stream, &envelope).is_err() {
                    break;
                }
            }
        }
    }
    // The stream ends whole on every exit past the loop: no half-open
    // transports left behind for the other side's reads.
    let _ = stream.shutdown(Shutdown::Both);
}

/// The envelope every reply here travels in: the requester's id carries
/// (proto.rs's Envelope.request_id doc) — `envelope_of` stamps 0, and the
/// hello's and the verbs' ids are the asker's.
fn a_reply(request_id: u64, payload: envelope::Payload) -> Envelope {
    Envelope { protocol_version: PROTOCOL_VERSION, request_id, payload: Some(payload) }
}

/// The post-hello catch-all: `Reply{Unsupported}`, naming the payload
/// that came in and where its state machines actually live.
fn an_unsupported(request_id: u64, payload: Option<&envelope::Payload>) -> Envelope {
    let what = payload.map(named).unwrap_or("an envelope without a payload");
    a_reply(
        request_id,
        envelope::Payload::Reply(Reply {
            status: reply::Status::Unsupported as i32,
            message: format!(
                "{what} is not served by the roles socket yet: the daemon's verb \
                 state machines are the Mac's DaemonService.swift's, a later \
                 slice of the port"
            ),
        }),
    )
}

/// What an envelope came as, for the catch-all's message ("naming it").
/// Every arm, the proto.rs oneof in order.
fn named(payload: &envelope::Payload) -> &'static str {
    match payload {
        envelope::Payload::Hello(_) => "Hello",
        envelope::Payload::Goodbye(_) => "Goodbye",
        envelope::Payload::Ping(_) => "Ping",
        envelope::Payload::Pong(_) => "Pong",
        envelope::Payload::Reply(_) => "Reply",
        envelope::Payload::Verb(_) => "Verb",
        envelope::Payload::Launch(_) => "Launch",
        envelope::Payload::Resize(_) => "Resize",
        envelope::Payload::Close(_) => "Close",
        envelope::Payload::Install(_) => "Install",
        envelope::Payload::Uninstall(_) => "Uninstall",
        envelope::Payload::SetClipboard(_) => "SetClipboard",
        envelope::Payload::ListApps(_) => "ListApps",
        envelope::Payload::ForceStop(_) => "ForceStop",
        envelope::Payload::DeleteAppData(_) => "DeleteAppData",
        envelope::Payload::GetPermissions(_) => "GetPermissions",
        envelope::Payload::SetPermission(_) => "SetPermission",
        envelope::Payload::ShareFiles(_) => "ShareFiles",
        envelope::Payload::SetDisplayVisibility(_) => "SetDisplayVisibility",
        envelope::Payload::OpenNotification(_) => "OpenNotification",
        envelope::Payload::DismissNotification(_) => "DismissNotification",
        envelope::Payload::SetRefreshRate(_) => "SetRefreshRate",
        envelope::Payload::FocusDisplay(_) => "FocusDisplay",
        envelope::Payload::AppInstalled(_) => "AppInstalled",
        envelope::Payload::AppRemoved(_) => "AppRemoved",
        envelope::Payload::DisplayReady(_) => "DisplayReady",
        envelope::Payload::TaskClosed(_) => "TaskClosed",
        envelope::Payload::Notification(_) => "Notification",
        envelope::Payload::NotificationRemoved(_) => "NotificationRemoved",
        envelope::Payload::ClipboardChanged(_) => "ClipboardChanged",
        envelope::Payload::OrientationRequest(_) => "OrientationRequest",
        envelope::Payload::AppList(_) => "AppList",
        envelope::Payload::PermissionList(_) => "PermissionList",
        envelope::Payload::DisplayContentChanged(_) => "DisplayContentChanged",
        envelope::Payload::TaskStarted(_) => "TaskStarted",
        envelope::Payload::RoleInvite(_) => "RoleInvite",
        envelope::Payload::RoleGrant(_) => "RoleGrant",
    }
}

/// The credential leg of the caller check, its purest form — the
/// credential's uid against the daemon's own euid
/// (`UnixStream::peer_cred()` is the surface; it is still behind std's
/// `peer_credentials_unix_socket` gate on this stable toolchain, issue
/// #42839, so nothing unstable comes in here). `None` is a socket whose
/// credentials would not read. The real mismatch path cannot run under
/// one uid — the battery's daemon and its clients share a process — so
/// the unit on both sides lives in the tests (the only caller until the
/// std gate lifts, hence `allow(dead_code)` there), and the fn is the
/// seam the per-connection accept path rides when the gate does. The
/// path leg (`the_mount_gate`) does the per-mount enforcing in stable
/// std.
#[allow(dead_code)]
fn peer_is_own(peer_uid: Option<u32>, own_uid: u32) -> bool {
    peer_uid == Some(own_uid)
}

/// The daemon's effective uid, from /proc/self/status's `Uid` line — std
/// carries no geteuid, and the mount gate and the credential leg both
/// want the euid. `None` when /proc does not read; `serve` surfaces that
/// as `ServeError::Bind`.
fn own_euid() -> Option<u32> {
    euid_of(&fs::read_to_string("/proc/self/status").ok()?)
}

/// The euid slice of one /proc/self/status body: the `Uid:` line's real,
/// effective, saved, fs numbers — the effective one is the second
/// (`Uid:\t<real>\t<effective>\t<saved>\t<fs>`).
fn euid_of(status: &str) -> Option<u32> {
    let uid_line = status.lines().find(|line| line.starts_with("Uid:"))?;
    uid_line.split_whitespace().nth(2)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::envelope_of;
    use crate::proto::{goodbye, Goodbye, Launch, RoleInvite, Verb};
    use prost::Message as _;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::sync::atomic::AtomicU64;

    /// A fresh socket path per test: `/tmp/avod-roles-<pid>-<n>/daemon.sock`
    /// — UnixListener::bind refuses collisions outright, and each test
    /// owns its directory for its whole run (the engine fixture's naming
    /// shape, engine.rs:552-556, with a directory around the file). The
    /// directory is mounted 0700 for the daemon's own user — what the
    /// packaging slice will own in production (`the_mount_gate` refuses
    /// anything else, and the tests want to pass it).
    struct Socket {
        path: PathBuf,
    }

    impl Socket {
        fn named() -> Socket {
            static NEXT: AtomicU64 = AtomicU64::new(1);
            let dir = std::env::temp_dir().join(format!(
                "avod-roles-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&dir).unwrap();
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
            Socket { path: dir.join(SOCKET_NAME) }
        }
    }

    impl Drop for Socket {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(self.path.parent().unwrap());
        }
    }

    /// The battery's daemon and its clients share one process, so the
    /// euid the checks compare against is this process's own — exactly
    /// what `serve` resolves in production.
    fn own_uid() -> u32 {
        own_euid().expect("the battery's Linux reads /proc/self/status")
    }

    fn dial(path: &Path) -> UnixStream {
        UnixStream::connect(path).unwrap()
    }

    /// One framed envelope onto a client's stream, with the asker's id
    /// in the header (control.rs's own test does the same patching,
    /// control.rs:153-155).
    fn say(stream: &mut UnixStream, request_id: u64, payload: envelope::Payload) {
        let mut envelope = envelope_of(payload);
        envelope.request_id = request_id;
        write_envelope(stream, &envelope).unwrap();
    }

    fn hear(stream: &mut UnixStream) -> Envelope {
        read_envelope(stream).unwrap().expect("an envelope")
    }

    fn invite(role: roles::Role, package: &str) -> envelope::Payload {
        envelope::Payload::RoleInvite(RoleInvite {
            role: role as i32,
            package: package.into(),
            client_version: "roles-test 0".into(),
        })
    }

    /// The whole hello dance, for tests that need to be past the gate:
    /// the invite goes out with `request_id`, the grant comes back
    /// paired. Returns the grant.
    fn hello(stream: &mut UnixStream, role: roles::Role, package: &str, request_id: u64) -> RoleGrant {
        say(stream, request_id, invite(role, package));
        let grant = hear(stream);
        assert_eq!(grant.request_id, request_id, "the reply pairs the asker's id (proto.rs:578-580)");
        match grant.payload {
            Some(envelope::Payload::RoleGrant(grant)) => grant,
            other => panic!("the hello's answer is a grant, not {other:?}"),
        }
    }

    /// The one screwed-down wire shape of the new tags: field 62, wire
    /// type 2 — key varint (62 << 3 | 2) = 498 → 0xF2 0x03 — then the
    /// inner length (14) and the shim-shaped inner RoleInvite: role 1
    /// (`0x08 0x01`), package "com.avo" (0x12 0x07), version "9"
    /// (`0x1A 0x01`). The ladder only ever grows (proto.rs:3: "fields
    /// are only ever added, never renumbered"), so peers that have not
    /// heard of 62/63 skip the fields the same way this file's decode
    /// skips one it has not met.
    #[test]
    fn the_role_invites_wire_bytes_are_pinned() {
        let envelope = Envelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: 0,
            payload: Some(envelope::Payload::RoleInvite(RoleInvite {
                role: roles::Role::Shim as i32,
                package: "com.avo".into(),
                client_version: "9".into(),
            })),
        };
        let mut buf = Vec::new();
        envelope.encode(&mut buf).unwrap();
        assert_eq!(
            buf,
            vec![
                0x08, 0x01, 0xF2, 0x03, 0x0E, 0x08, 0x01, 0x12, 0x07, b'c', b'o', b'm', b'.', b'a',
                b'v', b'o', 0x1A, 0x01, b'9',
            ],
            "the wire must not move; 62/63 join at the ladder's end"
        );
        let back = Envelope::decode(buf.as_slice()).unwrap();
        match back.payload {
            Some(envelope::Payload::RoleInvite(invite)) => {
                assert_eq!(invite.role, roles::Role::Shim as i32);
                assert_eq!(invite.package, "com.avo");
                assert_eq!(invite.client_version, "9");
            }
            other => panic!("an invite must round-trip as one: {other:?}"),
        }
    }

    /// The hello dance, end to end: ControlPanel in, the grant carries
    /// the daemon version serve_with was handed, the protocol ladder's
    /// two numbers (proto.rs:10-12) and the status closure's one word —
    /// the closure is asked at grant time, not before. Mac truth:
    /// XPCInterface.swift:12 (the first-call gate) and 267-285
    /// (ClientHello/DaemonHello).
    #[test]
    fn the_hello_dance_grants_the_role() {
        let socket = Socket::named();
        let server =
            serve_with(socket.path.clone(), || String::from("paused"), "test-daemon 9", own_uid())
                .unwrap();
        let mut client = dial(&socket.path);
        let grant = hello(&mut client, roles::Role::ControlPanel, "", 5);
        assert_eq!(
            grant.daemon_version, "test-daemon 9",
            "DaemonHello.daemonVersion — XPCInterface.swift:284"
        );
        assert_eq!(grant.protocol_version, PROTOCOL_VERSION);
        assert_eq!(grant.min_supported, PROTOCOL_MIN_VERSION);
        assert_eq!(
            grant.vm_state, "paused",
            "the status closure builds the grant (XPCInterface.swift:285)"
        );
        // The grant itself recorded too — the Control Panel comes in
        // package-less (XPCInterface.swift:269: `case controlPanel`).
        assert_eq!(
            *server.seen.lock().unwrap(),
            vec![(roles::Role::ControlPanel, String::new())],
        );
        server.stop();
    }

    /// The shim documents its package (XPCInterface.swift:270,
    /// `shim(package: String)`) and the grant lands it in the server's
    /// record — the table the later verb-level checks read.
    #[test]
    fn the_shims_role_and_package_are_recorded() {
        let socket = Socket::named();
        let server = serve_with(
            socket.path.clone(),
            || String::from("running"),
            DAEMON_VERSION,
            own_uid(),
        )
        .unwrap();
        let mut client = dial(&socket.path);
        let grant = hello(&mut client, roles::Role::Shim, "com.example.app", 0);
        assert_eq!(grant.daemon_version, DAEMON_VERSION);
        // The record precedes the wire (connection()'s doing), so a
        // client holding its grant reads its own row without polling.
        assert_eq!(
            *server.seen.lock().unwrap(),
            vec![(roles::Role::Shim, String::from("com.example.app"))],
        );
        server.stop();
    }

    /// Past the gate, the verb set is not served: the Mac's verbs
    /// (XPCInterface.swift:17-76 and onward) ride DaemonService.swift's
    /// state machines, later slices — the catch-all names what came in
    /// and keeps the connection open (a follow-up Ping still answers).
    #[test]
    fn a_post_hello_verb_gets_unsupported_naming_it() {
        let socket = Socket::named();
        let server =
            serve_with(socket.path.clone(), || String::from("running"), DAEMON_VERSION, own_uid())
                .unwrap();
        let mut client = dial(&socket.path);
        hello(&mut client, roles::Role::ControlPanel, "", 1);
        say(
            &mut client,
            42,
            envelope::Payload::Launch(Launch {
                package: "com.example.app".into(),
                ..Default::default()
            }),
        );
        let answer = hear(&mut client);
        assert_eq!(answer.request_id, 42, "the reply pairs the asker's id");
        match answer.payload {
            Some(envelope::Payload::Reply(answer)) => {
                assert_eq!(answer.status, reply::Status::Unsupported as i32);
                assert!(answer.message.contains("Launch"), "names it: {}", answer.message);
                assert!(
                    answer.message.contains("DaemonService"),
                    "names where the verbs live: {}",
                    answer.message
                );
            }
            other => panic!("not a reply: {other:?}"),
        }
        // The connection stayed open past the refusal: a Ping still
        // answers (the catch-all is not a close).
        say(&mut client, 43, envelope::Payload::Ping(Ping { nonce: 5 }));
        match hear(&mut client).payload {
            Some(envelope::Payload::Pong(pong)) => assert_eq!(pong.nonce, 5),
            other => panic!("not a pong: {other:?}"),
        }
        server.stop();
    }

    /// Before the hello nothing serves: any other first envelope — a
    /// Ping, here — closes the connection with no reply at all
    /// (XPCInterface.swift:12; the Mac's handshake never gets a daemon
    /// word for a stranger's first verb).
    #[test]
    fn a_non_invite_first_envelope_closes_the_connection() {
        let socket = Socket::named();
        let server =
            serve_with(socket.path.clone(), || String::from("running"), DAEMON_VERSION, own_uid())
                .unwrap();
        let mut client = dial(&socket.path);
        say(&mut client, 9, envelope::Payload::Ping(Ping { nonce: 1 }));
        let error = read_envelope(&mut client).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof, "closed, and silently");
        assert!(server.seen.lock().unwrap().is_empty(), "no grant, no record");
        server.stop();
    }

    /// The battery shares one uid between daemon and client, so the
    /// credential leg's mismatch path cannot run at the socket's level
    /// here — the check's logic runs as this pure unit on every side,
    /// and when std's `peer_credentials_unix_socket` gate lifts
    /// (issue #42839), the per-connection accept path rides the same fn
    /// for real (the doc says the same at `peer_is_own` and
    /// `connection`'s hello arm).
    #[test]
    fn the_peer_check_accepts_only_the_daemons_own_uid() {
        assert!(peer_is_own(Some(4242), 4242));
        assert!(!peer_is_own(Some(4243), 4242), "a different uid is refused outright");
        assert!(!peer_is_own(None, 4242), "no credentials is no grant");
    }

    /// The mount gate — the path leg (docs/linux-port.md phase 3's
    /// "socket credentials and paths instead"): a directory wider than
    /// the daemon's own user's 0700 is refused before the listen, and
    /// the socket never comes up there. The owner leg rides the same
    /// stat (another uid's directory reads the same refusal); a true
    /// cross-owner directory cannot be created from one uid in the
    /// battery, so the mode is the side exercised here.
    #[test]
    fn the_socket_mount_refuses_anything_wider_than_0700() {
        let socket = Socket::named();
        fs::set_permissions(
            socket.path.parent().unwrap(),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        let error = match serve_with(
            socket.path.clone(),
            || String::from("running"),
            DAEMON_VERSION,
            own_uid(),
        ) {
            Err(ServeError::Bind(error)) => error,
            Ok(_) => panic!("a mount wider than the daemon's own user must refuse the listen"),
        };
        assert!(error.to_string().contains("0700"), "names the mount: {error}");
    }

    /// `serve` needs the daemon's euid before anything passes; it reads
    /// /proc/self/status's `Uid` line (std carries no geteuid). This
    /// battery runs on Linux — its own /proc is there — and the line's
    /// shape is what euid_of parses purely.
    #[test]
    fn the_euid_is_the_uid_lines_second_number() {
        assert_eq!(
            euid_of("Uid:\t1000\t1000\t1000\t1000\nother lines\n"),
            Some(1000),
            "real, effective, saved, fs — the effective one is the second"
        );
        assert_eq!(euid_of("no uid line here"), None);
        assert!(own_euid().is_some(), "the battery's own /proc/self/status reads");
    }

    /// Liveness on a granted connection: Ping answers Pong with the
    /// nonce straight back (the pairing is what a shim tests as it
    /// comes up).
    #[test]
    fn pings_pong_their_nonce_straight_back() {
        let socket = Socket::named();
        let server =
            serve_with(socket.path.clone(), || String::from("running"), DAEMON_VERSION, own_uid())
                .unwrap();
        let mut client = dial(&socket.path);
        hello(&mut client, roles::Role::Engine, "", 1);
        say(&mut client, 3, envelope::Payload::Ping(Ping { nonce: 0x0A55 }));
        let pong = hear(&mut client);
        assert_eq!(pong.request_id, 3, "the reply pairs the asker's id");
        match pong.payload {
            Some(envelope::Payload::Pong(pong)) => assert_eq!(pong.nonce, 0x0A55, "nonce passthrough"),
            other => panic!("not a pong: {other:?}"),
        }
        server.stop();
    }

    /// The stop: the listen ends (the next dial finds nobody — the
    /// socket file is unlinked, nobody binds over a stale one), but the
    /// conversations already open keep speaking — the stop flag gates
    /// the listen, not the connections.
    #[test]
    fn the_stop_takes_the_listen_down_and_leaves_running_connections_be() {
        let socket = Socket::named();
        let server =
            serve_with(socket.path.clone(), || String::from("running"), DAEMON_VERSION, own_uid())
                .unwrap();
        let mut client = dial(&socket.path);
        hello(&mut client, roles::Role::ControlPanel, "", 1);
        server.stop();
        assert!(
            UnixStream::connect(&socket.path).is_err(),
            "the listen is ended and the file gone"
        );
        say(&mut client, 8, envelope::Payload::Ping(Ping { nonce: 77 }));
        match hear(&mut client).payload {
            Some(envelope::Payload::Pong(pong)) => assert_eq!(pong.nonce, 77),
            other => panic!("the conversation rides its own EOF: {other:?}"),
        }
    }

    /// The goodbye is theirs or nobody's (session.rs:536; the session's
    /// doc at session.rs:9-10): a client's Goodbye ends the stream with
    /// no goodbye in reply — the client reads the stream's end bare.
    #[test]
    fn a_goodbye_closes_the_stream_and_answers_nothing() {
        let socket = Socket::named();
        let server =
            serve_with(socket.path.clone(), || String::from("running"), DAEMON_VERSION, own_uid())
                .unwrap();
        let mut client = dial(&socket.path);
        hello(&mut client, roles::Role::Engine, "", 1);
        say(
            &mut client,
            0,
            envelope::Payload::Goodbye(Goodbye {
                reason: goodbye::Reason::Shutdown as i32,
                message: "the shim is closing".into(),
            }),
        );
        let error = read_envelope(&mut client).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof, "the end is EOF, not a goodbye");
        server.stop();
    }

    /// A post-grant Verb with a bus rides to the bus and the verdict
    /// rides back as the generic Reply in the asker's id — proto.rs tag
    /// 64's whole little round trip on the door's own grammar.
    #[test]
    fn a_verb_rides_the_bus_and_the_verdict_rides_back() {
        let socket = Socket::named();
        let heard: Arc<Mutex<Vec<(roles::Role, String, String)>>> =
            Arc::new(Mutex::new(Vec::new()));
        let bus: VerbBus = {
            let heard = Arc::clone(&heard);
            Arc::new(move |ask: Ask| {
                heard
                    .lock()
                    .unwrap()
                    .push((ask.role, ask.name.clone(), ask.argument.clone()));
                let _ = ask.settle.send(Ok(String::from("the asker rides")));
            })
        };
        let server = serve_with_verbs(socket.path.clone(), || String::from("running"), bus).unwrap();
        let mut client = dial(&socket.path);
        hello(&mut client, roles::Role::ControlPanel, "", 0);
        say(
            &mut client,
            9,
            envelope::Payload::Verb(Verb { name: String::from("pause"), argument: String::new() }),
        );
        let answer = hear(&mut client);
        assert_eq!(answer.request_id, 9, "the reply pairs the asker's id");
        match answer.payload {
            Some(envelope::Payload::Reply(answer)) => {
                assert_eq!(answer.status, reply::Status::Ok as i32);
                assert_eq!(answer.message, "the asker rides");
            }
            other => panic!("not a reply: {other:?}"),
        }
        // The bus heard the ask whole: who spoke it, and what was asked.
        assert_eq!(
            *heard.lock().unwrap(),
            vec![(roles::Role::ControlPanel, String::from("pause"), String::new())],
        );
        server.stop();
    }

    /// No bus, a Verb: the catch-all names it as every other payload —
    /// the Unsupported wording names the verb's own words and where the
    /// real state machines live, and the connection stays.
    #[test]
    fn a_verb_without_a_bus_gets_the_catch_all() {
        let socket = Socket::named();
        let server =
            serve_with(socket.path.clone(), || String::from("running"), DAEMON_VERSION, own_uid())
                .unwrap();
        let mut client = dial(&socket.path);
        hello(&mut client, roles::Role::ControlPanel, "", 0);
        say(
            &mut client,
            3,
            envelope::Payload::Verb(Verb {
                name: String::from("restart"),
                argument: String::new(),
            }),
        );
        let answer = hear(&mut client);
        match answer.payload {
            Some(envelope::Payload::Reply(answer)) => {
                assert_eq!(answer.status, reply::Status::Unsupported as i32);
                assert!(answer.message.contains("Verb"), "names it: {}", answer.message);
                assert!(
                    answer.message.contains("DaemonService"),
                    "names the state machines: {}",
                    answer.message
                );
            }
            other => panic!("not a reply: {other:?}"),
        }
        // The stays-open rule: the next Ping still answers.
        say(&mut client, 4, envelope::Payload::Ping(Ping { nonce: 7 }));
        let answer = hear(&mut client);
        assert_eq!(answer.request_id, 4, "the door stayed open for the next frame");
        server.stop();
    }

    /// The verb ask's own pins: field 64 — key varint (64 << 3 | 2) = 514
    /// → 0x82 0x04 — then the inner length (7) and the inner Verb: name
    /// "pause" (`0x0A 0x05`), the argument empty and so left off the wire.
    #[test]
    fn the_verbs_wire_bytes_are_pinned() {
        let envelope = Envelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: 0,
            payload: Some(envelope::Payload::Verb(Verb {
                name: "pause".into(),
                argument: String::new(),
            })),
        };
        let mut buf = Vec::new();
        envelope.encode(&mut buf).unwrap();
        assert_eq!(
            buf,
            vec![0x08, 0x01, 0x82, 0x04, 0x07, 0x0A, 0x05, b'p', b'a', b'u', b's', b'e'],
            "the wire must not move; 64 joins at the ladder's end"
        );
        let back = Envelope::decode(buf.as_slice()).unwrap();
        match back.payload {
            Some(envelope::Payload::Verb(verb)) => {
                assert_eq!(verb.name, "pause");
                assert_eq!(verb.argument, "");
            }
            other => panic!("a verb must round-trip as one: {other:?}"),
        }
    }
}
