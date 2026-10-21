//! The Input channel's records (vsock port 6001): fixed-layout
//! little-endian binary, deliberately not protobuf — the guest decodes into
//! a reused ByteBuffer so a 1000 Hz mouse never allocates (docs/protocol.md
//! "Input channel"; guest/bridge-agent/src/dev/avo/bridge/input/InputServer.java).
//! The layout's source of truth is that side: field offsets live in
//! dev.avo.bridge.input.InputRecords.java beside it, and the Mac's encoder —
//! the peer that produces these bytes — is
//! host/AvoKit/Sources/AvoProtocol/InputRecord.swift (`InputWire`), which
//! this module transcribes for the daemon's senders. The golden fixture
//! proto/testdata/input-v1.bin carries eight records the Swift tests
//! encoded (AvoProtocolTests/InputWireTests.swift's
//! `goldenFileMatchesEncoding` writes it, guest's test/InputRecordsTest.java
//! reads it through the injector's accessors); the tests below decode it and
//! reproduce it byte for byte.
//!
//! The channel's live rules, as the guest applies them: both sides send an
//! 8-byte preamble, the lower version wins (docs/protocol.md; the guest
//! checks the magic and answers with its own, applying no version rule —
//! the Mac's `negotiate` computes min(peer, own) and refuses a peer below
//! 1); a header length under 8 or over the 1024-byte cap throws "bad input
//! record length" and ends the session (InputServer.java); unknown types
//! are skipped using length; and a PING record is echoed verbatim, token
//! and all, for input round-trip measurement. On the Mac the same wire is
//! what App Shims push through the daemon — it validates each record
//! decodes whole and targets a display its sender owns, and refuses a
//! shim's PING (AvoDaemonCore's InputChannel.forward) — so this module's
//! `decode` exists for the day the Linux daemon forwards the same way; the
//! daemon itself only ever encodes.

/// The preamble's magic, ASCII `AVOI` (InputServer.java's MAGIC, and the
/// Mac's `InputWire.magic`).
pub const MAGIC: [u8; 4] = *b"AVOI";

/// Both sides' current input-channel version (Protocol.java's
/// INPUT_VERSION = 1; docs/protocol.md: "currently 1").
pub const INPUT_VERSION: u16 = 1;

/// One preamble's or header's length; the record header's fields sit in
/// those first 8 bytes of every record.
pub const PREAMBLE_LEN: usize = 8;
pub const HEADER_LEN: usize = 8;

/// The largest record either side accepts (Protocol.java's
/// INPUT_MAX_RECORD = 1024, docs/protocol.md). A header length over this
/// ends the guest's session; the host refuse-equivalent is the Mac's
/// InputWireError.recordTooLong.
pub const MAX_RECORD: usize = 1024;

/// The room text leaves: a u16 byte count at offset 8 and the UTF-8 from
/// offset 10 (the Mac's InputWire.maxTextBytes — with no padding, exactly
/// this much text fills a 1024-byte record).
pub const MAX_TEXT: usize = MAX_RECORD - HEADER_LEN - 2;

/// Record type codes (dev.avo.bridge input's TYPE_* constants in both
/// InputRecords.java and InputInjector.java; the Mac's RecordType carries
/// the same values).
pub const TYPE_TOUCH: u8 = 0x01;
pub const TYPE_KEY: u8 = 0x02;
pub const TYPE_SCROLL: u8 = 0x03;
pub const TYPE_TEXT: u8 = 0x04;
pub const TYPE_MOUSE: u8 = 0x05;
pub const TYPE_GAMEPAD: u8 = 0x06;
pub const TYPE_PING: u8 = 0x7F;

// ---------------------------------------------------------------------------
// Record types

/// The touch record's action byte — Android's MotionEvent values the host
/// sends: down, up, move, cancel and the pointer-indexed pair (4 is
/// ACTION_OUTSIDE, which a window's own display never produces). The Mac's
/// TouchAction carries the same six; the guest folds
/// POINTER_DOWN/UP's action_index back through ACTION_POINTER_INDEX_SHIFT
/// (InputInjector.touch()).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum TouchAction {
    Down = 0,
    Up = 1,
    Move = 2,
    Cancel = 3,
    PointerDown = 5,
    PointerUp = 6,
}

impl TouchAction {
    fn from_code(code: u8) -> Option<TouchAction> {
        Some(match code {
            0 => TouchAction::Down,
            1 => TouchAction::Up,
            2 => TouchAction::Move,
            3 => TouchAction::Cancel,
            5 => TouchAction::PointerDown,
            6 => TouchAction::PointerUp,
            _ => return None,
        })
    }
}

/// The key record's action byte: 0 down, 1 up. The guest reads any nonzero
/// as up (InputRecords.java's keyDown), so the Mac's two values are the
/// only ones that exist.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum KeyAction {
    Down = 0,
    Up = 1,
}

impl KeyAction {
    fn from_code(code: u8) -> Option<KeyAction> {
        Some(match code {
            0 => KeyAction::Down,
            1 => KeyAction::Up,
            _ => return None,
        })
    }
}

/// The mouse record's action byte — the MotionEvent actions a real pointer
/// uses: down/up/move (0/1/2), hover move/enter/exit (7/9/10) and the
/// button pair (11/12). The guest injects the byte straight as the action
/// (InputInjector.mouse()), so this covers what senders send; the Mac's
/// MouseEvent.Action carries the same eight.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum MouseAction {
    Down = 0,
    Up = 1,
    Move = 2,
    HoverMove = 7,
    HoverEnter = 9,
    HoverExit = 10,
    ButtonPress = 11,
    ButtonRelease = 12,
}

