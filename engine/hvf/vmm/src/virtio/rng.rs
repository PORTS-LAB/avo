//! virtio-rng: entropy from the host's arc4random.

use super::queue::Queue;
use super::{Active, Interrupt, TYPE_RNG, VirtioDevice};
use crate::memory::GuestMemory;
use std::sync::Arc;

unsafe extern "C" {
    fn arc4random_buf(buf: *mut u8, nbytes: usize);
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
            unsafe { arc4random_buf(bytes.as_mut_ptr(), bytes.len()) };
            let written = chain.write_all(&active.memory, &bytes);
            active.complete(0, chain.head, written as u32);
        }
    }

    fn reset(&mut self) {
        self.active = None;
    }
}
