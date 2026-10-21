//! avo.v1's control channel (proto/avo/v1/control.proto), as Rust
//! hand-transcribed with prost's wire derives — the schema source of truth
//! stays the .proto file; fields are only ever added, never renumbered.
//! Wire bytes must match the Swift/Java peers byte for byte, which the
//! pinned-byte tests at the bottom guard.

use prost::Message;

/// ProtocolVersion.
pub const PROTOCOL_VERSION: u32 = 1;
/// What a current peer still accepts as the other side's minimum.
pub const PROTOCOL_MIN_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// Session

/// Session-opening credentials, both directions. The first message the
/// stream carries in each direction.
#[derive(Clone, PartialEq, Message)]
pub struct Hello {
    /// Highest version the sender speaks (PROTOCOL_VERSION at build time).
    #[prost(uint32, tag = "1")]
    pub protocol_version: u32,
    /// Oldest peer version the sender still accepts.
    #[prost(uint32, tag = "2")]
    pub min_protocol_version: u32,
    /// Human-readable build of the sender.
    #[prost(string, tag = "3")]
    pub software_version: String,
    /// Optional features, e.g. "notifications", "clipboard", "permissions".
    #[prost(string, repeated, tag = "4")]
    pub capabilities: Vec<String>,
    /// Guest only: Android SDK level.
    #[prost(uint32, tag = "5")]
    pub android_sdk: u32,
    /// Guest only: the device profile currently applied.
    #[prost(string, tag = "6")]
    pub device_profile_id: String,
    /// Guest only.
    #[prost(bool, tag = "7")]
    pub rooted: bool,
}

/// Session-closing, either direction; the sender closes after it.
#[derive(Clone, PartialEq, Message)]
pub struct Goodbye {
    #[prost(enumeration = "goodbye::Reason", tag = "1")]
    pub reason: i32,
    #[prost(string, tag = "2")]
    pub message: String,
}

pub mod goodbye {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
    #[repr(i32)]
    pub enum Reason {
        Unspecified = 0,
        Shutdown = 1,
        IncompatibleVersion = 2,
        ProtocolError = 3,
    }
}

/// Liveness probe.
#[derive(Clone, PartialEq, Message)]
pub struct Ping {
    #[prost(uint64, tag = "1")]
    pub nonce: u64,
}

/// Liveness answer.
#[derive(Clone, PartialEq, Message)]
pub struct Pong {
    #[prost(uint64, tag = "1")]
    pub nonce: u64,
}

/// Generic completion for requests that have no typed response.
#[derive(Clone, PartialEq, Message)]
pub struct Reply {
    #[prost(enumeration = "reply::Status", tag = "1")]
    pub status: i32,
    #[prost(string, tag = "2")]
    pub message: String,
}

pub mod reply {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
    #[repr(i32)]
    pub enum Status {
        Ok = 0,
        Failed = 1,
        NotFound = 2,
        InvalidArgument = 3,
        Unsupported = 4,
        PermissionDenied = 5,
    }
}

/// The roles socket's hello dance — the Mac's `hello` rule lives at
/// XPCInterface.swift:12 ("Must be the first call"), the payloads at
/// 267-285; the JSON `Data` they traveled as on the Mac becomes envelopes
/// here, on the same oneof and framing every other Avo wire speaks.
/// Client → daemon on `<runtime>/daemon.sock`: always the first frame.
#[derive(Clone, PartialEq, Message)]
pub struct RoleInvite {
    /// Which of the Mac's `Role` cases the client speaks as (268-271).
    #[prost(enumeration = "roles::Role", tag = "1")]
    pub role: i32,
    /// The App Shim's package (`shim(package:)`, XPCInterface.swift:270);
    /// empty for the Control Panel and the engine.
    #[prost(string, tag = "2")]
    pub package: String,
    /// The Mac's `version` (XPCInterface.swift:275).
    #[prost(string, tag = "3")]
    pub client_version: String,
}

