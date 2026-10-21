//! The daemon's ADB client (AvoKit's AvoADB — ADBConnection.swift,
//! ADBMessage.swift, ADBServices.swift), spoken to adbd over the engine's
//! hybrid vsock on port 5555 (docs/protocol.md's ADB row). Framing: a
//! 24-byte header — command, arg0, arg1, payload length, a payload byte
//! sum only peers older than protocol 0x01000001 check, the command's bits
//! flipped — then the payload. One WRTE awaits its OKAY before the next
//! (classic flow control; `delayed_ack` deliberately unadvertised — it
//! switches adbd to windowing this client does not implement). The
//! handshake: CNXN out, then — if adbd is secure — an AUTH token back, the
//! key's signature back, when refused even that the public key in
//! Android's mincrypt encoding, then the real CNXN (adbkey.rs holds the
//! key and the encoding). Services, one at a time (v1): `shell,v2,raw:` —
//! separate stdout/stderr streams and an exit status as 1-byte records —
//! `exec:` for raw stdin/stdout (`install-write -` counts its stated `-S`
//! bytes rather than waiting for EOF, so no end-of-stdin signal exists),
//! and the `pm install-create/write/commit` session (ADBServices.swift:143
//! -172) that one APK rides whole.

use crate::adbkey::Key;
use crate::vsock::Vsock;
use std::io::{Read, Write};
use std::path::Path;

/// adbd's vsock port (docs/protocol.md's ADB row).
pub const ADB_PORT: u32 = 5555;

/// Protocol version with checksums skipped (ADBMessage.swift:44).
const VERSION: u32 = 0x0100_0001;
/// The largest payload we send; the peer's CNXN may lower it.
const MAX_PAYLOAD: u32 = 256 * 1024;
/// The largest payload we accept (ADBMessageDecoder.swift:92's cap).
const IN_MAX_PAYLOAD: u32 = 1024 * 1024;
const HEADER: usize = 24;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum Command {
    Connect = 0x4E58_4E43, // CNXN
    Auth = 0x4854_5541,    // AUTH
    Open = 0x4E45_504F,    // OPEN
    Okay = 0x5941_4B4F,    // OKAY
    Close = 0x4553_4C43,   // CLSE
    Write = 0x4554_5257,   // WRTE
}

impl Command {
    fn from(raw: u32) -> Option<Self> {
        Some(match raw {
            0x4E58_4E43 => Command::Connect,
            0x4854_5541 => Command::Auth,
            0x4E45_504F => Command::Open,
            0x5941_4B4F => Command::Okay,
            0x4553_4C43 => Command::Close,
            0x4554_5257 => Command::Write,
            _ => return None,
        })
    }
}

/// One ADB transport message (ADBMessage.swift:11-80).
#[derive(Clone)]
pub struct Message {
    pub command: Command,
    pub arg0: u32,
    pub arg1: u32,
    pub payload: Vec<u8>,
}

impl Message {
    pub fn new(command: Command, arg0: u32, arg1: u32, payload: Vec<u8>) -> Self {
        Self { command, arg0, arg1, payload }
    }

    /// The 24-byte header — command, arg0, arg1, length, sum (a plain byte
    /// sum, sent zero above protocol 0x01000000), the flipped command —
    /// then the payload (ADBMessage.swift:56-74).
    pub fn encoded(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER + self.payload.len());
        for word in [
            self.command as u32,
            self.arg0,
            self.arg1,
            self.payload.len() as u32,
            0,
            (self.command as u32) ^ 0xFFFF_FFFF,
        ] {
            out.extend(word.to_le_bytes());
        }
        out.extend(self.payload.iter());
        out
    }

    fn word(bytes: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(bytes[at * 4..at * 4 + 4].try_into().expect("a header word"))
    }

    /// One message off a blocking stream, whole or nothing.
    pub fn read(stream: &mut impl Read) -> Result<Self, AdbError> {
        let mut header = [0u8; HEADER];
        stream.read_exact(&mut header).map_err(|_| AdbError::Closed)?;
        let raw = Self::word(&header, 0);
        if Self::word(&header, 5) != raw ^ 0xFFFF_FFFF {
            return Err(AdbError::BadMagic);
        }
        let Some(command) = Command::from(raw) else {
            return Err(AdbError::Unknown(raw));
        };
        let length = Self::word(&header, 3);
        if length > IN_MAX_PAYLOAD {
            return Err(AdbError::TooLarge(length));
        }
        let mut payload = vec![0u8; length as usize];
        stream.read_exact(&mut payload).map_err(|_| AdbError::Closed)?;
        Ok(Message { command, arg0: Self::word(&header, 1), arg1: Self::word(&header, 2), payload })
    }

    pub fn write(&self, stream: &mut impl Write) -> Result<(), AdbError> {
        stream.write_all(&self.encoded()).map_err(AdbError::Io)
    }
}

