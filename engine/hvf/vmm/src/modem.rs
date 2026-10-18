//! A modem with no SIM card for Cuttlefish's radio HAL
//! (android.hardware.radio-service.cuttlefish), which speaks AT commands to
//! Cuttlefish's host modem simulator over vsock and exits without one. With
//! no radio HAL, Android's phone process waits for it at every start, is
//! killed for not responding and starts again, all the time. This one
//! answers the way a modem with no SIM inserted and no network does, so
//! telephony settles on "No SIM" and the device behaves like a Wi-Fi-only
//! phone.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

/// The vsock port the radio HAL dials (androidboot.modem_simulator_ports).
pub const PORT: u32 = 9600;

/// Answers modem connections from the guest on `path`, the vsock device's
/// socket for guest connections to [`PORT`]. Once per process: the modem
/// keeps nothing between boots, and a listener made again at every guest
/// reboot would leave the last one's thread waiting on a socket nobody
/// reaches.
pub fn serve(path: &Path) -> Result<(), String> {
    static SERVING: AtomicBool = AtomicBool::new(false);
    if SERVING.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path).map_err(|e| format!("modem: {}: {e}", path.display()))?;
    std::thread::Builder::new()
        .name("avo-modem".into())
        .spawn(move || {
            for stream in listener.incoming().flatten() {
                let _ = std::thread::Builder::new().name("avo-modem-session".into()).spawn(move || session(stream));
            }
        })
        .map_err(|e| format!("modem: {e}"))?;
    Ok(())
}

fn session(stream: UnixStream) {
    let Ok(reader) = stream.try_clone() else { return };
    let mut reader = BufReader::new(reader);
    let mut writer = stream;
    let mut modem = Modem { powered: false };
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\r', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let command = String::from_utf8_lossy(&line);
        let command = command.trim_matches(|c: char| c.is_whitespace() || c == '\0');
        if command.is_empty() {
            continue;
        }
        if writer.write_all(modem.answer(command).as_bytes()).is_err() {
            return;
        }
    }
}

struct Modem {
    powered: bool,
}

impl Modem {
    fn answer(&mut self, command: &str) -> String {
        let ok = |lines: &[String]| lines.iter().map(|l| format!("{l}\r\n")).collect::<String>() + "OK\r\n";
        let upper = command.to_ascii_uppercase();
        // SIM-related commands: there is no SIM (27.007 CME error 10).
        const SIM: [&str; 8] = ["AT+CPIN", "AT+CIMI", "AT+CRSM", "AT+CSIM", "AT+CNUM", "AT+CCHO", "AT+CGLA", "AT+CLCK"];
        if SIM.iter().any(|prefix| upper.starts_with(prefix)) {
            return "+CME ERROR: 10\r\n".into();
        }
        match upper.as_str() {
            "AT+CFUN?" => ok(&[format!("+CFUN: {}", self.powered as u8)]),
            "AT+CREG?" => ok(&["+CREG: 2,0".into()]),
            "AT+CGREG?" => ok(&["+CGREG: 2,0".into()]),
            "AT+CEREG?" => ok(&["+CEREG: 2,0".into()]),
            "AT+COPS?" => ok(&["+COPS: 0".into()]),
            "AT+CSQ" => ok(&["+CSQ: 99,99".into()]),
            // No IMEI or serial to give: an empty modem has none worth inventing.
            "AT+CGSN" | "AT+CGMI" | "AT+CGMM" | "AT+CGMR" => "+CME ERROR: 4\r\n".into(),
            _ => {
                if let Some(value) = upper.strip_prefix("AT+CFUN=") {
                    self.powered = value.split(',').next().is_some_and(|v| v.trim() != "0");
                }
                ok(&[])
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_like_a_modem_without_a_sim() {
        let mut modem = Modem { powered: false };
        assert_eq!(modem.answer("ATE0Q0V1"), "OK\r\n");
        assert_eq!(modem.answer("AT+CPIN?"), "+CME ERROR: 10\r\n");
        assert_eq!(modem.answer("AT+CFUN?"), "+CFUN: 0\r\nOK\r\n");
        assert_eq!(modem.answer("AT+CFUN=1"), "OK\r\n");
        assert_eq!(modem.answer("at+cfun?"), "+CFUN: 1\r\nOK\r\n");
        assert_eq!(modem.answer("AT+CREG?"), "+CREG: 2,0\r\nOK\r\n");
    }
}
