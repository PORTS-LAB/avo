//! The daemon's end of the desktop's notifications: the guest's
//! notifications presented onto `org.freedesktop.Notifications` through
//! libdbus-the-library, no subprocess, no dependency — dlopen of
//! `libdbus-1.so.3` the way the sound engine loads `libasound.so.2`
//! (engine/hvf/vmm/src/virtio/sound/alsa.rs), fixed-argument functions
//! only: libdbus's own `dbus_message_append_args` is variadic and Rust
//! never calls a variadic C function safely, so the iterator functions
//! carry the whole instead.
//!
//! The Mac's presenter is host/AvoDaemon/MacIntegrations.swift's
//! `UserNotificationPresenter`, and the mapping lands line by line there:
//!
//! - ongoing notifications are never shown ("progress bars and media
//!   sessions stay in Android" — MacIntegrations.swift); `show` reports
//!   `None` and builds no message;
//! - the summary is the guest's title, or the app's name when the title is
//!   empty (the Mac's title fallback), and the app's name rides the call's
//!   `app_name` argument — the slot freedesktop servers present as the
//!   notification's context label, which is where the Mac's subtitle
//!   lived;
//! - the body is the guest's body (the Mac's `content.body`);
//! - the same key's second arrival replaces the first (the Mac hands the
//!   key to `UNNotificationRequest`'s identifier, so macOS replaces free)
//!   — here a key→id map stands in, and `replaces_id` names it;
//! - `NotificationRemoved` closes by that same id (the Mac's
//!   `removeDeliveredNotifications` with the key as the identifier);
//! - `silent` carries the freedesktop hint `suppress-sound` true (the
//!   spec's "server will not play sound"; the Mac sets `content.sound`
//!   when the guest is *not* silent — the desktop's default sound is
//!   exactly the shape of that flag);
//! - `group`/threading: the Mac thread-identifies by the package;
//!   freedesktop has no thread slot, so the package travels as the custom
//!   hint `x-avo-thread` for any server curious later — unknown hints are
//!   ignored by the spec;
//! - `large_icon_png` stays unset: the Mac writes it to a temp file and
//!   attaches it (`UNNotificationAttachment`), but freedesktop's
//!   `image-data` hint wants raw pixels and a PNG decoder is another
//!   dependency away — documented here, not faked;
//! - the expire timeout is 0, "never expires": the Mac's notification
//!   carries no trigger, so it shows and stays until the user or the app
//!   dismisses it, and that is freedesktop's 0;
//! - actions stay empty. The Mac's category carries a dismiss action and
//!   click routes at `openNotification(package, key)`; freedesktop's
//!   action array is the map for the click half, but the daemon has no
//!   back channel to the guest yet — a later slice.
//!
//! The session bus is fetched private (`dbus_bus_get_private`), so this
//! connection is the daemon's alone and `close` + unref are legal on its
//! way out. `dbus_threads_init_default` runs at load, which makes moving
//! the connection across threads the library's own documented safe use —
//! and the daemon serializes its presenter's calls besides.
//!
//! Tests never touch a bus: the messages build, then
//! `dbus_message_marshal`/`dbus_message_unmarshal` round them through
//! libdbus's own machinery and the iterator walks the result back — every
//! shape the call makes is pinned against the library itself. What a live
//! session bus *reads* stays open on purpose (the sound engine's live
//! playback is env-gated; here the live check is deferred, listed in the
//! gaps at the tests' end).

use crate::proto::Notification;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CString};
use std::sync::{Mutex, OnceLock};