impl std::fmt::Debug for Message {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        out.debug_struct("Message")
            .field("command", &self.command)
            .field("arg0", &self.arg0)
            .field("arg1", &self.arg1)
            .field("payload", &self.payload.len())
            .finish()
    }
}

#[derive(Debug)]
pub enum AdbError {
    Io(std::io::Error),
    /// The header's magic did not check — corrupt transport.
    BadMagic,
    /// A command the protocol does not say.
    Unknown(u32),
    /// A payload past what this client accepts.
    TooLarge(u32),
    /// adbd asked a third time: the key is not the guest's.
    Rejected,
    /// The transport ended.
    Closed,
    /// Anything out of the grammar's place, worded.
    Unexpected(String),
}

impl std::fmt::Display for AdbError {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(what) => write!(out, "{what}"),
            Self::BadMagic => write!(out, "corrupt ADB message"),
            Self::Unknown(raw) => write!(out, "unknown ADB command {raw:#x}"),
            Self::TooLarge(length) => write!(out, "ADB payload of {length} bytes is too large"),
            Self::Rejected => write!(out, "adbd rejected the key"),
            Self::Closed => write!(out, "ADB connection closed"),
            Self::Unexpected(what) => write!(out, "unexpected ADB message: {what}"),
        }
    }
}

impl std::error::Error for AdbError {}

/// One shell run's whole output. Exit codes ride the shell v2 record 3 as
/// one byte; 255 stands in when the record is empty (ADBConnection.swift).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl ShellResult {
    pub fn success(&self) -> bool {
        self.exit_code == 0
    }

    /// The words the device said, trimmed — the failure wording
    /// (ADBServices.swift:189-196).
    pub fn words(&self) -> String {
        let joined = format!("{}{}", self.stdout, self.stderr);
        let trimmed = joined.trim();
        if trimmed.is_empty() {
            format!("exit {exit}", exit = self.exit_code)
        } else {
            trimmed.to_string()
        }
    }
}

/// What the pump brought back: one stream's data, the acknowledgment of
/// our own write, or the stream's end.
enum Pump {
    Data(Vec<u8>),
    Ready,
    Closed,
}

/// One connection to adbd, handshake whole, services one at a time. Holds
/// nothing but the socket — each `connect` dials its own fresh one, the
/// relay's per-accept shape.
pub struct Client<'k> {
    stream: std::os::unix::net::UnixStream,
    key: &'k Key,
    max_payload: u32,
    next_local: u32,
    /// The stream while a service is out: (our local id, its remote id).
    open: Option<(u32, u32)>,
}

impl<'k> Client<'k> {
    /// Connects through the engine's vsock (`CONNECT 5555` / `OK`), then
    /// the CNXN/AUTH dance: our CNXN out, then — if adbd runs secure — the
    /// token, our signature, and if even that is refused our public key in
    /// Android's encoding, then the final CNXN (ADBConnection.swift:59-69,
    /// 141-158). One connection per client; `runtime` is the runtime
    /// directory whose `vsock.sock` the engine hosts the guest's ports on.
    pub fn connect(runtime: &Path, key: &'k Key) -> Result<Self, AdbError> {
        let stream = Vsock::at(runtime.join("vsock.sock"))
            .connect_to(ADB_PORT)
            .map_err(AdbError::Io)?
            .into_inner();
        let mut client = Client { stream, key, max_payload: MAX_PAYLOAD, next_local: 1, open: None };
        client.handshake()?;
        Ok(client)
    }

