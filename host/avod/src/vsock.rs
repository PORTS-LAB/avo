//! The engine's vsock, as the daemon sees it: the runtime directory's
//! `vsock.sock`, in the Firecracker hybrid-vsock convention — a Unix socket
//! per VM whose streams name the guest's vsock port before going raw
//! (docs/protocol.md; the engine's half is virtio/vsock.rs in the engine
//! tree, whose handshake this mirrors exactly).
//!
//! Every channel is one of these: the daemon connects to the guest's ADB
//! (5555, the raw ADB wire protocol), control (6000, protobuf envelopes) and
//! input (6001, fixed-layout records).

use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

/// The runtime directory's socket.
pub struct Vsock {
    path: PathBuf,
}

/// One guest port's connection, past the handshake: the bytes are the raw
/// vsock stream from here on.
#[derive(Debug)]
pub struct VsockStream {
    inner: UnixStream,
    /// What the engine assigned the connection (its `OK` line's port).
    host_port: u32,
}

impl Vsock {
    /// The runtime directory's `vsock.sock`.
    pub fn at(path: impl AsRef<Path>) -> Vsock {
        Vsock { path: path.as_ref().to_path_buf() }
    }

    /// Host side: opens the engine's connection to the guest's vsock port
    /// `port` — writes `CONNECT`, consumes the `OK` line, and leaves the
    /// stream raw for the channel's own protocol.
    pub fn connect_to(&self, port: u32) -> std::io::Result<VsockStream> {
        let mut stream = UnixStream::connect(&self.path)?;
        stream.write_all(format!("CONNECT {port}\n").as_bytes())?;
        match read_line(&mut stream)? {
            Some(line) if line.starts_with("OK ") => {
                let host_port = line[3..]
                    .trim()
                    .parse()
                    .map_err(|_| io_error(ErrorKind::InvalidData, "the engine's OK line does not name a port"))?;
                Ok(VsockStream { inner: stream, host_port })
            }
            Some(line) if line.starts_with("ERROR ") => {
                let reason = line["ERROR ".len()..].trim();
                if reason == "connection refused" {
                    Err(io_error(ErrorKind::ConnectionRefused, "the engine refused the connection"))
                } else {
                    Err(io_error(ErrorKind::InvalidData, reason)) // bad request, and the rest
                }
            }
            Some(line) => Err(io_error(ErrorKind::InvalidData, format!("expected CONNECT's answer, got {line:?}"))),
            None => Err(io_error(ErrorKind::ConnectionAborted, "the engine closed before answering")),
        }
    }
}

/// Reads a newline-terminated line, at most 256 bytes of it, as UTF-8.
fn read_line(stream: &mut UnixStream) -> std::io::Result<Option<String>> {
    let mut line = Vec::new();
    loop {
        if line.len() >= 256 {
            return Err(io_error(ErrorKind::InvalidData, "the engine's handshake line is unreasonably long"));
        }
        let mut byte = [0u8; 1];
        stream.read_exact(&mut byte)?;
        line.push(byte[0]);
        if byte[0] == b'\n' {
            break;
        }
    }
    if line.is_empty() {
        return Ok(None);
    }
    let line = std::str::from_utf8(&line)
        .map_err(|_| io_error(ErrorKind::InvalidData, "the engine's handshake is not UTF-8"))?
        .to_string();
    Ok(Some(line))
}

fn io_error(error: ErrorKind, text: impl AsRef<str>) -> std::io::Error {
    std::io::Error::new(error, text.as_ref())
}

impl VsockStream {
    /// The engine's assigned host port for the connection.
    pub fn host_port(&self) -> u32 {
        self.host_port
    }

    /// The raw stream this wraps.
    pub fn into_inner(self) -> UnixStream {
        self.inner
    }
}

impl Read for VsockStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl Write for VsockStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::sync::mpsc;

    /// One newline-terminated line, at most 64 bytes, or nothing at EOF.
    fn line(stream: &mut UnixStream) -> Option<String> {
        let mut line = Vec::new();
        loop {
            if line.len() >= 64 {
                break;
            }
            let mut byte = [0u8; 1];
            match stream.read_exact(&mut byte) {
                Ok(_) => line.push(byte[0]),
                Err(_) => break,
            }
            if byte[0] == b'\n' {
                break;
            }
        }
        if line.is_empty() {
            return None;
        }
        Some(String::from_utf8_lossy(&line).into_owned())
    }

    /// A stand-in for the engine's socket-device half: one connection
    /// handled on its own thread; lines are answered with `answer` (an
    /// `OK`/`ERROR` line) and the next raw line is captured.
    fn engine(answer: &'static str, raw_answers: &[&'static str]) -> (Vsock, mpsc::Receiver<String>) {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "avod-vsock-{}-{}.sock",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let listener = UnixListener::bind(&path).unwrap();
        let answers = raw_answers.to_vec();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let mut stream = listener.incoming().next().unwrap().unwrap();
            let _ = sender.send(line(&mut stream).unwrap_or_default());
            stream.write_all(answer.as_bytes()).unwrap();
            // The client's first raw line after the handshake (nothing, when
            // it got an error and left) — the thread stays on the stream
            // until then, so a successful handshake's payload is not cut by
            // the server dropping out.
            let _ = sender.send(line(&mut stream).unwrap_or_default());
            for answer in answers {
                let _ = line(&mut stream);
                if !answer.is_empty() {
                    let _ = stream.write_all(answer.as_bytes());
                }
            }
        });
        (Vsock { path }, receiver)
    }

    #[test]
    fn a_connect_names_the_port_and_then_the_stream_is_raw() {
        let (vsock, got) = engine("OK 1024\n", &[]);
        let mut stream = vsock.connect_to(5555).unwrap();
        assert_eq!(stream.host_port(), 1024);
        stream.write_all("adb wire goes here\n".as_bytes()).unwrap();
        assert_eq!(got.recv_timeout(std::time::Duration::from_secs(5)).unwrap(), "CONNECT 5555\n");
        assert_eq!(got.recv_timeout(std::time::Duration::from_secs(5)).unwrap(), "adb wire goes here\n");
    }

    #[test]
    fn a_refusal_is_complete_refusal() {
        let (vsock, _) = engine("ERROR connection refused\n", &[]);
        let error = vsock.connect_to(6000).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::ConnectionRefused);
    }

    #[test]
    fn anything_else_is_a_protocol_offence() {
        let (vsock, _) = engine("ERROR bad request\n", &[]);
        let error = vsock.connect_to(6000).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidData);
        assert!(error.to_string().contains("bad request"));
    }
}