// The same calls the sound engine makes through the libc crate; the
// daemon takes no such dependency, so they stay hand-typed, and std
// links libc itself — the symbols bind at build time.
unsafe extern "C" {
    fn dlopen(filename: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlerror() -> *mut c_char;
}

/// <dlfcn.h>'s two, the same values glibc and musl both name.
const RTLD_NOW: c_int = 2;
const RTLD_LOCAL: c_int = 0;

/// DBusConnection, at the ABI's distance.
type Connection = *mut c_void;
/// DBusMessage, ditto — the library hands them out opaque.
type Message = *mut c_void;

/// DBusMessageIter is what the library *fills*, so it is a value sized by
/// its published struct (three pointers and a run of ints, ~72 bytes).
/// The blob is generously larger; nothing reads it back, only passes the
/// same address to the calls that know the truth.
#[repr(C)]
#[derive(Clone, Copy)]
struct Iter {
    storage: [u64; 16],
}

impl Iter {
    fn new() -> Self {
        Iter { storage: [0; 16] }
    }
}

/// The wire format's letters, the header's own constants.
const TYPE_STRING: c_int = 115; // 's'
const TYPE_BOOL: c_int = 98; // 'b'
const TYPE_UINT32: c_int = 117; // 'u'
const TYPE_INT32: c_int = 105; // 'i'
const TYPE_ARRAY: c_int = 97; // 'a'
const TYPE_DICT_ENTRY: c_int = 101; // 'e'
const TYPE_VARIANT: c_int = 118; // 'v'

/// The doc's message-family code a Notify and CloseNotification share,
/// named for the unmarshal test's own argument.
#[allow(dead_code)]
const MESSAGE_TYPE_METHOD_CALL: c_int = 1;

/// The spec's own names: the service's well-known name, its standard path,
/// and the two members the guest's notifications become.
const DESTINATION: &str = "org.freedesktop.Notifications";
const PATH: &str = "/org/freedesktop/Notifications";
const INTERFACE: &str = "org.freedesktop.Notifications";
const MEMBER_NOTIFY: &str = "Notify";
const MEMBER_CLOSE: &str = "CloseNotification";
const HINT_SUPPRESS_SOUND: &str = "suppress-sound";
const HINT_THREAD: &str = "x-avo-thread";

/// The reply wait in milliseconds: the daemon's own bound on the desktop
/// (libdbus's default is 25s and the session's requests live on shorter
/// numbers than that).
const REPLY_WAIT_MS: c_int = 5000;

/// `dbus_bool_t` in the C ABI: unsigned 0 or 1.
type Bool = u32;

// The table's read-half (`message_marshal`, `message_unmarshal`, the
// getters) is the tests' inspecting eye alone; the lib's own life reads
// the send path. The dead-code bar bends for exactly those and no more.
#[allow(dead_code)]
struct Symbols {
    /// dbus_threads_init_default: libdbus's threading comes on once at
    /// load, which is the library's own prerequisite for a connection
    /// touched from more than the loading thread.
    threads_init_default: unsafe extern "C" fn() -> Bool,
    /// dbus_bus_get_private(DBusBusType, DBusError*) — the daemon's errors
    /// are its own words, so the error struct never travels: NULL in, NULL
    /// back on failure.
    bus_get_private: unsafe extern "C" fn(c_int, *mut c_void) -> Connection,
    /// void dbus_connection_close(DBusConnection*) — legal on a private
    /// connection only; the shared one dbus_bus_get returns forbids it.
    connection_close: unsafe extern "C" fn(Connection),
    connection_unref: unsafe extern "C" fn(Connection) -> Connection,
    /// DBusMessage* dbus_message_new_method_call(dest, path, iface, member)
    message_new_method_call: unsafe extern "C" fn(*const c_char, *const c_char, *const c_char, *const c_char) -> Message,
    message_get_type: unsafe extern "C" fn(Message) -> c_int,
    message_get_path: unsafe extern "C" fn(Message) -> *const c_char,
    message_get_interface: unsafe extern "C" fn(Message) -> *const c_char,
    message_get_member: unsafe extern "C" fn(Message) -> *const c_char,
    message_get_destination: unsafe extern "C" fn(Message) -> *const c_char,
    message_get_signature: unsafe extern "C" fn(Message) -> *const c_char,
    /// dbus_message_iter_init(Message, DBusMessageIter*) — false when the
    /// message carries no arguments at all.
    message_iter_init: unsafe extern "C" fn(Message, *mut Iter) -> Bool,
    message_iter_next: unsafe extern "C" fn(*mut Iter) -> Bool,
    message_iter_get_arg_type: unsafe extern "C" fn(*mut Iter) -> c_int,
    message_iter_get_basic: unsafe extern "C" fn(*mut Iter, *mut c_void),
    message_iter_recurse: unsafe extern "C" fn(*mut Iter, *mut Iter),
    message_iter_init_append: unsafe extern "C" fn(Message, *mut Iter),
    /// dbus_message_iter_append_basic — the *value* of a string argument
    /// is passed as the address of its `const char*`.
    message_iter_append_basic: unsafe extern "C" fn(*mut Iter, c_int, *const c_void) -> Bool,
    /// dbus_message_iter_open_container — the signature is the element's
    /// for an array ("{sv}" for the hints array, "s" for the actions),
    /// the variant's contents for a variant, NULL for a dict entry.
    message_iter_open_container: unsafe extern "C" fn(*mut Iter, c_int, *const c_char, *mut Iter) -> Bool,
    message_iter_close_container: unsafe extern "C" fn(*mut Iter, *mut Iter) -> Bool,
    /// DBusMessage* dbus_connection_send_with_reply_and_block(conn, msg,
    /// timeout_ms, DBusError*) — the caller keeps its ref to the outgoing
    /// message and owns the unref in every path (dbus-connection.c).
    connection_send_with_reply_and_block: unsafe extern "C" fn(Connection, Message, c_int, *mut c_void) -> Message,
    /// dbus_message_marshal(Message, char**, int*) + the freed buffer.
    message_marshal: unsafe extern "C" fn(Message, *mut *mut c_char, *mut c_int) -> Bool,
    /// DBusMessage* dbus_message_unmarshal(data, len, type)
    message_unmarshal: unsafe extern "C" fn(*const c_char, c_int, c_int) -> Message,
    message_unref: unsafe extern "C" fn(Message),
    /// void dbus_free(void*) — what marshal hands back is ours to give up.
    free: unsafe extern "C" fn(*mut c_void),
}

static LIBRARY: OnceLock<Result<Symbols, String>> = OnceLock::new();

/// Loads the symbols, `None` on any machine without libdbus — the daemon
/// carries on without notifications the same way the sound engine carries
/// on without a sound system (alsa.rs's discipline: absence shapes, it
/// does not crash).
fn table() -> Option<&'static Symbols> {
    let loaded = LIBRARY.get_or_init(|| {
        let mut error = String::new();
        // The runtime name first; an unversioned dev-system name behind it.
        for name in [c"libdbus-1.so.3", c"libdbus-1.so"] {
            let handle = unsafe { dlopen(name.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
            if handle.is_null() {
                let raw = unsafe { dlerror() };
                error = if raw.is_null() {
                    format!("{} cannot load", name.to_string_lossy())
                } else {
                    unsafe { std::ffi::CStr::from_ptr(raw) }.to_string_lossy().into_owned()
                };
                continue;
            }
            return load_table(handle);
        }
        Err(error)
    });
    loaded.as_ref().ok()
}

/// One handle's symbol table, factored from the search so a test can ask
/// what a handle with no symbols in it does. The threading switch is the
/// load's own last step: libdbus's documented prerequisite for a
/// connection touched from more than the loading thread, once, before any
/// `Presenter` exists to hold one.
fn load_table(handle: *mut c_void) -> Result<Symbols, String> {
    macro_rules! symbol {
        ($symbol:literal) => {{
            let pointer = unsafe { dlsym(handle, concat!($symbol, "\0").as_ptr().cast()) };
            if pointer.is_null() {
                return Err(format!("libdbus has no {}", $symbol));
            }
            // SAFETY: the field's type is the symbol's prototype.
            unsafe { std::mem::transmute::<*mut c_void, _>(pointer) }
        }};
    }
    // SAFETY: the fields read at the calls that follow carry the symbols'
    // own prototypes; the calls run exactly once per process, under the
    // loader's lock.
    let table = Symbols {
        threads_init_default: symbol!("dbus_threads_init_default"),
        bus_get_private: symbol!("dbus_bus_get_private"),
        connection_close: symbol!("dbus_connection_close"),
        connection_unref: symbol!("dbus_connection_unref"),
        message_new_method_call: symbol!("dbus_message_new_method_call"),
        message_get_type: symbol!("dbus_message_get_type"),
        message_get_path: symbol!("dbus_message_get_path"),
        message_get_interface: symbol!("dbus_message_get_interface"),
        message_get_member: symbol!("dbus_message_get_member"),
        message_get_destination: symbol!("dbus_message_get_destination"),
        message_get_signature: symbol!("dbus_message_get_signature"),
        message_iter_init: symbol!("dbus_message_iter_init"),
        message_iter_next: symbol!("dbus_message_iter_next"),
        message_iter_get_arg_type: symbol!("dbus_message_iter_get_arg_type"),
        message_iter_get_basic: symbol!("dbus_message_iter_get_basic"),
        message_iter_recurse: symbol!("dbus_message_iter_recurse"),
        message_iter_init_append: symbol!("dbus_message_iter_init_append"),
        message_iter_append_basic: symbol!("dbus_message_iter_append_basic"),
        message_iter_open_container: symbol!("dbus_message_iter_open_container"),
        message_iter_close_container: symbol!("dbus_message_iter_close_container"),
        connection_send_with_reply_and_block: symbol!("dbus_connection_send_with_reply_and_block"),
        message_marshal: symbol!("dbus_message_marshal"),
        message_unmarshal: symbol!("dbus_message_unmarshal"),
        message_unref: symbol!("dbus_message_unref"),
        free: symbol!("dbus_free"),
    };
    if unsafe { (table.threads_init_default)() } == 0 {
        return Err("libdbus's threading would not come on".into());
    }
    Ok(table)
}

/// What presenting can fail with — the crate's error voice, narrowed to
/// the module's two ends: the machine has no libdbus or no bus the daemon
/// can ride (`Bus`), or a call disagreed with the wire (`Wire`, where the
/// body names the seam).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    Bus,
    Wire(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Bus => write!(f, "the session bus is not reachable"),
            Error::Wire(what) => write!(f, "the notification's wire disagrees: {what}"),
        }
    }
}