    fn handshake(&mut self) -> Result<(), AdbError> {
        let banner = format!("host::features={}", HOST_FEATURES.join(","));
        self.message(Message::new(Command::Connect, VERSION, MAX_PAYLOAD, banner.into_bytes()))?;
        let mut signature = false;
        let mut public = false;
        loop {
            let message = Message::read(&mut self.stream)?;
            match (message.command, message.arg0) {
                (Command::Auth, 1) => {
                    // The token: sign it. A second token asks for the public
                    // key; a third means the guest does not carry the key
                    // (ADBConnection.swift:147-158).
                    if !signature {
                        let signature_bytes =
                            self.key.sign_token(&message.payload).map_err(|_| AdbError::Rejected)?;
                        self.message(Message::new(Command::Auth, 2, 0, signature_bytes))?;
                        signature = true;
                    } else if !public {
                        let mut line = self
                            .key
                            .android_pubkey("avo-daemon")
                            .map_err(|_| AdbError::Rejected)?
                            .into_bytes();
                        line.push(0);
                        self.message(Message::new(Command::Auth, 3, 0, line))?;
                        public = true;
                    } else {
                        return Err(AdbError::Rejected);
                    }
                }
                (Command::Connect, _) => {
                    self.max_payload = message.arg1.min(MAX_PAYLOAD);
                    return Ok(());
                }
                _ => {
                    return Err(AdbError::Unexpected(format!(
                        "{message:?} in the handshake"
                    )))
                }
            }
        }
    }

    fn message(&mut self, message: Message) -> Result<(), AdbError> {
        message.write(&mut self.stream)
    }

    /// Opens one service; answers (our local id, the device's remote id).
    /// The service string rides NUL-terminated.
    fn open_service(&mut self, service: &str) -> Result<(u32, u32), AdbError> {
        if self.open.is_some() {
            self.close_stream()?;
        }
        let local = self.next_local;
        self.next_local = self.next_local.wrapping_add(1);
        self.message(Message::new(Command::Open, local, 0, {
            let mut payload = service.as_bytes().to_vec();
            payload.push(0);
            payload
        }))?;
        loop {
            let message = Message::read(&mut self.stream)?;
            match (message.command, message.arg1) {
                (Command::Okay, id) if id == local => return Ok((local, message.arg0)),
                (Command::Close, id) if id == local => {
                    return Err(AdbError::Unexpected(format!("adbd refused {service}")));
                }
                _ => return Err(AdbError::Unexpected(format!("{message:?} on open"))),
            }
        }
    }

    /// One inbound message for `local`'s stream, replies baked in: the
    /// device's WRTE gets answered OKAY and its payload returns; our
    /// write's OKAY returns Ready; the stream's end returns Closed.
    fn pump(&mut self, local: u32) -> Result<Pump, AdbError> {
        loop {
            let message = Message::read(&mut self.stream)?;
            match message.command {
                Command::Write if message.arg1 == local => {
                    self.message(Message::new(Command::Okay, local, message.arg0, Vec::new()))?;
                    return Ok(Pump::Data(message.payload));
                }
                Command::Okay if message.arg1 == local => return Ok(Pump::Ready),
                Command::Close if message.arg1 == local => return Ok(Pump::Closed),
                _ => return Err(AdbError::Unexpected(format!("{message:?} on a stream"))),
            }
        }
    }

    /// Streams `data` in peer-sized WRTEs, each awaiting its own OKAY
    /// (ADBConnection.swift:224-241). Whatever the device writes back
    /// while we are still streaming lands in `sink` — `exec:` children can
    /// start talking before all the input has crossed.
    fn stream_write(&mut self, local: u32, remote: u32, data: &[u8], sink: &mut Vec<u8>) -> Result<(), AdbError> {
        for chunk in data.chunks(self.max_payload as usize) {
            self.message(Message::new(Command::Write, local, remote, chunk.to_vec()))?;
            match self.pump(local)? {
                Pump::Ready => {}
                Pump::Closed => return Err(AdbError::Closed),
                Pump::Data(payload) => sink.extend(payload),
            }
        }
        Ok(())
    }

    /// Ends the stream: our CLSE, best effort. Clears nothing when the
    /// device already closed — the caller clears it then.
    pub fn close_stream(&mut self) -> Result<(), AdbError> {
        if let Some((local, remote)) = self.open.take() {
            self.message(Message::new(Command::Close, local, remote, Vec::new()))?;
        }
        Ok(())
    }