impl MouseAction {
    fn from_code(code: u8) -> Option<MouseAction> {
        Some(match code {
            0 => MouseAction::Down,
            1 => MouseAction::Up,
            2 => MouseAction::Move,
            7 => MouseAction::HoverMove,
            9 => MouseAction::HoverEnter,
            10 => MouseAction::HoverExit,
            11 => MouseAction::ButtonPress,
            12 => MouseAction::ButtonRelease,
            _ => return None,
        })
    }
}

/// One pointer of a touch: its Android pointer id and display-pixel
/// coordinates, origin top-left (docs/protocol.md); pressure rides
/// unvalidated, 1.0 being the Mac's default (TouchPointer's init).
#[derive(Clone, Debug, PartialEq)]
pub struct Pointer {
    pub id: u32,
    pub x: f32,
    pub y: f32,
    pub pressure: f32,
}

/// A complete MotionEvent: the action plus every pointer currently down
/// (docs/protocol.md), so a MOVE re-sends the array with fresh coordinates.
/// One byte carries pointer_count, so 16 pointers are the cap — the guest
/// clamps beyond it (InputInjector.touch's Math.min) while the Mac's
/// encoder refuses outright.
#[derive(Clone, Debug, PartialEq)]
pub struct Touch {
    pub display_id: u32,
    pub action: TouchAction,
    /// Index into `pointers` of the pointer that came or went; only
    /// POINTER_DOWN/UP give it a meaning.
    pub action_index: u8,
    pub pointers: Vec<Pointer>,
}

/// An Android KeyEvent (docs/protocol.md): a `KEYCODE_*` at offset 12, the
/// `META_*` bits held around it, the auto-repeat count, and a scancode (0
/// when unknown). The guest builds the event with
/// KeyCharacterMap.VIRTUAL_KEYBOARD and SOURCE_KEYBOARD
/// (InputInjector.key()).
#[derive(Clone, Debug, PartialEq)]
pub struct Key {
    pub display_id: u32,
    pub action: KeyAction,
    pub keycode: u32,
    pub meta_state: u32,
    pub repeat: u32,
    pub scancode: u32,
}

/// A mouse wheel's notches at a pointer position, decoded as ACTION_SCROLL
/// with SOURCE_MOUSE (InputInjector.scroll()): x/y where the pointer was,
/// h_scroll/v_scroll the AXIS_HSCROLL/AXIS_VSCROLL amounts with 1.0 = one
/// notch (docs/protocol.md), buttons the mouse buttons held. The Mac's
/// wheel logic writes a notch's dx/dy (lines in the content's direction)
/// as horizontal = -dx and vertical = dy, so AXIS_VSCROLL is positive when
/// the content moves down (the wheel rolled away from the user) and
/// AXIS_HSCROLL when it moves left (WheelScrolling.swift's scrollEvent).
#[derive(Clone, Debug, PartialEq)]
pub struct Scroll {
    pub display_id: u32,
    pub x: f32,
    pub y: f32,
    pub h_scroll: f32,
    pub v_scroll: f32,
    pub buttons: u32,
}

/// Committed text as UTF-8 (dead keys, the emoji picker, paste-as-typing):
/// a u16 byte count at offset 8, the bytes from 10, and no padding — the
/// record's length is exactly 10 + count. The guest turns it into key
/// events through KeyCharacterMap.getEvents and falls back to one
/// ACTION_MULTIPLE KeyEvent that text fields commit directly
/// (InputInjector.text()); bad UTF-8 rides on as replacement characters,
/// both readers decoding lossily.
#[derive(Clone, Debug, PartialEq)]
pub struct Text {
    pub display_id: u32,
    pub text: String,
}

/// Real pointer events for the apps whose keymap profile opts in — by
/// default the host sends clicks as touches (docs/protocol.md). buttons
/// carries the BUTTON_* bits held and action_button the button the event
/// is about, which the guest sets only for BUTTON_PRESS/RELEASE
/// (InputInjector.mouse(), over its setActionButton reflection).
#[derive(Clone, Debug, PartialEq)]
pub struct Mouse {
    pub display_id: u32,
    pub action: MouseAction,
    pub x: f32,
    pub y: f32,
    pub buttons: u32,
    pub action_button: u32,
}

/// A controller's whole state. The buttons' bits are AvoKit's
/// GamepadButton — bit = 1 << index in the enum's order a, b, x, y,
/// leftShoulder, rightShoulder, leftTrigger, rightTrigger, dpadUp,
/// dpadDown, dpadLeft, dpadRight, leftThumbstick, rightThumbstick, menu,
/// options (Keys.swift) — with Home on bit 16 (docs/protocol.md). `axes`
/// indexes leftX, leftY, rightX, rightY, leftTrigger, rightTrigger, hatX,
/// hatY in GameController's units: sticks and hat -1…1 with y up, triggers
/// 0…1 (GamepadState in InputRecord.swift, EngineGamepad.swift). The
/// Bridge Agent's injector logs and drops the record for now
/// (InputInjector's TYPE_GAMEPAD arm); on the Mac the daemon plays records
/// like this one on the engine's virtual Xbox pad instead
/// (EngineGamepad.command). display_id names the key window's display that
/// drives the pad, and the guest unplugs the gamepad when that display
/// closes (docs/protocol.md; InputChannel.swift's displayID(of:) note).
#[derive(Clone, Debug, PartialEq)]
pub struct Gamepad {
    pub display_id: u32,
    pub pad: u8,
    pub connected: bool,
    pub buttons: u32,
    /// Exactly eight, fixed by the layout (Swift's GamepadState
    /// precondition).
    pub axes: [f32; 8],
}