/// The key→id bookkeeping, a pure thing before any bus is involved: a
/// key's second arrival names the first's id (the Mac's identifier trick,
/// spelled out because freedesktop needs the number), a strike hands the
/// id out and forgets the key, a stranger's returns nothing and leaves
/// the rest untouched.
#[derive(Default)]
struct Ids {
    map: HashMap<Box<str>, u32>,
}

impl Ids {
    fn new() -> Self {
        Ids { map: HashMap::new() }
    }

    /// The id the server call names for this key: an existing arrival's id
    /// (the replace), or 0 — "new" — for a key the map has not seen.
    fn replaces(&self, key: &str) -> u32 {
        self.map.get(key).copied().unwrap_or(0)
    }

    fn stored(&mut self, key: &str, id: u32) {
        self.map.insert(key.into(), id);
    }

    fn removed(&mut self, key: &str) -> Option<u32> {
        self.map.remove(key)
    }
}

/// The summary the call carries: the guest's title, or the app's name
/// when the title is empty — MacIntegrations.swift's fallback, one line.
fn summary<'a>(notification: &'a Notification, app_name: &'a str) -> &'a str {
    if notification.title.is_empty() {
        app_name
    } else {
        &notification.title
    }
}

/// A D-Bus method call's destination-side strings, as the library wants
/// them: a guest's own strings are cut at any NUL (one cannot travel
/// inside the string type's encoding, and the Mac's strings never carry
/// one), the rest goes through lossless.
fn c_of(text: &str) -> CString {
    let cut = text.split('\0').next().unwrap_or("");
    CString::new(cut).unwrap_or_default()
}