    /// Runs a command with the shell v2 raw protocol: records of a 1-byte
    /// id, a 4-byte length, the payload — 1 stdout, 2 stderr, 3 exit.
    pub fn shell(&mut self, command: &str) -> Result<ShellResult, AdbError> {
        let service = format!("shell,v2,raw:{command}");
        let (local, remote) = self.open_service(&service)?;
        self.open = Some((local, remote));
        let mut records: Vec<u8> = Vec::new();
        loop {
            match self.pump(local)? {
                Pump::Data(data) => records.extend(data),
                Pump::Ready => {}
                Pump::Closed => {
                    // The device ended the stream: ours is already gone.
                    self.open = None;
                    break;
                }
            }
        }
        let (stdout, stderr, exit) = frame_shell_v2(&records);
        let exit = exit.ok_or_else(|| {
            AdbError::Unexpected(format!("{command}: the stream closed without an exit status"))
        })?;
        Ok(ShellResult {
            exit_code: exit,
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
        })
    }

    /// Runs `command` with the raw `exec:` service, streaming `input` as
    /// stdin and taking everything the child wrote. The child ends itself —
    /// `install-write -S` counts its stated bytes rather than waiting for
    /// an EOF — and the device's CLSE closes the read.
    pub fn exec(&mut self, command: &str, input: &[u8]) -> Result<Vec<u8>, AdbError> {
        let service = format!("exec:{command}");
        let (local, remote) = self.open_service(&service)?;
        self.open = Some((local, remote));
        let mut early = Vec::new();
        self.stream_write(local, remote, input, &mut early)?;
        let mut out = early;
        loop {
            match self.pump(local)? {
                Pump::Data(data) => out.extend(data),
                Pump::Ready => {}
                Pump::Closed => {
                    // The child ended itself: the device closed the stream.
                    self.open = None;
                    break;
                }
            }
        }
        Ok(out)
    }

    /// Installs one APK the way ADBServices.swift:143-172 wraps them:
    /// `pm install-create`, the APK streamed through `cmd package
    /// install-write` on exec stdin (name quoted), `pm install-commit` —
    /// abandoning the session on any failure. Answers the session's words
    /// on success; the failing side's words on failure.
    pub fn install(&mut self, apk_path: &Path) -> Result<String, String> {
        let apk = std::fs::read(apk_path).map_err(|what| what.to_string())?;
        let create = match self.shell(&format!("pm install-create -r -S {}", apk.len())) {
            Ok(result) => result,
            Err(what) => return Err(what.to_string()),
        };
        if !create.success() {
            return Err(create.words());
        }
        let Some(session) = session_id(&create.stdout) else {
            return Err(create.words());
        };
        let name = apk_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "apk".to_string());
        match self.exec(
            &format!(
                "cmd package install-write -S {} {} {} -",
                apk.len(),
                session,
                shell_quote(&name)
            ),
            &apk,
        ) {
            Ok(bytes) if String::from_utf8_lossy(&bytes).contains("Success") => {}
            Ok(bytes) => {
                let _ = self.shell(&format!("pm install-abandon {session}"));
                return Err(String::from_utf8_lossy(&bytes).trim().to_string());
            }
            Err(what) => {
                let _ = self.shell(&format!("pm install-abandon {session}"));
                return Err(what.to_string());
            }
        }
        let commit = match self.shell(&format!("pm install-commit {session}")) {
            Ok(result) => result,
            Err(what) => return Err(what.to_string()),
        };
        if commit.success() && commit.stdout.contains("Success") {
            Ok(commit.words())
        } else {
            Err(commit.words())
        }
    }
}

impl Drop for Client<'_> {
    fn drop(&mut self) {
        let _ = self.close_stream();
    }
}

/// The protocol-1 features (ADBConnection.swift:22) — the banner's reason
/// `shell,v2,raw:` parses at all: adbd's feature gate.
const HOST_FEATURES: &[&str] =
    &["shell_v2", "cmd", "stat_v2", "ls_v2", "fixed_push_mkdir", "abb_exec", "abb"];

/// Splits the shell v2 raw records: 1 stdout, 2 stderr, 3 exit (the exit
/// code as one byte; 255 stands in on an empty record). The records ride
/// in order; a partial trailing record is dropped.
fn frame_shell_v2(records: &[u8]) -> (Vec<u8>, Vec<u8>, Option<i32>) {
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut exit = None;
    let mut cursor = records;
    while cursor.len() >= 5 {
        let id = cursor[0];
        let length =
            u32::from_le_bytes(cursor[1..5].try_into().expect("a record length")) as usize;
        if cursor.len() < 5 + length {
            break;
        }
        let payload = &cursor[5..5 + length];
        match id {
            1 => stdout.extend(payload),
            2 => stderr.extend(payload),
            3 => exit = Some(i32::from(payload.first().copied().unwrap_or(255))),
            _ => {}
        }
        cursor = &cursor[5 + length..];
    }
    (stdout, stderr, exit)
}