/// Daemon → client: the hello's answer, the Mac's `DaemonHello`
/// (XPCInterface.swift:283-285) with the protocol numbers spelled out;
/// `vm_state` is the daemon body's status string ("running", "paused",
/// "stopped"; bare "unknown" until the body wires its own wording in).
#[derive(Clone, PartialEq, Message)]
pub struct RoleGrant {
    #[prost(string, tag = "1")]
    pub daemon_version: String,
    #[prost(uint32, tag = "2")]
    pub protocol_version: u32,
    /// Oldest protocol version the daemon still accepts (PROTOCOL_MIN_VERSION).
    #[prost(uint32, tag = "3")]
    pub min_supported: u32,
    #[prost(string, tag = "4")]
    pub vm_state: String,
}

/// Client → daemon on the roles socket, after the hello (tag 64): one
/// verb ask, the Mac's XPC verb set flat (XPCInterface.swift:17-127 —
/// the selectors DaemonService.swift's state machines serve). The reply
/// is the generic Reply, in the asker's id. v1 speaks the engine's
/// one-line commands; the rest names where its state machine lives.
#[derive(Clone, PartialEq, Message)]
pub struct Verb {
    /// The Mac's verb selector, flat — the engine's own grammar's first
    /// word ("pause", "resume", "touch"…).
    #[prost(string, tag = "1")]
    pub name: String,
    /// The line's remainder, or empty. Never carries a newline: the
    /// engine's grammar is one line, and the door refuses earlier.
    #[prost(string, tag = "2")]
    pub argument: String,
}

/// The Mac's `ClientHello.Role` (XPCInterface.swift:268-271), on the same
/// numbered-ladder shape `pub mod goodbye` uses.
pub mod roles {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
    #[repr(i32)]
    pub enum Role {
        ControlPanel = 0,
        Shim = 1,
        Engine = 2,
    }
}

// ---------------------------------------------------------------------------
// Displays and tasks
//
// Display ids are allocated by the host (the daemon) and are unique for the
// lifetime of a VM boot. One display hosts exactly one task.

/// Host → guest: starts one app on a display it has never seen.
#[derive(Clone, PartialEq, Message)]
pub struct Launch {
    #[prost(string, tag = "1")]
    pub package: String,
    #[prost(uint32, tag = "2")]
    pub display_id: u32,
    /// Size of the display in physical pixels.
    #[prost(uint32, tag = "3")]
    pub width: u32,
    /// Height, in physical pixels.
    #[prost(uint32, tag = "4")]
    pub height: u32,
    /// The display's density in dpi.
    #[prost(uint32, tag = "5")]
    pub dpi: u32,
    /// Optional explicit component ("com.example/.MainActivity"); the
    /// package's launcher activity when empty.
    #[prost(string, tag = "6")]
    pub component: String,
    /// Optional: start the content intent of this notification on the new
    /// display instead of the launcher activity (notification click).
    #[prost(string, tag = "7")]
    pub notification_key: String,
    /// Optional: VIEW intent data URI (e.g. a file shared via "Open With").
    #[prost(string, tag = "8")]
    pub data_uri: String,
    /// Optional: the intent's MIME type.
    #[prost(string, tag = "9")]
    pub mime_type: String,
    /// Refresh rate of the display in Hz (Android's display rate this boot,
    /// 60 to 120); 0 = 60.
    #[prost(uint32, tag = "10")]
    pub refresh_rate: u32,
}

/// Host → guest: resizes a display's resolution and density.
#[derive(Clone, PartialEq, Message)]
pub struct Resize {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(uint32, tag = "2")]
    pub width: u32,
    #[prost(uint32, tag = "3")]
    pub height: u32,
    /// 0 keeps the current density.
    #[prost(uint32, tag = "4")]
    pub dpi: u32,
}

/// Host → guest: closes a display and its task.
#[derive(Clone, PartialEq, Message)]
pub struct Close {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
}

/// Host → guest: a rate cap change without a restart. display_id 0 applies
/// it to every display and becomes the default for new ones.
#[derive(Clone, PartialEq, Message)]
pub struct SetRefreshRate {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(uint32, tag = "2")]
    pub fps: u32,
}

/// Host → guest: a window minimised or fully occluded — the guest may stop
/// rendering the display to save GPU time.
#[derive(Clone, PartialEq, Message)]
pub struct SetDisplayVisibility {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(bool, tag = "2")]
    pub visible: bool,
}

/// Host → guest: the display's window became the host's key window; its app
/// takes Android's input focus, as a phone's one app has it. Only the GPU
/// engine needs it; displays with their own focus already have it.
#[derive(Clone, PartialEq, Message)]
pub struct FocusDisplay {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
}