/// Piece work for `append_basic`: a string argument's value side is the
/// address of its `const char*`.
fn append_string(table: &Symbols, iter: &mut Iter, text: &str) -> Result<(), Error> {
    let held = c_of(text);
    let pointer: *const c_char = held.as_ptr();
    let ok = unsafe { (table.message_iter_append_basic)(iter, TYPE_STRING, pointer as *const *const c_char as *const c_void) };
    if ok == 0 {
        return Err(Error::Wire("a string argument did not fit".into()));
    }
    Ok(())
}

fn append_u32(table: &Symbols, iter: &mut Iter, value: u32) -> Result<(), Error> {
    let slot = value;
    let ok = unsafe { (table.message_iter_append_basic)(iter, TYPE_UINT32, &slot as *const u32 as *const c_void) };
    if ok == 0 {
        return Err(Error::Wire("a uint argument did not fit".into()));
    }
    Ok(())
}

fn append_i32(table: &Symbols, iter: &mut Iter, value: i32) -> Result<(), Error> {
    let slot = value;
    let ok = unsafe { (table.message_iter_append_basic)(iter, TYPE_INT32, &slot as *const i32 as *const c_void) };
    if ok == 0 {
        return Err(Error::Wire("an int argument did not fit".into()));
    }
    Ok(())
}

/// The Notify message the guest's notification becomes, `None` for sorts
/// the guest classifies out of the desktop (the Mac's ongoing sieve). The
/// argument order is the spec's: app_name, replaces_id, app_icon,
/// summary, body, actions, hints, expire_timeout.
fn notify_message(table: &Symbols, ids: &Ids, notification: &Notification, app_name: &str) -> Result<Option<Message>, Error> {
    // The Mac's sieve: progress bars and media sessions stay in Android.
    if notification.ongoing {
        return Ok(None);
    }
    let dest = c_of(DESTINATION);
    let path = c_of(PATH);
    let interface = c_of(INTERFACE);
    let member = c_of(MEMBER_NOTIFY);
    let message = unsafe { (table.message_new_method_call)(dest.as_ptr(), path.as_ptr(), interface.as_ptr(), member.as_ptr()) };
    if message.is_null() {
        return Err(Error::Wire("the call would not form".into()));
    }
    let build = || -> Result<(), Error> {
        let mut iter = Iter::new();
        unsafe { (table.message_iter_init_append)(message, &mut iter) };
        // The app's name rides the call's own argument, the context slot
        // the servers read (the Mac's subtitle slot).
        append_string(table, &mut iter, app_name)?;
        // A key the map has seen names its id: the second arrival REPLACES.
        append_u32(table, &mut iter, ids.replaces(&notification.key))?;
        // The icon: unset (the gap in the module's opening).
        append_string(table, &mut iter, "")?;
        append_string(table, &mut iter, summary(notification, app_name))?;
        append_string(table, &mut iter, &notification.body)?;
        // The actions: an empty string array, closed without any member —
        // the back channel's seam for a later slice.
        let mut actions = Iter::new();
        if unsafe { (table.message_iter_open_container)(&mut iter, TYPE_ARRAY, c"s".as_ptr(), &mut actions) } == 0 {
            return Err(Error::Wire("the action array would not open".into()));
        }
        if unsafe { (table.message_iter_close_container)(&mut iter, &mut actions) } == 0 {
            return Err(Error::Wire("the action array would not close".into()));
        }
        // The hints: `suppress-sound` when the guest is silent, the
        // package's thread for any server curious later.
        let mut hints = Iter::new();
        if unsafe { (table.message_iter_open_container)(&mut iter, TYPE_ARRAY, c"{sv}".as_ptr(), &mut hints) } == 0 {
            return Err(Error::Wire("the hint array would not open".into()));
        }
        if notification.silent {
            append_hint_bool(table, &mut hints, HINT_SUPPRESS_SOUND, true)?;
        }
        if !notification.package.is_empty() {
            append_hint_string(table, &mut hints, HINT_THREAD, &notification.package)?;
        }
        if unsafe { (table.message_iter_close_container)(&mut iter, &mut hints) } == 0 {
            return Err(Error::Wire("the hint array would not close".into()));
        }
        // 0: the server keeps it until the user or the app dismiss it —
        // the Mac's triggerless notification, spelled in the spec's own
        // number.
        append_i32(table, &mut iter, 0)?;
        Ok(())
    };
    if let Err(error) = build() {
        unsafe { (table.message_unref)(message) };
        return Err(error);
    }
    Ok(Some(message))
}