/// "Success: created install session [1234567]" -> "1234567"
/// (ADBServices.swift:175-180).
fn session_id(output: &str) -> Option<&str> {
    let open = output.find('[')?;
    let end = open + output[open..].find(']')?;
    output
        .as_bytes()
        .get(open + 1..end)?
        .iter()
        .all(|byte| byte.is_ascii_digit())
        .then(|| &output[open + 1..end])
        .filter(|word| !word.is_empty())
}

/// Single-quotes an argument for the device shell
/// (ADBServices.swift:197-199).
pub fn shell_quote(argument: &str) -> String {
    format!("'{}'", argument.replace('\'', "'\\''"))
}

#[cfg(test)]
pub mod fake {
    //! The fake adbd the tests speak to — the same dances, scripted: the
    //! hybrid vsock's `CONNECT 5555`, our AUTH token, the client's
    //! signature verified against a real public half, the final CNXN, then
    //! services answered through a canned closure: shell services get the
    //! words framed as shell v2 records plus an exit status, exec services
    //! swallow the stdin until the child's stated `-S` bytes crossed
    //! before answering. The body test rides in through `serve_connection`
    //! on its own guest fake.

    use super::*;
    use rsa::pkcs1v15::Pkcs1v15Sign;
    use rsa::RsaPublicKey;
    use sha1::Sha1;
    use std::os::unix::net::UnixStream;

    /// One full dance on a fresh socket: the client's CNXN intro, our AUTH
    /// token, the signature verified, our final CNXN, then every OPEN's
    /// service answered through `canned` until the socket dies. Only the
    /// signature check is real; `canned` decides the words.
    pub fn serve_connection(
        stream: &mut UnixStream,
        public: &RsaPublicKey,
        canned: &dyn Fn(&str) -> (&str, i32),
    ) {
        if handshake(stream, public).is_err() {
            return;
        }
        loop {
            let open = match Message::read(stream) {
                Ok(m) => m,
                Err(_) => return,
            };
            if open.command != Command::Open || serve_service(stream, &open, canned).is_err() {
                return;
            }
        }
    }

    fn handshake(stream: &mut UnixStream, public: &RsaPublicKey) -> Result<(), AdbError> {
        Message::read(stream)?;
        let token = [9u8; 20];
        Message::write(&Message::new(Command::Auth, 1, 0, token.to_vec()), stream)?;
        let answer = Message::read(stream)?;
        if answer.command != Command::Auth || answer.arg0 != 2 {
            return Err(AdbError::Unexpected("no AUTH signature".into()));
        }
        if public
            .verify(Pkcs1v15Sign::new::<Sha1>(), &token, &answer.payload)
            .is_err()
        {
            return Err(AdbError::Rejected);
        }
        Message::write(
            &Message::new(Command::Connect, VERSION, MAX_PAYLOAD, b"device::ro.build.version.release=14\x00\x00\x00".to_vec()),
            stream,
        )
    }

    fn serve_service(
        stream: &mut UnixStream,
        open: &Message,
        canned: &dyn Fn(&str) -> (&str, i32),
    ) -> Result<(), AdbError> {
        let payload_len = open.payload.len().saturating_sub(1);
        let service = String::from_utf8_lossy(&open.payload[..payload_len]).into_owned();
        let local = open.arg0;
        let remote: u32 = 0x7777;
        Message::write(&Message::new(Command::Okay, remote, local, Vec::new()), stream)?;

        let (words, exit) = canned(&service);
        let code = exit.clamp(0, 255) as u8;
        match service.split_once(':') {
            Some(("shell,v2,raw", _)) => {
                let mut records = record(1, words.as_bytes());
                records.extend(record(3, &[code]));
                wrte_then_okay(stream, local, remote, records)?;
                Message::write(&Message::new(Command::Close, remote, local, Vec::new()), stream)
            }
            _ => {
                swallow_stdin(stream, remote, stated_size(&service))?;
                if !words.is_empty() {
                    wrte_then_okay(stream, local, remote, words.as_bytes().to_vec())?;
                }
                Message::write(&Message::new(Command::Close, remote, local, Vec::new()), stream)
            }
        }
    }