/// Guest → host: a task rendered its first frame on its display.
#[derive(Clone, PartialEq, Message)]
pub struct DisplayReady {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(string, tag = "2")]
    pub package: String,
}

/// Guest → host: the task is gone.
#[derive(Clone, PartialEq, Message)]
pub struct TaskClosed {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(string, tag = "2")]
    pub package: String,
}

/// Guest → host: an app came to the front on Android's own screen, which no
/// window shows (started by adb, another app or the system). The host opens
/// a window for the package; its Launch brings the running task there.
#[derive(Clone, PartialEq, Message)]
pub struct TaskStarted {
    #[prost(string, tag = "1")]
    pub package: String,
    #[prost(int32, tag = "2")]
    pub task_id: i32,
}

/// Guest → host: a display's top activity changed (title, package) so its
/// window can update its title and dock badge.
#[derive(Clone, PartialEq, Message)]
pub struct DisplayContentChanged {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(string, tag = "2")]
    pub package: String,
    #[prost(string, tag = "3")]
    pub title: String,
}

/// Host → guest: the display should rotate.
#[derive(Clone, PartialEq, Message)]
pub struct OrientationRequest {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(enumeration = "Orientation", tag = "2")]
    pub orientation: i32,
}

/// Orientation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum Orientation {
    Unspecified = 0,
    Portrait = 1,
    Landscape = 2,
    ReversePortrait = 3,
    ReverseLandscape = 4,
}

// ---------------------------------------------------------------------------
// Packages

/// Adaptive icon layers rendered at 432x432 px (108 dp at xxxhdpi), the
/// visible safe zone being the centred 288x288 px circle/squircle.
#[derive(Clone, PartialEq, Message)]
pub struct AdaptiveIcon {
    #[prost(bytes = "vec", tag = "1")]
    pub background_png: Vec<u8>,
    #[prost(bytes = "vec", tag = "2")]
    pub foreground_png: Vec<u8>,
    #[prost(bytes = "vec", tag = "3")]
    pub monochrome_png: Vec<u8>,
}

/// One installed app.
#[derive(Clone, PartialEq, Message)]
pub struct AppInfo {
    #[prost(string, tag = "1")]
    pub package: String,
    #[prost(string, tag = "2")]
    pub label: String,
    #[prost(string, tag = "3")]
    pub version_name: String,
    #[prost(int64, tag = "4")]
    pub version_code: i64,
    /// Flattened launcher icon (PNG, 192x192 or larger).
    #[prost(bytes = "vec", tag = "5")]
    pub icon_png: Vec<u8>,
    /// Present when the launcher icon is an AdaptiveIconDrawable.
    #[prost(message, optional, tag = "6")]
    pub adaptive_icon: Option<AdaptiveIcon>,
    /// APK + data + cache, in bytes, when known.
    #[prost(int64, tag = "7")]
    pub size_bytes: i64,
    #[prost(int64, tag = "8")]
    pub first_install_time_ms: i64,
    #[prost(int64, tag = "9")]
    pub last_update_time_ms: i64,
    #[prost(bool, tag = "10")]
    pub system_app: bool,
    /// Has a launcher activity (only launchable apps get a window).
    #[prost(bool, tag = "11")]
    pub launchable: bool,
    #[prost(string, tag = "12")]
    pub installer_package: String,
}

/// Guest → host: an app arrived (install finished), or replaced itself.
#[derive(Clone, PartialEq, Message)]
pub struct AppInstalled {
    #[prost(message, optional, tag = "1")]
    pub app: Option<AppInfo>,
    /// True when this replaces an existing install (update).
    #[prost(bool, tag = "2")]
    pub replacing: bool,
}

/// Guest → host: an app is gone (or is being replaced, by an AppInstalled).
#[derive(Clone, PartialEq, Message)]
pub struct AppRemoved {
    #[prost(string, tag = "1")]
    pub package: String,
    /// True when the removal is part of an update (an AppInstalled follows).
    #[prost(bool, tag = "2")]
    pub replacing: bool,
}

/// Host → guest
#[derive(Clone, PartialEq, Message)]
pub struct ListApps {
    /// Include icons (large); the host omits them when it already has them.
    #[prost(bool, tag = "1")]
    pub include_icons: bool,
    #[prost(bool, tag = "2")]
    pub include_system: bool,
}