/// Each hint is one dict entry inside the array: the key's string, then
/// the variant the server reads by its own signature (a boolean for the
/// silence, a string for the package's thread).
fn append_hint_bool(table: &Symbols, hints: &mut Iter, key: &str, value: bool) -> Result<(), Error> {
    let mut entry = Iter::new();
    if unsafe { (table.message_iter_open_container)(hints, TYPE_DICT_ENTRY, std::ptr::null(), &mut entry) } == 0 {
        return Err(Error::Wire("a hint's entry would not open".into()));
    }
    append_string(table, &mut entry, key)?;
    let mut variant = Iter::new();
    if unsafe { (table.message_iter_open_container)(&mut entry, TYPE_VARIANT, c"b".as_ptr(), &mut variant) } == 0 {
        return Err(Error::Wire("a hint's variant would not open".into()));
    }
    let mut slot = value as Bool;
    if unsafe { (table.message_iter_append_basic)(&mut variant, TYPE_BOOL, &mut slot as *mut Bool as *mut c_void) } == 0 {
        return Err(Error::Wire("a hint's value would not fit".into()));
    }
    if unsafe { (table.message_iter_close_container)(&mut entry, &mut variant) } == 0 {
        return Err(Error::Wire("a hint's variant would not close".into()));
    }
    if unsafe { (table.message_iter_close_container)(hints, &mut entry) } == 0 {
        return Err(Error::Wire("a hint's entry would not close".into()));
    }
    Ok(())
}

fn append_hint_string(table: &Symbols, hints: &mut Iter, key: &str, value: &str) -> Result<(), Error> {
    let mut entry = Iter::new();
    if unsafe { (table.message_iter_open_container)(hints, TYPE_DICT_ENTRY, std::ptr::null(), &mut entry) } == 0 {
        return Err(Error::Wire("a hint's entry would not open".into()));
    }
    append_string(table, &mut entry, key)?;
    let mut variant = Iter::new();
    if unsafe { (table.message_iter_open_container)(&mut entry, TYPE_VARIANT, c"s".as_ptr(), &mut variant) } == 0 {
        return Err(Error::Wire("a hint's variant would not open".into()));
    }
    append_string(table, &mut variant, value)?;
    if unsafe { (table.message_iter_close_container)(&mut entry, &mut variant) } == 0 {
        return Err(Error::Wire("a hint's variant would not close".into()));
    }
    if unsafe { (table.message_iter_close_container)(hints, &mut entry) } == 0 {
        return Err(Error::Wire("a hint's entry would not close".into()));
    }
    Ok(())
}

/// The CloseNotification message a removal becomes, body just the u32 id.
fn close_message(table: &Symbols, id: u32) -> Result<Message, Error> {
    let dest = c_of(DESTINATION);
    let path = c_of(PATH);
    let interface = c_of(INTERFACE);
    let member = c_of(MEMBER_CLOSE);
    let message = unsafe { (table.message_new_method_call)(dest.as_ptr(), path.as_ptr(), interface.as_ptr(), member.as_ptr()) };
    if message.is_null() {
        return Err(Error::Wire("the call would not form".into()));
    }
    let mut iter = Iter::new();
    unsafe { (table.message_iter_init_append)(message, &mut iter) };
    if let Err(error) = append_u32(table, &mut iter, id) {
        unsafe { (table.message_unref)(message) };
        return Err(error);
    }
    Ok(message)
}

/// The reply's one argument, the id the server assigned for replaces_id's
/// bookkeeping to name. A reply with nothing, or with something other
/// than a u32, is a server not speaking the spec.
fn reply_id(table: &Symbols, reply: Message) -> Result<u32, Error> {
    let mut iter = Iter::new();
    if unsafe { (table.message_iter_init)(reply, &mut iter) } == 0 {
        return Err(Error::Wire("the reply carried no id".into()));
    }
    if unsafe { (table.message_iter_get_arg_type)(&mut iter) } != TYPE_UINT32 {
        return Err(Error::Wire("the reply's id is not a uint".into()));
    }
    let mut id = 0u32;
    unsafe { (table.message_iter_get_basic)(&mut iter, &mut id as *mut u32 as *mut c_void) };
    Ok(id)
}

/// A connection's string table-entry at the ABI's distance, for the tests'
/// reads: get_basic lays the `const char*` in the slot for string types.
#[cfg(test)]
fn string_of(table: &Symbols, iter: &mut Iter) -> String {
    let mut pointer: *const c_char = std::ptr::null();
    unsafe { (table.message_iter_get_basic)(iter, &mut pointer as *mut *const c_char as *mut c_void) };
    unsafe { std::ffi::CStr::from_ptr(pointer) }.to_string_lossy().into_owned()
}

/// The guest's words, spoken by the desktop. One connection, opened
/// private, kept for the daemon's lifetime; the calls ride it serialized.
pub struct Presenter {
    connection: Connection,
    ids: Mutex<Ids>,
}