/// The latency probe: a u64 token at offset 8, and the header names no
/// display — the Mac writes 0 for it (InputRecord.swift's
/// header(.ping, displayID: 0)). The guest echoes the whole record back
/// verbatim on the same stream (InputServer.java), and the daemon matches
/// the echo's token to its send time (InputChannel's ping/pong means).
#[derive(Clone, Debug, PartialEq)]
pub struct Ping {
    pub token: u64,
}

/// One record of the channel. The header every one carries: type u8
/// (offsets 0), flags u8 reserved 0, length u16 LE (offsets 2, total
/// record length including this header), display_id u32 LE (offsets 4,
/// target display, 0 = focused display) — docs/protocol.md, and the guest's
/// accessors in InputRecords.java read exactly those fields. Every integer
/// is little-endian and every float IEEE-754 `f32`.
#[derive(Clone, Debug, PartialEq)]
pub enum Record {
    Touch(Touch),
    Key(Key),
    Scroll(Scroll),
    Text(Text),
    Mouse(Mouse),
    Gamepad(Gamepad),
    Ping(Ping),
}

/// What `encode` refuses, and what a record the wire cannot carry decodes
/// to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// The peer's preamble is not this channel's: wrong magic or a version
    /// below 1 (the Mac's InputWireError.badPreamble — the guest instead
    /// ends the session with "bad input preamble", InputServer.java).
    BadPreamble,
    /// A touch record's pointer count outside 1…16: `encode` sees a Vec of
    /// that size, `decode` the record's count byte (the Mac's
    /// InputWireError.tooManyPointers covers both; the guest clamps
    /// instead, InputInjector.touch).
    TooManyPointers(usize),
    /// Text whose UTF-8 would leave the record over the cap (1014 bytes at
    /// this version; the Mac's InputWireError.textTooLong).
    TextTooLong(usize),
    /// A record whose length field is under the header itself or over the
    /// 1024-byte cap — the guest throws "bad input record length" and the
    /// session ends (InputServer.java; the Mac's recordTooShort/Long).
    BadLength(usize),
    /// An action byte outside its type's values (the Mac's
    /// InputWireError.invalidAction; the guest's touch() would otherwise
    /// build a MotionEvent that Android's injector refuses).
    BadAction(u8),
}

/// The 8 bytes both sides send before any records: the magic, the version
/// this side speaks, and a reserved u16 0 (docs/protocol.md "Preamble").
/// The guest answers with its own after checking the magic alone
/// (InputServer.java); the Mac's bytes are pinned by its
/// `preambleNegotiation` test — [b'A', b'V', b'O', b'I', 1, 0, 0, 0].
pub fn preamble(version: u16) -> [u8; PREAMBLE_LEN] {
    let mut preamble = [0u8; PREAMBLE_LEN];
    preamble[..4].copy_from_slice(&MAGIC);
    preamble[4..6].copy_from_slice(&version.to_le_bytes());
    // The trailing u16 reserved zero is already in place.
    preamble
}

/// The version the channel uses once both preambles are in: the lower of
/// the two (docs/protocol.md). The Mac computes min(peer, own) and refuses
/// a peer below 1 (InputRecord.swift's negotiate); the guest reads neither
/// rule — it is the one being responded to.
pub fn negotiate(peer_preamble: &[u8]) -> Result<u16, Error> {
    if peer_preamble.len() != PREAMBLE_LEN || &peer_preamble[..4] != &MAGIC {
        return Err(Error::BadPreamble);
    }
    let peer = u16::from_le_bytes([peer_preamble[4], peer_preamble[5]]);
    if peer < 1 {
        return Err(Error::BadPreamble);
    }
    Ok(peer.min(INPUT_VERSION))
}

/// What a decode found at the front of `bytes`.
#[derive(Clone, Debug, PartialEq)]
pub enum Decoded {
    /// A record and the bytes it consumed.
    Record(Record, usize),
    /// A record type this version does not know: skip that many bytes — the
    /// guest's inject falls through its switch, the Mac's decoder returns a
    /// nil record, and docs/protocol.md calls the practice out ("Unknown
    /// types are skipped using length").
    Skip(usize),
    /// Fewer bytes than the header or the header's length asks for: append
    /// more and try again from the same offset (the Mac's InputRecordDecoder
    /// does exactly this on its growing buffer).
    Partial,
}

