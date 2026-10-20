//! virtio-rng: entropy from the host's CSPRNG (arc4random on the Mac,
//! getrandom elsewhere).

use super::queue::Queue;
use super::{Active, Interrupt, TYPE_RNG, VirtioDevice};
use crate::memory::GuestMemory;
use std::sync::Arc;

/// Fills the bytes with the host's entropy: arc4random on the Mac,
/// getrandom(2) elsewhere (the kernel's own pool, no fd to open).
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn arc4random_buf(buf: *mut u8, nbytes: usize);
}

#[cfg(target_os = "macos")]
fn fill(buf: &mut [u8]) {
    unsafe { arc4random_buf(buf.as_mut_ptr(), buf.len()) };
}

#[cfg(not(target_os = "macos"))]
fn fill(buf: &mut [u8]) {
    let mut done = 0;
    while done < buf.len() {
        let n = unsafe { libc::getrandom(buf[done..].as_mut_ptr().cast(), buf.len() - done, 0) };
        if n >= 0 {
            done += n as usize;
        } else if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        } else {
            // No getrandom syscall (kernel < 3.17): read the urandom file.
            use std::io::Read;
            let mut file = std::fs::File::open("/dev/urandom").expect("no entropy source on this host");
            file.read_exact(&mut buf[done..]).expect("/dev/urandom returned short");
            return;
        }
    }
}

#[derive(Default)]
pub struct Rng {
    active: Option<Active>,
}

impl VirtioDevice for Rng {
    fn device_type(&self) -> u16 {
        TYPE_RNG
    }

    fn features(&self) -> u64 {
        0
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![64]
    }

    fn config(&self) -> Vec<u8> {
        Vec::new()
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        self.active = Some(Active { memory, queues, interrupt });
    }

    fn notify(&mut self, _queue: usize) {
        let Some(active) = self.active.as_mut() else { return };
        while let Some(chain) = active.queues[0].pop(&active.memory) {
            let mut bytes = vec![0u8; chain.writable_len().min(64 * 1024)];
            fill(&mut bytes);
            let written = chain.write_all(&active.memory, &bytes);
            active.complete(0, chain.head, written as u32);
        }
    }

    fn reset(&mut self) {
        self.active = None;
    }
}