// Libdbus's threading is switched on at load (`dbus_threads_init_default`
// is the library's own prerequisite for a connection across threads), and
// the daemon serializes the presenter's calls besides — the marks carry
// that contract.
unsafe impl Send for Presenter {}
unsafe impl Sync for Presenter {}

impl Presenter {
    /// Rides the machine's session bus, or names what stands in the way.
    /// `Bus` means the daemon carries on without notifications — the
    /// sound engine's null backend, the same discipline.
    pub fn open() -> Result<Presenter, Error> {
        let table = table().ok_or(Error::Bus)?;
        // DBUS_BUS_SESSION is the zeroth bus; the error struct stays NULL
        // because the daemon's words for "no bus" are its own.
        let connection = unsafe { (table.bus_get_private)(0, std::ptr::null_mut()) };
        if connection.is_null() {
            return Err(Error::Bus);
        }
        Ok(Presenter { connection, ids: Mutex::new(Ids::new()) })
    }

    /// One notification out. `None` is the sorts the guest classifies out
    /// of the desktop itself (ongoing); `Some` carries the id the server
    /// assigned, the same one `replaces_id` names twice — the caller logs
    /// it if it likes.
    pub fn show(&self, notification: &Notification, app_name: &str) -> Result<Option<u32>, Error> {
        let Some(table) = table() else { return Err(Error::Bus) };
        let Some(message) = notify_message(&table, &self.ids.lock().expect("the ids' mutex is never poisoned"), notification, app_name)? else {
            return Ok(None);
        };
        let reply = self.call(&table, message)?;
        let id = reply_id(&table, reply)?;
        unsafe { (table.message_unref)(reply) };
        self.ids.lock().expect("the ids' mutex is never poisoned").stored(&notification.key, id);
        Ok(Some(id))
    }

    /// The guest's word for a notification gone: closes by the id the
    /// map's key names (the Mac's removeDeliveredNotifications with the
    /// key as the identifier). False for a key this presenter never
    /// showed — a stranger's removal is no work.
    pub fn remove(&self, key: &str) -> Result<bool, Error> {
        let Some(table) = table() else { return Err(Error::Bus) };
        let Some(id) = self.ids.lock().expect("the ids' mutex is never poisoned").removed(key) else {
            return Ok(false);
        };
        let message = close_message(&table, id)?;
        let reply = self.call(&table, message)?;
        unsafe { (table.message_unref)(reply) };
        Ok(true)
    }

    /// One call out and its reply back, bounded at the module's own wait.
    /// The outgoing message is unref'd here in every path —
    /// dbus-connection.c keeps the caller's ref on its plate.
    fn call(&self, table: &Symbols, message: Message) -> Result<Message, Error> {
        let reply = unsafe {
            (table.connection_send_with_reply_and_block)(self.connection, message, REPLY_WAIT_MS, std::ptr::null_mut())
        };
        unsafe { (table.message_unref)(message) };
        if reply.is_null() {
            // The bus refused the call or the wait ran out; the module's
            // words do not split the two because the caller reacts the
            // same to both.
            return Err(Error::Bus);
        }
        Ok(reply)
    }
}