impl Record {
    /// Appends the record's exact wire bytes to `out` — the same bytes the
    /// guest's `ByteBuffer` will hold. Each total length is known before
    /// the fields go down, so the header's u16 length is written once,
    /// not patched.
    ///
    /// Fails only on the sizes no valid record can carry: a touch outside
    /// 1…16 pointers (`TooManyPointers`, the Mac's tooManyPointers) or text
    /// over `MAX_TEXT` bytes (`TextTooLong`).
    pub fn encode(&self, out: &mut Vec<u8>) -> Result<(), Error> {
        match self {
            Record::Touch(touch) => {
                let count = touch.pointers.len();
                if !(1..=16).contains(&count) {
                    return Err(Error::TooManyPointers(count));
                }
                let header_len = 16 + 16 * count;
                put_header(out, TYPE_TOUCH, touch.display_id, header_len as u16);
                out.push(touch.action as u8);
                out.push(touch.action_index);
                out.push(count as u8);
                out.push(0); // reserved u8 at offset 11
                out.extend_from_slice(&[0, 0, 0, 0]); // reserved u32 at 12…16
                for pointer in &touch.pointers {
                    // InputRecords.java reads pointer i at 16 + i*16:
                    // id u32, then x, y, pressure f32.
                    out.extend_from_slice(&pointer.id.to_le_bytes());
                    out.extend_from_slice(&pointer.x.to_le_bytes());
                    out.extend_from_slice(&pointer.y.to_le_bytes());
                    out.extend_from_slice(&pointer.pressure.to_le_bytes());
                }
            }
            Record::Key(key) => {
                put_header(out, TYPE_KEY, key.display_id, 28);
                out.push(key.action as u8);
                out.extend_from_slice(&[0, 0, 0]); // reserved u8 + u16 at 9…12
                out.extend_from_slice(&key.keycode.to_le_bytes());
                out.extend_from_slice(&key.meta_state.to_le_bytes());
                out.extend_from_slice(&key.repeat.to_le_bytes());
                out.extend_from_slice(&key.scancode.to_le_bytes());
            }
            Record::Scroll(scroll) => {
                put_header(out, TYPE_SCROLL, scroll.display_id, 28);
                out.extend_from_slice(&scroll.x.to_le_bytes());
                out.extend_from_slice(&scroll.y.to_le_bytes());
                out.extend_from_slice(&scroll.h_scroll.to_le_bytes());
                out.extend_from_slice(&scroll.v_scroll.to_le_bytes());
                out.extend_from_slice(&scroll.buttons.to_le_bytes());
            }
            Record::Text(text) => {
                let utf8 = text.text.as_bytes();
                if utf8.len() > MAX_TEXT {
                    return Err(Error::TextTooLong(utf8.len()));
                }
                put_header(out, TYPE_TEXT, text.display_id, (10 + utf8.len()) as u16);
                out.extend_from_slice(&(utf8.len() as u16).to_le_bytes());
                out.extend_from_slice(utf8);
            }
            Record::Mouse(mouse) => {
                put_header(out, TYPE_MOUSE, mouse.display_id, 28);
                out.push(mouse.action as u8);
                out.extend_from_slice(&[0, 0, 0]); // reserved u8 + u16 at 9…12
                out.extend_from_slice(&mouse.x.to_le_bytes());
                out.extend_from_slice(&mouse.y.to_le_bytes());
                out.extend_from_slice(&mouse.buttons.to_le_bytes());
                out.extend_from_slice(&mouse.action_button.to_le_bytes());
            }
            Record::Gamepad(gamepad) => {
                put_header(out, TYPE_GAMEPAD, gamepad.display_id, 48);
                out.push(gamepad.pad);
                out.push(u8::from(gamepad.connected)); // 1/0 exactly, InputRecords.java's connected
                out.extend_from_slice(&[0, 0]); // reserved u16 at 10…12
                out.extend_from_slice(&gamepad.buttons.to_le_bytes());
                for axis in gamepad.axes {
                    out.extend_from_slice(&axis.to_le_bytes()); // 8 f32s from offset 16
                }
            }
            Record::Ping(ping) => {
                put_header(out, TYPE_PING, 0, 16);
                out.extend_from_slice(&ping.token.to_le_bytes());
            }
        }
        Ok(())
    }
}