/// Guest → host: the answer to ListApps.
#[derive(Clone, PartialEq, Message)]
pub struct AppList {
    #[prost(message, repeated, tag = "1")]
    pub apps: Vec<AppInfo>,
}

/// Host → guest: installs an APK that already exists on the guest
/// filesystem (pushed over the ADB channel). Split APK sets use
/// `pm install-create/-write/-commit` over ADB instead; docs/protocol.md.
#[derive(Clone, PartialEq, Message)]
pub struct Install {
    #[prost(string, tag = "1")]
    pub path: String,
    #[prost(string, repeated, tag = "2")]
    pub split_paths: Vec<String>,
}

/// Host → guest
#[derive(Clone, PartialEq, Message)]
pub struct Uninstall {
    #[prost(string, tag = "1")]
    pub package: String,
}

/// Host → guest
#[derive(Clone, PartialEq, Message)]
pub struct ForceStop {
    #[prost(string, tag = "1")]
    pub package: String,
}

/// Host → guest: "clear data" — removes the app's data and cache.
#[derive(Clone, PartialEq, Message)]
pub struct DeleteAppData {
    #[prost(string, tag = "1")]
    pub package: String,
}

/// Host → guest: asks what permissions a package holds.
#[derive(Clone, PartialEq, Message)]
pub struct GetPermissions {
    #[prost(string, tag = "1")]
    pub package: String,
}

/// Guest → host: the answer to GetPermissions.
#[derive(Clone, PartialEq, Message)]
pub struct PermissionList {
    #[prost(string, tag = "1")]
    pub package: String,
    #[prost(message, repeated, tag = "2")]
    pub permissions: Vec<Permission>,
}

/// Host → guest: flips one of a package's permissions. The typed response
/// is a `Reply`.
#[derive(Clone, PartialEq, Message)]
pub struct SetPermission {
    #[prost(string, tag = "1")]
    pub package: String,
    #[prost(string, tag = "2")]
    pub permission: String,
    #[prost(bool, tag = "3")]
    pub granted: bool,
}

/// Host → guest
#[derive(Clone, PartialEq, Message)]
pub struct Permission {
    #[prost(string, tag = "1")]
    pub name: String,
    #[prost(string, tag = "2")]
    pub label: String,
    #[prost(bool, tag = "3")]
    pub granted: bool,
    /// Dangerous (runtime) permissions can be toggled by the host.
    #[prost(bool, tag = "4")]
    pub runtime: bool,
}

/// Host → guest: files already copied to the guest (normally
/// /sdcard/Download) are offered to the app on `display_id` through
/// ACTION_SEND / ACTION_SEND_MULTIPLE.
#[derive(Clone, PartialEq, Message)]
pub struct ShareFiles {
    #[prost(uint32, tag = "1")]
    pub display_id: u32,
    #[prost(string, repeated, tag = "2")]
    pub paths: Vec<String>,
    #[prost(string, repeated, tag = "3")]
    pub mime_types: Vec<String>,
}

// ---------------------------------------------------------------------------
// Notifications and clipboard

/// Guest → host: a notification the host can present as its own.
#[derive(Clone, PartialEq, Message)]
pub struct Notification {
    #[prost(string, tag = "1")]
    pub package: String,
    /// StatusBarNotification key; stable for updates of the same.
    #[prost(string, tag = "2")]
    pub key: String,
    #[prost(string, tag = "3")]
    pub title: String,
    #[prost(string, tag = "4")]
    pub body: String,
    #[prost(int64, tag = "5")]
    pub posted_at_ms: i64,
    #[prost(bytes = "vec", tag = "6")]
    pub large_icon_png: Vec<u8>,
    #[prost(string, tag = "7")]
    pub group: String,
    #[prost(bool, tag = "8")]
    pub ongoing: bool,
    #[prost(bool, tag = "9")]
    pub silent: bool,
}

/// Guest → host: a notification's dismissal.
#[derive(Clone, PartialEq, Message)]
pub struct NotificationRemoved {
    #[prost(string, tag = "1")]
    pub key: String,
}