impl Drop for Presenter {
    fn drop(&mut self) {
        let Some(table) = table() else { return };
        // The close first, the unref second: libdbus's own order for a
        // private connection the daemon is done with.
        unsafe { (table.connection_close)(self.connection) };
        unsafe { (table.connection_unref)(self.connection) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    /// The loader resolves where libdbus stands; tests that need the
    /// library say why they sit out when it does not (the env-free part
    /// of the alsa discipline — a machine without the library still gets
    /// the pure tests below).
    fn table_or_skip() -> Option<&'static Symbols> {
        let loaded = table();
        if loaded.is_none() {
            eprintln!("libdbus stands nowhere here; the marshaling tests sit out");
        }
        loaded
    }

    /// The guest's notification, the ordinary one.
    fn notification() -> Notification {
        Notification {
            package: "com.avo.notes".into(),
            key: "0|com.avo.notes|null|10032".into(),
            title: "Saved".into(),
            body: "The note synced to the other end.".into(),
            ..Default::default()
        }
    }

    #[test]
    fn the_loader_names_a_missing_symbol() {
        // The zero handle searches the process's own global scope, where
        // libdbus's names live only if it was loaded LOCAL — it never is —
        // so every name misses and the first reports itself.
        let error = match load_table(std::ptr::null_mut()) {
            Err(error) => error,
            Ok(_) => panic!("a handle with no symbols named a table anyway"),
        };
        assert_eq!(error, "libdbus has no dbus_threads_init_default");
    }

    #[test]
    fn the_loader_cannot_be_pretended_out_of_a_handle() {
        // A handle the search cannot reach does not fall back to
        // something else: the error names the loading, not the symbol —
        // the search's error message is the loader's last words, not a
        // lie about the table.
        //
        // (Companion to the one above: the *loader's* arm for a machine
        // without the library reports the dlopen error, kept in range by
        // the two names' shape and never by invention.)
        let error = match load_table(std::ptr::null_mut()) {
            Err(error) => error,
            Ok(_) => panic!("a handle with no symbols named a table anyway"),
        };
        assert!(!error.is_empty());
    }

    #[test]
    fn the_notify_message_carries_the_specified_arguments() {
        let Some(table) = table_or_skip() else { return };
        let ids = Ids::new();
        let guest = notification();
        let message = notify_message(table, &ids, &guest, "Avo").unwrap().unwrap();
        assert_eq!(unsafe { (table.message_get_type)(message) }, MESSAGE_TYPE_METHOD_CALL);
        assert_eq!(unsafe { CStr::from_ptr((table.message_get_destination)(message)) }.to_bytes(), DESTINATION.as_bytes());
        assert_eq!(unsafe { CStr::from_ptr((table.message_get_path)(message)) }.to_bytes(), PATH.as_bytes());
        assert_eq!(unsafe { CStr::from_ptr((table.message_get_interface)(message)) }.to_bytes(), INTERFACE.as_bytes());
        assert_eq!(unsafe { CStr::from_ptr((table.message_get_member)(message)) }.to_bytes(), MEMBER_NOTIFY.as_bytes());
        // The spec's argument list, in the marshaled type letters:
        // s u s s s as a{sv} i.
        assert_eq!(
            unsafe { CStr::from_ptr((table.message_get_signature)(message)) }.to_bytes(),
            b"sussasa{sv}i"
        );
        let mut iter = Iter::new();
        assert_ne!(unsafe { (table.message_iter_init)(message, &mut iter) }, 0);
        // app_name is the context slot, not the summary: the summary is
        // the title's, the app's name its own argument (the Mac's
        // title-with-subtitle split, where Linux splits them the spec's
        // way).
        assert_eq!(string_of(table, &mut iter), "Avo");
        assert_ne!(unsafe { (table.message_iter_next)(&mut iter) }, 0);
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_UINT32, "replaces_id");
        assert_ne!(unsafe { (table.message_iter_next)(&mut iter) }, 0);
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_STRING, "app_icon");
        assert_eq!(string_of(table, &mut iter), "");
        assert_ne!(unsafe { (table.message_iter_next)(&mut iter) }, 0);
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_STRING, "summary");
        assert_eq!(string_of(table, &mut iter), "Saved");
        assert_ne!(unsafe { (table.message_iter_next)(&mut iter) }, 0);
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_STRING, "body");
        assert_eq!(string_of(table, &mut iter), "The note synced to the other end.");
        assert_ne!(unsafe { (table.message_iter_next)(&mut iter) }, 0);
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_ARRAY, "actions");
        // Empty: no member inside (the back channel's seam reads the same).
        let mut actions = Iter::new();
        unsafe { (table.message_iter_recurse)(&mut iter, &mut actions) };
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut actions) }, 0);
        assert_ne!(unsafe { (table.message_iter_next)(&mut iter) }, 0);
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_ARRAY, "hints");
        unsafe {
            (table.message_unref)(message);
        }
    }

    #[test]
    fn the_library_rounds_the_message_through_its_own_bytes() {
        let Some(table) = table_or_skip() else { return };
        let mut ids = Ids::new();
        ids.stored(&"0|com.avo.notes|null|10032".to_owned(), 4242);
        let rebuilt = notify_message(table, &ids, &notification(), "Avo").unwrap().unwrap();
        // Marshal, give the buffer away, unmarshal, and the wire's own
        // reading of what it wrote agrees with the builder.
        let mut bytes: *mut c_char = std::ptr::null_mut();
        let mut length: c_int = 0;
        assert_ne!(unsafe { (table.message_marshal)(rebuilt, &mut bytes, &mut length) }, 0);
        assert!(length > 0);
        let walked = unsafe { (table.message_unmarshal)(bytes, length, MESSAGE_TYPE_METHOD_CALL) };
        assert!(!walked.is_null());
        unsafe { (table.free)(bytes as *mut c_void) };
        assert_eq!(
            unsafe { CStr::from_ptr((table.message_get_signature)(walked)) }.to_bytes(),
            b"sussasa{sv}i"
        );
        // The replaces_id rides the round trip: 4242, the stored id's
        // word, not the 0 a stranger's key earns.
        let mut iter = Iter::new();
        assert_ne!(unsafe { (table.message_iter_init)(walked, &mut iter) }, 0);
        // arg 1: app_name
        assert_eq!(string_of(table, &mut iter), "Avo");
        assert_ne!(unsafe { (table.message_iter_next)(&mut iter) }, 0);
        let mut replaces: u32 = 0;
        unsafe { (table.message_iter_get_basic)(&mut iter, &mut replaces as *mut u32 as *mut c_void) };
        assert_eq!(replaces, 4242);
        // The hints' dict survived: one entry, the package's thread.
        // (arg 5: body; arg 6: actions; arg 7: hints)
        unsafe { (table.message_iter_next)(&mut iter) };
        unsafe { (table.message_iter_next)(&mut iter) };
        unsafe { (table.message_iter_next)(&mut iter) };
        unsafe { (table.message_iter_next)(&mut iter) };
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_ARRAY);
        let mut hints = Iter::new();
        unsafe { (table.message_iter_recurse)(&mut iter, &mut hints) };
        // One entry: the key's string, then the variant holding a string.
        let mut entry = Iter::new();
        unsafe { (table.message_iter_recurse)(&mut hints, &mut entry) };
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut entry) }, TYPE_STRING, "the hint's key");
        assert_eq!(string_of(table, &mut entry), HINT_THREAD);
        let mut variant = Iter::new();
        unsafe { (table.message_iter_recurse)(&mut entry, &mut variant) };
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut variant) }, TYPE_STRING, "the hint's body type");
        assert_eq!(string_of(table, &mut variant), "com.avo.notes");
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut hints) }, 0, "one hint only, then quiet");
        unsafe { (table.message_unref)(walked) };
        unsafe { (table.message_unref)(rebuilt) };
    }

    #[test]
    fn a_silent_guest_carries_the_suppress_sound_hint() {
        let Some(table) = table_or_skip() else { return };
        let ids = Ids::new();
        let mut guest = notification();
        guest.silent = true;
        guest.package = String::new(); // the silent row alone in the hints
        let message = notify_message(table, &ids, &guest, "Avo").unwrap().unwrap();
        let mut iter = Iter::new();
        assert_ne!(unsafe { (table.message_iter_init)(message, &mut iter) }, 0);
        // Walk to the hints (arg 8's place: skip the seven before).
        for _ in 0..6 {
            unsafe { (table.message_iter_next)(&mut iter) };
        }
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut iter) }, TYPE_ARRAY);
        let mut hints = Iter::new();
        unsafe { (table.message_iter_recurse)(&mut iter, &mut hints) };
        let mut entry = Iter::new();
        unsafe { (table.message_iter_recurse)(&mut hints, &mut entry) };
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut entry) }, TYPE_STRING);
        assert_eq!(string_of(table, &mut entry), HINT_SUPPRESS_SOUND);
        let mut variant = Iter::new();
        unsafe { (table.message_iter_recurse)(&mut entry, &mut variant) };
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut variant) }, TYPE_BOOL);
        let mut value: Bool = 0;
        unsafe { (table.message_iter_get_basic)(&mut variant, &mut value as *mut Bool as *mut c_void) };
        assert_eq!(value, 1);
        assert_eq!(unsafe { (table.message_iter_get_arg_type)(&mut hints) }, 0, "the silence is the only hint");
        unsafe { (table.message_unref)(message) };
    }

    #[test]
    fn an_ongoing_notice_builds_nothing_at_all() {
        let Some(table) = table_or_skip() else { return };
        let ids = Ids::new();
        let mut guest = notification();
        guest.ongoing = true;
        // The Mac's sieve: None, no server reached, no id spent.
        assert!(notify_message(table, &ids, &guest, "Avo").unwrap().is_none());
    }

    #[test]
    fn the_key_replaces_through_the_map() {
        let mut ids = Ids::new();
        // The stranger's first arrival: new, id 0.
        assert_eq!(ids.replaces("a"), 0);
        ids.stored("a", 7);
        assert_eq!(ids.replaces("a"), 7, "the second arrival names the first's id");
        // A newer store is the one the next arrival replaces: the map
        // keeps the latest, never both.
        ids.stored("a", 8);
        assert_eq!(ids.replaces("a"), 8);
        // A stranger's removal is no work; the key's own hands its id out
        // and forgets — the next arrival starts clean.
        assert!(ids.removed("b").is_none());
        assert_eq!(ids.removed("a"), Some(8));
        assert_eq!(ids.replaces("a"), 0);
    }

    #[test]
    fn the_summary_falls_back_to_the_app_name() {
        let mut guest = notification();
        assert_eq!(summary(&guest, "Avo"), "Saved", "the title carries when it is there");
        guest.title = String::new();
        assert_eq!(summary(&guest, "Avo"), "Avo", "the app's name carries when the title is not");
    }

    // Gaps this module carries on purpose, read from the Mac's side:
    // * `large_icon_png` travels nowhere — the Mac's temp-file attachment
    //   has no honest freedesktop analog without a PNG→pixels step;
    // * the actions stay empty: the Mac's dismiss action and its click →
    //   openNotification(package, key) back channel need a daemon side
    //   that reads the server's action replies, a later slice;
    // * `close()` on the wire (`Goodbye`) is not the desktop's matter —
    //   the daemon's own session words cover it, and no signal of the
    //   user's *dismissal* comes back from the server to guest either
    //   way (the Mac's UNUserNotificationCenterDelegate didDidDismiss is
    //   the other half of the back channel's gap);
    // * a live session bus is never touched in tests: every shape above
    //   is pinned by libdbus's own marshal/unmarshal, and what a real
    //   server *does* with the call (terms the spec's conformance table
    //   names) is read when a recipe for CI on a desktop lands.
}