/// Reads one record off the front of `bytes`. The rules mirror the two
/// peers' decoders: a length outside [8, 1024] is `BadLength` no matter
/// how few bytes stand behind it (checked before completeness — the Mac's
/// recordTooLong fires the same way); truncated records are `Partial`;
/// each body's fields are read only after the record's minimum is proved
/// (the Mac's `require` calls) so a short record is refused rather than
/// read into a neighbour's bytes.
pub fn decode(bytes: &[u8]) -> Result<Decoded, Error> {
    if bytes.len() < HEADER_LEN {
        return Ok(Decoded::Partial);
    }
    let type_code = bytes[0];
    // bytes[1] is the flags byte — reserved 0, never checked by either
    // reader (the Mac's decode discards it).
    let length = u16::from_le_bytes([bytes[2], bytes[3]]) as usize;
    let display_id = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    if !(HEADER_LEN..=MAX_RECORD).contains(&length) {
        return Err(Error::BadLength(length));
    }
    if bytes.len() < length {
        return Ok(Decoded::Partial);
    }
    let mut reader = Reader { bytes: &bytes[..length], at: HEADER_LEN };
    match type_code {
        TYPE_TOUCH => {
            if length < 16 {
                return Err(Error::BadLength(length));
            }
            let raw = reader.u8();
            let Some(action) = TouchAction::from_code(raw) else {
                return Err(Error::BadAction(raw));
            };
            let action_index = reader.u8();
            let count = reader.u8() as usize;
            reader.skip(1); // reserved u8 at 11
            reader.skip(4); // reserved u32 at 12
            if !(1..=16).contains(&count) {
                return Err(Error::TooManyPointers(count));
            }
            if length < 16 + 16 * count {
                return Err(Error::BadLength(length));
            }
            let mut pointers = Vec::with_capacity(count);
            for _ in 0..count {
                let id = reader.u32();
                let x = reader.f32();
                let y = reader.f32();
                let pressure = reader.f32();
                pointers.push(Pointer { id, x, y, pressure });
            }
            Ok(Decoded::Record(
                Record::Touch(Touch { display_id, action, action_index, pointers }),
                length,
            ))
        }
        TYPE_KEY => {
            if length < 28 {
                return Err(Error::BadLength(length));
            }
            let raw = reader.u8();
            let Some(action) = KeyAction::from_code(raw) else {
                return Err(Error::BadAction(raw));
            };
            reader.skip(3); // reserved u8 + u16 — the guest reads byte 8 alone
            let keycode = reader.u32();
            let meta_state = reader.u32();
            let repeat = reader.u32();
            let scancode = reader.u32();
            Ok(Decoded::Record(
                Record::Key(Key { display_id, action, keycode, meta_state, repeat, scancode }),
                length,
            ))
        }
        TYPE_SCROLL => {
            if length < 28 {
                return Err(Error::BadLength(length));
            }
            let x = reader.f32();
            let y = reader.f32();
            let h_scroll = reader.f32();
            let v_scroll = reader.f32();
            let buttons = reader.u32();
            Ok(Decoded::Record(
                Record::Scroll(Scroll { display_id, x, y, h_scroll, v_scroll, buttons }),
                length,
            ))
        }
        TYPE_TEXT => {
            if length < 10 {
                return Err(Error::BadLength(length));
            }
            let count = reader.u16() as usize;
            if length < 10 + count {
                return Err(Error::BadLength(length)); // the count runs past the record
            }
            let text = String::from_utf8_lossy(reader.rest(count)).into_owned();
            Ok(Decoded::Record(Record::Text(Text { display_id, text }), length))
        }
        TYPE_MOUSE => {
            if length < 28 {
                return Err(Error::BadLength(length));
            }
            let raw = reader.u8();
            let Some(action) = MouseAction::from_code(raw) else {
                return Err(Error::BadAction(raw));
            };
            reader.skip(3); // reserved u8 + u16
            let x = reader.f32();
            let y = reader.f32();
            let buttons = reader.u32();
            let action_button = reader.u32();
            Ok(Decoded::Record(
                Record::Mouse(Mouse { display_id, action, x, y, buttons, action_button }),
                length,
            ))
        }
        TYPE_GAMEPAD => {
            if length < 48 {
                return Err(Error::BadLength(length));
            }
            let pad = reader.u8();
            let connected = reader.u8() != 0;
            reader.skip(2); // reserved u16
            let buttons = reader.u32();
            let mut axes = [0.0f32; 8];
            for axis in &mut axes {
                *axis = reader.f32();
            }
            Ok(Decoded::Record(
                Record::Gamepad(Gamepad { display_id, pad, connected, buttons, axes }),
                length,
            ))
        }
        TYPE_PING => {
            if length < 16 {
                return Err(Error::BadLength(length));
            }
            let token = reader.u64();
            // The header's display_id is dropped: a ping is about the token,
            // and an echo travels as the raw bytes it came in as.
            Ok(Decoded::Record(Record::Ping(Ping { token }), length))
        }
        _ => Ok(Decoded::Skip(length)),
    }
}

/// Puts one record header down: type, flags 0, length LE, display_id LE.
fn put_header(out: &mut Vec<u8>, type_code: u8, display_id: u32, length: u16) {
    out.push(type_code);
    out.push(0); // flags: reserved 0 (docs/protocol.md; the Mac writes 0)
    out.extend_from_slice(&length.to_le_bytes());
    out.extend_from_slice(&display_id.to_le_bytes());
}