/// Host → guest: opens a notification's content intent.
#[derive(Clone, PartialEq, Message)]
pub struct OpenNotification {
    #[prost(string, tag = "1")]
    pub key: String,
    /// Display to start the content intent on (0: let the guest decide).
    #[prost(uint32, tag = "2")]
    pub display_id: u32,
}

/// Host → guest: clears one notification.
#[derive(Clone, PartialEq, Message)]
pub struct DismissNotification {
    #[prost(string, tag = "1")]
    pub key: String,
}

/// Host → guest: replaces the shared clipboard.
#[derive(Clone, PartialEq, Message)]
pub struct SetClipboard {
    #[prost(string, tag = "1")]
    pub text: String,
}

/// Guest → host: the clipboard changed on Android's side.
#[derive(Clone, PartialEq, Message)]
pub struct ClipboardChanged {
    #[prost(string, tag = "1")]
    pub text: String,
}

/// The `Envelope`'s oneof payload, `envelope::Payload`: field tags are the
/// protocol's and are only ever added.
pub mod envelope {
    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        Hello(super::Hello),
        #[prost(message, tag = "11")]
        Goodbye(super::Goodbye),
        #[prost(message, tag = "12")]
        Ping(super::Ping),
        #[prost(message, tag = "13")]
        Pong(super::Pong),
        #[prost(message, tag = "14")]
        Reply(super::Reply),

        // Host -> guest.
        #[prost(message, tag = "20")]
        Launch(super::Launch),
        #[prost(message, tag = "21")]
        Resize(super::Resize),
        #[prost(message, tag = "22")]
        Close(super::Close),
        #[prost(message, tag = "23")]
        Install(super::Install),
        #[prost(message, tag = "24")]
        Uninstall(super::Uninstall),
        #[prost(message, tag = "25")]
        SetClipboard(super::SetClipboard),
        #[prost(message, tag = "26")]
        ListApps(super::ListApps),
        #[prost(message, tag = "27")]
        ForceStop(super::ForceStop),
        #[prost(message, tag = "28")]
        DeleteAppData(super::DeleteAppData),
        #[prost(message, tag = "29")]
        GetPermissions(super::GetPermissions),
        #[prost(message, tag = "30")]
        SetPermission(super::SetPermission),
        #[prost(message, tag = "31")]
        ShareFiles(super::ShareFiles),
        #[prost(message, tag = "32")]
        SetDisplayVisibility(super::SetDisplayVisibility),
        #[prost(message, tag = "33")]
        OpenNotification(super::OpenNotification),
        #[prost(message, tag = "34")]
        DismissNotification(super::DismissNotification),
        #[prost(message, tag = "35")]
        SetRefreshRate(super::SetRefreshRate),
        #[prost(message, tag = "36")]
        FocusDisplay(super::FocusDisplay),

        // Guest -> host.
        #[prost(message, tag = "50")]
        AppInstalled(super::AppInstalled),
        #[prost(message, tag = "51")]
        AppRemoved(super::AppRemoved),
        #[prost(message, tag = "52")]
        DisplayReady(super::DisplayReady),
        #[prost(message, tag = "53")]
        TaskClosed(super::TaskClosed),
        #[prost(message, tag = "54")]
        Notification(super::Notification),
        #[prost(message, tag = "55")]
        NotificationRemoved(super::NotificationRemoved),
        #[prost(message, tag = "56")]
        ClipboardChanged(super::ClipboardChanged),
        #[prost(message, tag = "57")]
        OrientationRequest(super::OrientationRequest),
        #[prost(message, tag = "58")]
        AppList(super::AppList),
        #[prost(message, tag = "59")]
        PermissionList(super::PermissionList),
        #[prost(message, tag = "60")]
        DisplayContentChanged(super::DisplayContentChanged),
        #[prost(message, tag = "61")]
        TaskStarted(super::TaskStarted),

        // The roles socket: the Mac's XPC hello dance, drawn out of the
        // JSON `Data` payloads the @objc surface carried
        // (XPCInterface.swift:12, 267-285).
        #[prost(message, tag = "62")]
        RoleInvite(super::RoleInvite),
        #[prost(message, tag = "63")]
        RoleGrant(super::RoleGrant),
        #[prost(message, tag = "64")]
        Verb(super::Verb),
    }
}