    /// Our WRTE, awaiting the client's OKAY.
    fn wrte_then_okay(
        stream: &mut UnixStream,
        local: u32,
        remote: u32,
        payload: Vec<u8>,
    ) -> Result<(), AdbError> {
        Message::write(&Message::new(Command::Write, remote, local, payload), stream)?;
        loop {
            let message = Message::read(stream)?;
            match message.command {
                Command::Okay if message.arg1 == remote => return Ok(()),
                _ => return Err(AdbError::Unexpected("no OKAY on the fake's write".into())),
            }
        }
    }

    /// The client's stdin WRTEs, each answered OKAY, counted against the
    /// child's stated `-S` bytes — the real install-write's own arithmetic
    /// (it exits once it has them, without needing an EOF). No `-S`, no
    /// stdin worth swallowing. Host→device messages carry the device's id
    /// in arg1 (adb's own convention, ADBConnection.swift:224-249).
    fn swallow_stdin(
        stream: &mut UnixStream,
        remote: u32,
        stated: Option<usize>,
    ) -> Result<(), AdbError> {
        let Some(size) = stated else { return Ok(()) };
        let mut received = 0usize;
        while received < size {
            let message = Message::read(stream)?;
            match message.command {
                Command::Write if message.arg1 == remote => {
                    received += message.payload.len();
                    Message::write(
                        &Message::new(Command::Okay, remote, message.arg0, Vec::new()),
                        stream,
                    )?;
                }
                Command::Close if message.arg1 == remote => return Ok(()),
                _ => return Err(AdbError::Unexpected("stdin ended oddly".into())),
            }
        }
        Ok(())
    }

    fn stated_size(service: &str) -> Option<usize> {
        let at = service.find("-S ")?;
        let rest = &service[at + 3..];
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        digits.parse().ok()
    }

    fn record(id: u8, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![id];
        out.extend((payload.len() as u32).to_le_bytes());
        out.extend(payload);
        out
    }
}