/// A cursor over one record's span. Every read sits inside bounds a caller
/// proved first against the record's length — one that did not would be a
/// bug, so the fields index straight in.
struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn u8(&mut self) -> u8 {
        let value = self.bytes[self.at];
        self.at += 1;
        value
    }

    fn u16(&mut self) -> u16 {
        let value = u16::from_le_bytes([self.bytes[self.at], self.bytes[self.at + 1]]);
        self.at += 2;
        value
    }

    fn u32(&mut self) -> u32 {
        let value = u32::from_le_bytes([
            self.bytes[self.at],
            self.bytes[self.at + 1],
            self.bytes[self.at + 2],
            self.bytes[self.at + 3],
        ]);
        self.at += 4;
        value
    }

    fn u64(&mut self) -> u64 {
        let value = u64::from_le_bytes([
            self.bytes[self.at],
            self.bytes[self.at + 1],
            self.bytes[self.at + 2],
            self.bytes[self.at + 3],
            self.bytes[self.at + 4],
            self.bytes[self.at + 5],
            self.bytes[self.at + 6],
            self.bytes[self.at + 7],
        ]);
        self.at += 8;
        value
    }

    fn f32(&mut self) -> f32 {
        let mut chunk = [0u8; 4];
        chunk.copy_from_slice(&self.bytes[self.at..self.at + 4]);
        self.at += 4;
        f32::from_le_bytes(chunk)
    }

    fn rest(&mut self, count: usize) -> &[u8] {
        let slice = &self.bytes[self.at..self.at + count];
        self.at += count;
        slice
    }

    fn skip(&mut self, count: usize) {
        self.at += count;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Encodes one record, which no test record here should fail to do.
    fn wire(record: &Record) -> Vec<u8> {
        let mut out = Vec::new();
        record.encode(&mut out).expect("a test record encodes");
        out
    }

    /// The eight records AvoProtocolTests/InputWireTests.swift encodes into
    /// proto/testdata/input-v1.bin, in its order (the Swift tests'
    /// `samples`).
    fn golden_records() -> Vec<Record> {
        vec![
            Record::Touch(Touch {
                display_id: 2,
                action: TouchAction::Down,
                action_index: 0,
                pointers: vec![Pointer { id: 0, x: 10.5, y: 20.25, pressure: 1.0 }],
            }),
            Record::Touch(Touch {
                display_id: 2,
                action: TouchAction::PointerDown,
                action_index: 1,
                pointers: vec![
                    Pointer { id: 0, x: 10.0, y: 20.0, pressure: 1.0 },
                    Pointer { id: 4, x: 300.0, y: 400.0, pressure: 0.5 },
                ],
            }),
            Record::Key(Key {
                display_id: 5,
                action: KeyAction::Down,
                keycode: 111,
                meta_state: 0x1000,
                repeat: 2,
                scancode: 1,
            }),
            Record::Scroll(Scroll {
                display_id: 1,
                x: 100.0,
                y: 200.0,
                h_scroll: -0.5,
                v_scroll: 2.0,
                buttons: 0,
            }),
            Record::Text(Text { display_id: 1, text: "Halo, dunia! 🥑".into() }),
            Record::Mouse(Mouse {
                display_id: 3,
                action: MouseAction::ButtonPress,
                x: 1.0,
                y: 2.0,
                buttons: 2,
                action_button: 2,
            }),
            Record::Gamepad(Gamepad {
                display_id: 0,
                pad: 1,
                connected: true,
                buttons: 0b1011,
                axes: [0.1, -0.2, 0.3, -0.4, 1.0, 0.0, -1.0, 1.0],
            }),
            Record::Ping(Ping { token: 0xDEAD_BEEF_CAFE }),
        ]
    }

    /// The golden fixture: eight of the Mac's encoded records.
    const GOLDEN: &[u8] = include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../proto/testdata/input-v1.bin"
    ));

    #[test]
    fn every_record_kind_roundtrips_through_the_wire() {
        let mut records = golden_records();
        records.extend([
            // A full 16-pointer MOVE: the touch record's widest shape.
            Record::Touch(Touch {
                display_id: 9,
                action: TouchAction::Move,
                action_index: 0,
                pointers: (0..16u32)
                    .map(|i| Pointer { id: i, x: i as f32 * 1.5, y: 767.0 - i as f32, pressure: 0.25 })
                    .collect(),
            }),
            Record::Touch(Touch {
                display_id: 1,
                action: TouchAction::Cancel,
                action_index: 0,
                pointers: vec![Pointer { id: 0, x: 5.0, y: 6.0, pressure: 1.0 }],
            }),
            Record::Key(Key {
                display_id: 7,
                action: KeyAction::Up,
                keycode: 29,
                meta_state: 0,
                repeat: 0,
                scancode: 0,
            }),
            Record::Mouse(Mouse {
                display_id: 3,
                action: MouseAction::HoverMove,
                x: -1.5,
                y: 2.5,
                buttons: 0,
                action_button: 0,
            }),
            // A gamepad whose header carries a foreign display: the guest
            // unplugs the pad when that display closes (docs/protocol.md).
            Record::Gamepad(Gamepad {
                display_id: 4,
                pad: 3,
                connected: false,
                buttons: 1 << 16, // Home (docs/protocol.md)
                axes: [0.75, -0.25, 0.5, -0.5, 1.0, 0.0, -1.0, 0.125],
            }),
        ]);
        for record in &records {
            let out = wire(record);
            match decode(&out).expect("a self-encoded record decodes") {
                Decoded::Record(back, consumed) => {
                    assert_eq!(consumed, out.len(), "consumes exactly its own bytes: {record:?}");
                    assert_eq!(back, *record, "{record:?}");
                }
                other => panic!("a self-encoded record must not read as {other:?}"),
            }
        }
    }

    #[test]
    fn encoding_the_fixture_samples_reproduces_the_golden_bytes() {
        // The fixture is written by the Swift test's encoder
        // (goldenFileMatchesEncoding, rewritten under AVO_UPDATE_GOLDEN=1);
        // the same eight records re-encoded here must be the same bytes.
        let mut out = Vec::new();
        for record in golden_records() {
            record.encode(&mut out).expect("a golden record encodes");
        }
        assert_eq!(out, GOLDEN, "the wire must match the Swift encoder's bytes");
    }

    #[test]
    fn the_golden_fixture_decodes_record_by_record() {
        // The checks track test/InputRecordsTest.java, which reads the
        // fixture through dev.avo.bridge.input.InputRecords's accessors —
        // the same reads the injector does.
        let mut at = 0;
        let mut records = Vec::new();
        while at < GOLDEN.len() {
            match decode(&GOLDEN[at..]).expect("the fixture holds well-formed records") {
                Decoded::Record(record, consumed) => {
                    at += consumed;
                    records.push(record);
                }
                other => panic!("the fixture must not stop short: {other:?}"),
            }
        }
        assert_eq!(at, GOLDEN.len(), "the fixture is fully records");
        assert_eq!(records.len(), 8);

        let Record::Touch(touch) = &records[0] else {
            panic!("record 0 is a touch");
        };
        assert_eq!(touch.display_id, 2);
        assert_eq!(touch.action, TouchAction::Down);
        assert_eq!(touch.pointers.len(), 1);
        assert_eq!(touch.pointers[0].x, 10.5);
        assert_eq!(touch.pointers[0].y, 20.25);
        assert_eq!(touch.pointers[0].pressure, 1.0);

        let Record::Touch(touch) = &records[1] else {
            panic!("record 1 is a touch");
        };
        assert_eq!(touch.action, TouchAction::PointerDown);
        assert_eq!(touch.action_index, 1);
        assert_eq!(touch.pointers.len(), 2);
        assert_eq!(touch.pointers[1].id, 4);
        assert_eq!(touch.pointers[1].x, 300.0);
        assert_eq!(touch.pointers[1].pressure, 0.5);

        let Record::Key(key) = &records[2] else {
            panic!("record 2 is a key");
        };
        assert_eq!(key.display_id, 5);
        assert_eq!(key.action, KeyAction::Down);
        assert_eq!(key.keycode, 111);
        assert_eq!(key.meta_state, 0x1000);
        assert_eq!(key.repeat, 2);
        assert_eq!(key.scancode, 1);

        let Record::Scroll(scroll) = &records[3] else {
            panic!("record 3 is a scroll");
        };
        assert_eq!(scroll.x, 100.0);
        assert_eq!(scroll.y, 200.0);
        assert_eq!(scroll.h_scroll, -0.5);
        assert_eq!(scroll.v_scroll, 2.0);

        let Record::Text(text) = &records[4] else {
            panic!("record 4 is text");
        };
        assert_eq!(text.text, "Halo, dunia! 🥑");

        let Record::Mouse(mouse) = &records[5] else {
            panic!("record 5 is a mouse");
        };
        assert_eq!(mouse.action, MouseAction::ButtonPress);
        assert_eq!(mouse.x, 1.0);
        assert_eq!(mouse.y, 2.0);
        assert_eq!(mouse.buttons, 2);
        assert_eq!(mouse.action_button, 2);

        let Record::Gamepad(gamepad) = &records[6] else {
            panic!("record 6 is a gamepad");
        };
        assert_eq!(gamepad.pad, 1);
        assert!(gamepad.connected);
        assert_eq!(gamepad.buttons, 0b1011);
        assert_eq!(gamepad.axes[1], -0.2);
        assert_eq!(gamepad.axes[6], -1.0);

        let Record::Ping(ping) = &records[7] else {
            panic!("record 7 is a ping");
        };
        assert_eq!(ping.token, 0xDEAD_BEEF_CAFE);
    }

    #[test]
    fn record_sizes_are_pinned() {
        // The Swift tests' documentedSizes pins these totals (a touch grows
        // by 16 bytes a pointer); text carries no padding. Indexes run over
        // the fixture's order.
        assert_eq!(wire(&golden_records()[0]).len(), 32);
        assert_eq!(wire(&golden_records()[1]).len(), 48);
        assert_eq!(wire(&golden_records()[2]).len(), 28);
        assert_eq!(wire(&golden_records()[3]).len(), 28);
        assert_eq!(wire(&golden_records()[4]).len(), 27);
        assert_eq!(wire(&golden_records()[5]).len(), 28);
        assert_eq!(wire(&golden_records()[6]).len(), 48);
        assert_eq!(wire(&golden_records()[7]).len(), 16);
        // A ping's header names no display: the Mac writes 0 for it
        // (InputRecord.swift's header(.ping, displayID: 0)).
        assert_eq!(&wire(&golden_records()[7])[4..8], &[0, 0, 0, 0]);
    }

    #[test]
    fn the_preamble_is_eight_pinned_bytes() {
        assert_eq!(preamble(INPUT_VERSION), [0x41, 0x56, 0x4F, 0x49, 1, 0, 0, 0]);
        assert_eq!(preamble(0x0102).len(), 8);
        // The lower of the two versions applies — the Mac's
        // preambleNegotiation test has the peer speak 7 and the pair use 1.
        assert_eq!(negotiate(&preamble(7)).unwrap(), 1);
        assert_eq!(negotiate(&preamble(3)).unwrap(), 3.min(INPUT_VERSION));
        // Not the magic, or a peer version below 1: bad preamble (the Mac's
        // negotiate throws badPreamble; the guest ends the session).
        assert_eq!(negotiate(&[1, 2, 3, 4, 1, 0, 0, 0]), Err(Error::BadPreamble));
        assert_eq!(negotiate(&[0x41, 0x56, 0x4F, 0x49, 0, 0, 0, 0]), Err(Error::BadPreamble));
        assert_eq!(negotiate(&[0x41, 0x56]), Err(Error::BadPreamble));
    }

    #[test]
    fn touch_fields_sit_at_the_guests_offsets() {
        let out = wire(&Record::Touch(Touch {
            display_id: 0x0102_0304,
            action: TouchAction::Move,
            action_index: 0,
            pointers: vec![Pointer { id: 9, x: 1.0, y: 2.0, pressure: 1.0 }],
        }));
        assert_eq!(out[0], TYPE_TOUCH);
        assert_eq!(&out[4..8], &[0x04, 0x03, 0x02, 0x01]); // display, little-endian
        assert_eq!(out[8], TouchAction::Move as u8);
        assert_eq!(out[10], 1); // pointer_count
        assert_eq!(&out[16..20], &[9, 0, 0, 0]); // pointer id
        assert_eq!(&out[20..24], &[0x00, 0x00, 0x80, 0x3F]); // 1.0 f32
        // The byte patterns are the Swift tests' touchLayoutIsLittleEndian;
        // dev.avo.bridge.input.InputRecords.java reads pointer i at
        // 16 + i*16, x at +4, y at +8, pressure at +12.
    }

    #[test]
    fn a_key_record_is_twenty_eight_pinned_bytes() {
        // dev.avo.bridge.input.InputRecords.java reads action at 8, keycode
        // at 12, meta_state at 16, repeat at 20 and scancode at 24 — the
        // whole record, matching the fixture's third record.
        let out = wire(&Record::Key(Key {
            display_id: 5,
            action: KeyAction::Down,
            keycode: 111,
            meta_state: 0x1000,
            repeat: 2,
            scancode: 1,
        }));
        assert_eq!(
            out,
            vec![
                0x02, 0x00, 0x1C, 0x00, // header: type, flags, length 28
                0x05, 0x00, 0x00, 0x00, // display_id 5
                0x00, 0x00, 0x00, 0x00, // action 0 down; reserved u8 + u16
                0x6F, 0x00, 0x00, 0x00, // keycode 111 at offset 12
                0x00, 0x10, 0x00, 0x00, // meta_state 0x1000 at offset 16
                0x02, 0x00, 0x00, 0x00, // repeat 2 at offset 20
                0x01, 0x00, 0x00, 0x00, // scancode 1 at offset 24
            ]
        );
    }

    #[test]
    fn text_carries_a_byte_count_and_no_padding() {
        // InputRecords.java's text reads count at 8 and the bytes from 10;
        // the fixture's text record is 27 bytes — an odd length a padded
        // format could not produce.
        let text = wire(&golden_records()[4]);
        assert_eq!(text.len(), 27);
        assert_eq!(&text[8..10], &[0x11, 0x00]); // 17: "Halo, dunia! " (13) + 🥑 (4)
        assert_eq!(&text[10..], "Halo, dunia! 🥑".as_bytes());
    }

    #[test]
    fn unknown_types_are_skipped_by_length() {
        // The unknown record between two good ones is the Swift tests'
        // streamDecoderHandlesSplitsAndSkipsUnknownTypes: type 0x42 with a
        // 12-byte total.
        let mut stream = vec![0x42, 0, 12, 0, 0, 0, 0, 0, 1, 2, 3, 4];
        let scroll = wire(&golden_records()[3]);
        stream.extend_from_slice(&scroll);
        assert_eq!(decode(&stream).unwrap(), Decoded::Skip(12));
        match decode(&stream[12..]).unwrap() {
            Decoded::Record(record, consumed) => {
                assert_eq!(consumed, scroll.len());
                assert_eq!(record, golden_records()[3]);
            }
            other => panic!("the record after the skip must not read as {other:?}"),
        }
    }

    #[test]
    fn a_past_the_cap_or_short_length_is_refused() {
        // A body claimed under the header's own 8 bytes (the Swift tests'
        // rejectsCorruptLength; the guest's "bad input record length 4"
        // ends the session).
        assert_eq!(decode(&[0x01, 0, 4, 0, 0, 0, 0, 0]), Err(Error::BadLength(4)));
        // Past the 1024-byte cap — refused before completeness matters, the
        // way the Mac's recordTooLong fires before its nil-on-incomplete.
        assert_eq!(decode(&[0x01, 0, 0xD0, 0x07, 0, 0, 0, 0]), Err(Error::BadLength(2000)));
    }

    #[test]
    fn too_many_pointers_or_too_long_text_is_refused_at_encode() {
        // The Swift tests' rejectsTooManyPointers: a 17-pointer MOVE. Zero
        // pointers is the same refusal (the Mac's (1...16) range guard).
        let seventeen = (0..17u32).map(|i| Pointer { id: i, x: 0.0, y: 0.0, pressure: 1.0 }).collect();
        let mut out = Vec::new();
        assert_eq!(
            Record::Touch(Touch {
                display_id: 1,
                action: TouchAction::Move,
                action_index: 0,
                pointers: seventeen,
            })
            .encode(&mut out),
            Err(Error::TooManyPointers(17)),
        );
        assert_eq!(
            Record::Touch(Touch {
                display_id: 1,
                action: TouchAction::Down,
                action_index: 0,
                pointers: Vec::new(),
            })
            .encode(&mut out),
            Err(Error::TooManyPointers(0)),
        );
        // The Swift tests' rejectsOversizedText: one byte past MAX_TEXT.
        assert_eq!(
            Record::Text(Text { display_id: 1, text: "a".repeat(MAX_TEXT + 1) }).encode(&mut out),
            Err(Error::TextTooLong(MAX_TEXT + 1)),
        );
        // At the caps themselves a record is still exactly the 1024 bytes
        // the channel allows.
        let mut out = Vec::new();
        let full = Record::Text(Text { display_id: 1, text: "a".repeat(MAX_TEXT) });
        full.encode(&mut out).expect("max text encodes");
        assert_eq!(out.len(), MAX_RECORD);
        let mut out = Vec::new();
        Record::Touch(Touch {
            display_id: 1,
            action: TouchAction::Down,
            action_index: 0,
            pointers: (0..16u32).map(|i| Pointer { id: i, x: 0.0, y: 0.0, pressure: 1.0 }).collect(),
        })
        .encode(&mut out)
        .expect("16 pointers encode");
        assert_eq!(out.len(), 16 + 16 * 16);
    }

    #[test]
    fn a_cut_record_waits_for_its_rest() {
        // The streaming case InputRecordDecoder.next services: bytes short
        // of the header, or of the length the header names, read as
        // `Partial` and the caller waits.
        let touch = wire(&golden_records()[1]); // 48 bytes, two pointers
        for cut in [0, 7, 8, 30, 47] {
            match decode(&touch[..cut]) {
                Ok(Decoded::Partial) => {}
                other => panic!("cut at {cut} must not read as {other:?}"),
            }
        }
        match decode(&touch).expect("the full record decodes") {
            Decoded::Record(record, consumed) => {
                assert_eq!(consumed, touch.len());
                assert_eq!(record, golden_records()[1]);
            }
            other => panic!("the full record must not read as {other:?}"),
        }
    }
}