/// Everything on the wire is one of these: the sender's protocol version,
/// the request id it expects its response to carry (0 for the unasked ones
/// the guest sends), and the payload.
#[derive(Clone, PartialEq, Message)]
pub struct Envelope {
    #[prost(uint32, tag = "1")]
    pub protocol_version: u32,
    /// Non-zero when the sender expects a reply carrying the same id; ids
    /// are the requester's and only need to be unique per connection and
    /// direction.
    #[prost(uint64, tag = "2")]
    pub request_id: u64,
    #[prost(oneof = "envelope::Payload", tags = "10, 11, 12, 13, 14, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64")]
    pub payload: Option<envelope::Payload>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pinned bytes: what the Swift and Java peers put on the wire for
    /// this envelope must be exactly this, forever.
    #[test]
    fn hello_bytes_are_pinned() {
        let mut buf = Vec::new();
        Envelope {
            protocol_version: 1,
            request_id: 4,
            payload: Some(envelope::Payload::Hello(Hello {
                protocol_version: 1,
                min_protocol_version: 1,
                software_version: "avod 0".into(),
                ..Default::default()
            })),
        }
        .encode(&mut buf)
        .unwrap();
        // Envelope: protocol_version (0x08 0x01), request_id (0x10 0x04),
        // the oneof's field 10 wire type 2 (0x52) and its 12 bytes (0x0C);
        // Hello: its own 1 and 2 (0x08 0x01, 0x10 0x01) and "avod 0"
        // (0x1A 0x06).
        let mut expect = vec![0x08, 0x01, 0x10, 0x04, 0x52, 0x0C, 0x08, 0x01, 0x10, 0x01, 0x1A, 0x06];
        expect.extend_from_slice(b"avod 0");
        assert_eq!(buf, expect, "the wire must not move; tags and order are the protocol's");
        let back = Envelope::decode(buf.as_slice()).unwrap();
        assert_eq!(back.request_id, 4);
        assert!(matches!(back.payload, Some(envelope::Payload::Hello(_))));
    }

    /// The guest → host direction's tags are pinned the same way.
    #[test]
    fn the_guests_direction_keeps_its_tags() {
        let mut buf = Vec::new();
        Envelope {
            protocol_version: 1,
            request_id: 0,
            payload: Some(envelope::Payload::TaskStarted(TaskStarted {
                package: "com.avo".into(),
                task_id: 3,
            })),
        }
        .encode(&mut buf)
        .unwrap();
        // The oneof's field 61 wire type 2 (0xEA 0x03) and its 11 bytes
        // (0x0B); TaskStarted: "com.avo" (0x0A 0x07) and task_id 3 (0x10 0x03).
        assert_eq!(
            buf,
            vec![
                0x08, 0x01, 0xEA, 0x03, 0x0B, 0x0A, 0x07, b'c', b'o', b'm', b'.', b'a', b'v', b'o',
                0x10, 0x03
            ]
        );
        let back = Envelope::decode(buf.as_slice()).unwrap();
        assert!(matches!(back.payload, Some(envelope::Payload::TaskStarted(_))));
    }

    #[test]
    fn an_envelope_roundtrips_through_the_wire() {
        let envelope = Envelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: 9,
            payload: Some(envelope::Payload::Notification(Notification {
                package: "com.avo.notes".into(),
                key: "k".into(),
                body: "hi".into(),
                posted_at_ms: 1729,
                ongoing: true,
                ..Default::default()
            })),
        };
        let mut buf = Vec::new();
        envelope.encode(&mut buf).unwrap();
        assert_eq!(Envelope::decode(buf.as_slice()).unwrap(), envelope);
    }

    /// Fields a newer protocol version adds decode and are ignored — the
    /// contract that lets versions step past each other.
    #[test]
    fn a_later_versions_fields_decode_and_are_ignored() {
        // A Hello with a field 99 this file never heard of (varint 1).
        let wire = [0x08u8, 0x01, 0x10, 0x01, 0x98, 0x06, 0x01];
        let hello = Hello::decode(wire.as_slice()).unwrap();
        assert_eq!(hello.protocol_version, 1);
        assert_eq!(hello.min_protocol_version, 1);
        assert_eq!(hello.software_version, "");
    }

    #[test]
    fn the_version_consts_match_the_first_protocol() {
        assert_eq!(PROTOCOL_VERSION, 1);
        assert_eq!(PROTOCOL_MIN_VERSION, 1);
    }
}