#[cfg(test)]
mod tests {
use super::fake::serve_connection;
use super::*;
use rsa::RsaPublicKey;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};

    /// Binds `dir/vsock.sock`, speaks the hybrid vsock's `CONNECT 5555`,
    /// then hands each socket to the fake's `serve_connection`.
    fn serve_adb(dir: &Path, public: RsaPublicKey, canned: Arc<dyn Fn(&str) -> (&str, i32) + Send + Sync>) {
        // Bind on the test's own thread — a connect before the spawn's
        // first instruction would meet a socket file with no listener
        // behind it, and the refused code lies about the cause.
        let path = dir.join("vsock.sock");
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).expect("the fake's socket");
        std::thread::spawn(move || loop {
            let Ok((mut stream, _)) = listener.accept() else { break };
            stream.set_read_timeout(Some(std::time::Duration::from_secs(2))).ok();
            let Some(line) = read_line(&mut stream) else { break };
            if !line.starts_with("CONNECT 5555") {
                continue;
            }
            let _ = stream.write_all(b"OK 1\n");
            serve_connection(&mut stream, &public, canned.as_ref());
        });
    }

    fn read_line(stream: &mut UnixStream) -> Option<String> {
        let mut line = Vec::new();
        let mut byte = [0u8; 1];
        while stream.read(&mut byte).ok()? == 1 {
            if byte[0] == b'\n' {
                break;
            }
            line.push(byte[0]);
        }
        (!line.is_empty()).then(|| String::from_utf8_lossy(&line).into_owned())
    }

    /// Connect and shell whole against the fake, the fake having verified
    /// the signature against the daemon's real key — handshake, flow
    /// control, records, exit codes, a second shell on the same client.
    #[test]
    fn the_client_shells_the_fake_whole() {
        let dir = fresh_dir("adbc-shell");
        let key = crate::adbkey::Key::load_or_create(dir.join(crate::adbkey::KEY_FILE)).unwrap();
        serve_adb(
            &dir,
            key.public(),
            Arc::new(|service| {
                if service.contains("pm list packages com.avo") {
                    ("package:com.avo.notes", 0)
                } else {
                    ("", 7)
                }
            }),
        );
        let mut client = Client::connect(&dir, &key).expect("connects");
        let result = client.shell("pm list packages com.avo").expect("shells");
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout, "package:com.avo.notes");
        let result = client.shell("pm list packages no.more").expect("shells again");
        assert_eq!(result.exit_code, 7, "the exit code rides");
        assert_eq!(result.stdout, "");
        drop(client);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The install session: create, the APK bytes streamed on exec stdin —
    /// the fake counts them against the stated `-S` — commit, the name
    /// quoted, the create's size stated.
    #[test]
    fn the_client_installs_through_the_session() {
        let dir = fresh_dir("adbc-install");
        let key = crate::adbkey::Key::load_or_create(dir.join(crate::adbkey::KEY_FILE)).unwrap();
        let apk = dir.join("app.apk");
        std::fs::write(&apk, vec![7u8; 1234]).unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let seen_for_fake = Arc::clone(&seen);
        serve_adb(
            &dir,
            key.public(),
            Arc::new(move |service| {
                seen_for_fake.lock().unwrap().push(service.to_string());
                if service.contains("install-create") {
                    ("Success: created install session [42]", 0)
                } else if service.contains("install-write") {
                    ("Success", 0)
                } else if service.contains("install-commit") {
                    ("Success", 0)
                } else {
                    ("", 1)
                }
            }),
        );
        let mut client = Client::connect(&dir, &key).expect("connects");
        let words = client.install(&apk).expect("installs");
        assert_eq!(words, "Success");
        let what = seen.lock().unwrap();
        assert!(what[0].contains("install-create"), "{}", what[0]);
        assert!(what[0].contains("-S 1234"), "the size stated: {}", what[0]);
        assert!(what[1].contains("install-write"), "{}", what[1]);
        assert!(what[1].contains(" 'app.apk'"), "the name quoted: {}", what[1]);
        assert!(what[2].contains("install-commit"), "{}", what[2]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The handshake's security holds: a key the guest does not carry
    /// fails the fake's verify, the fake hangs up, and the client's
    /// connect — whose signature leg never completes — comes back closed.
    #[test]
    fn a_strangers_key_is_rejected() {
        let dir = fresh_dir("adbc-refuse");
        let key = crate::adbkey::Key::load_or_create(dir.join(crate::adbkey::KEY_FILE)).unwrap();
        let stranger_dir = fresh_dir("adbc-stranger");
        let stranger = crate::adbkey::Key::load_or_create(stranger_dir.join(crate::adbkey::KEY_FILE)).unwrap();
        serve_adb(&dir, stranger.public(), Arc::new(|_| ("", 0)));
        match Client::connect(&dir, &key).map(|client| {
            drop(client);
        }) {
            Err(AdbError::Closed) => {}
            other => panic!("the fake hung up on a stranger's signature: {other:?}"),
        }
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&stranger_dir);
    }

    /// The shell v2 framer: the records arrive as id+len+payload, the
    /// exit code rides as one byte, and a trailing partial record — a
    /// threaded length with no payload yet — is dropped.
    #[test]
    fn the_shell_v2_records_frame() {
        let stdout_record = {
            let mut out = vec![1u8];
            out.extend(5u32.to_le_bytes());
            out.extend(b"hello");
            out
        };
        let mut with_exit = stdout_record.clone();
        with_exit.extend([3u8, 1, 0, 0, 0, 0]);
        with_exit.extend([2u8, 2, 0, 0, 0]);
        assert_eq!(
            frame_shell_v2(&with_exit),
            (b"hello".to_vec(), Vec::new(), Some(0)),
            "the full stream frames, the partial record dropped"
        );
        assert_eq!(frame_shell_v2(&stdout_record).2, None, "no exit record, no exit");
    }

    /// The session id's parser: the digits between the brackets only.
    #[test]
    fn the_session_id_parses() {
        assert_eq!(session_id("Success: created install session [1234567]\n"), Some("1234567"));
        assert_eq!(session_id("Success: created install session [42]"), Some("42"));
        assert_eq!(session_id("no session here"), None);
        assert_eq!(session_id("session []"), None);
        assert_eq!(session_id("words [1a2] in it"), None, "digits only");
    }

    /// The quoting: adb's own single-quote dialect.
    #[test]
    fn the_shell_quote_holds() {
        assert_eq!(shell_quote("com.avo.notes"), "'com.avo.notes'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }

    fn fresh_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "adbc-{name}-{}-{:?}",
            std::process::id(),
            std::time::Instant::now()
        ));
        let _ = std::fs::create_dir_all(&dir);
        dir
    }
}
