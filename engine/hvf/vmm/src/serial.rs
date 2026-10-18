//! Simple platform devices: a PL011 UART (kernel console) and a PL031 RTC.

use crate::bus::MmioHandler;
use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

fn le(value: u32, data: &mut [u8]) {
    let bytes = value.to_le_bytes();
    let n = data.len().min(4);
    data[..n].copy_from_slice(&bytes[..n]);
}

fn from_le(data: &[u8]) -> u32 {
    let mut bytes = [0u8; 4];
    let n = data.len().min(4);
    bytes[..n].copy_from_slice(&data[..n]);
    u32::from_le_bytes(bytes)
}

/// Output-only PL011: enough for earlycon and the console driver's polled writes.
pub struct Pl011 {
    out: Mutex<Box<dyn Write + Send>>,
}

impl Pl011 {
    pub fn new(out: Box<dyn Write + Send>) -> Pl011 {
        Pl011 { out: Mutex::new(out) }
    }
}

impl MmioHandler for Pl011 {
    fn read(&self, offset: u64, data: &mut [u8]) {
        let value = match offset {
            0x018 => 0x90, // UARTFR: transmit FIFO empty, receive FIFO empty
            0xfe0 => 0x11,
            0xfe4 => 0x10,
            0xfe8 => 0x34,
            0xfec => 0x00,
            0xff0 => 0x0d,
            0xff4 => 0xf0,
            0xff8 => 0x05,
            0xffc => 0xb1,
            _ => 0,
        };
        le(value, data);
    }

    fn write(&self, offset: u64, data: &[u8]) {
        if offset == 0 {
            let mut out = self.out.lock().unwrap();
            let _ = out.write_all(&data[..1]);
            if data[0] == b'\n' {
                let _ = out.flush();
            }
        }
    }
}

/// PL031 real-time clock, seconds since the epoch from the host clock.
pub struct Pl031 {
    offset: Mutex<i64>,
}

impl Default for Pl031 {
    fn default() -> Pl031 {
        Pl031 { offset: Mutex::new(0) }
    }
}

impl Pl031 {
    fn now() -> i64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
    }
}

impl MmioHandler for Pl031 {
    fn read(&self, offset: u64, data: &mut [u8]) {
        let value = match offset {
            0x00 => (Pl031::now() + *self.offset.lock().unwrap()) as u32, // RTCDR
            0x0c => 1,                                                     // RTCCR: started
            0xfe0 => 0x31,
            0xfe4 => 0x10,
            0xfe8 => 0x14,
            0xfec => 0x00,
            0xff0 => 0x0d,
            0xff4 => 0xf0,
            0xff8 => 0x05,
            0xffc => 0xb1,
            _ => 0,
        };
        le(value, data);
    }

    fn write(&self, offset: u64, data: &[u8]) {
        if offset == 0x08 {
            // RTCLR: the guest sets the time.
            *self.offset.lock().unwrap() = from_le(data) as i64 - Pl031::now();
        }
    }
}
