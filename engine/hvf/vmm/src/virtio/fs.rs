//! virtio-fs (virtio 1.2 §5.11): a folder on the Mac as a file system in
//! the guest (`mount -t virtiofs <tag> <dir>`), served by server.rs. Queue 0
//! is the high-priority one (FORGET, INTERRUPT), queue 1 the requests: the
//! request's header and arguments in its device-readable buffers, the reply
//! in its device-writable ones. No DAX window and no notifications; the
//! guest's caches expire instead (server.rs).

pub mod server;

use super::queue::{Chain, Queue};
use super::{Active, Interrupt, VirtioDevice};
use crate::memory::GuestMemory;
use server::SharedDir;
use std::sync::Arc;

pub const TYPE_FS: u16 = 26;
/// The mount's source in the guest (36 bytes at most).
pub const TAG: &str = "avo_shared";
/// Room for a whole MAX_TRANSFER read or write in one request.
const QUEUE_SIZE: u16 = 1024;

pub struct Fs {
    server: SharedDir,
    active: Option<Active>,
}

impl Fs {
    pub fn new(server: SharedDir) -> Fs {
        Fs { server, active: None }
    }

    fn serve(server: &mut SharedDir, memory: &GuestMemory, chain: &Chain) -> u32 {
        let Some(request) = chain.read_all(memory) else { return 0 };
        match server.handle(&request) {
            Some(reply) => chain.write_all(memory, &reply) as u32,
            None => 0,
        }
    }
}

impl VirtioDevice for Fs {
    fn device_type(&self) -> u16 {
        TYPE_FS
    }

    fn features(&self) -> u64 {
        0
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![128, QUEUE_SIZE]
    }

    /// `virtio_fs_config`: the tag, one request queue, no notification buffer.
    fn config(&self) -> Vec<u8> {
        let mut config = vec![0u8; 44];
        config[..TAG.len()].copy_from_slice(TAG.as_bytes());
        config[36..40].copy_from_slice(&1u32.to_le_bytes());
        config
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        self.active = Some(Active { memory, queues, interrupt });
    }

    fn notify(&mut self, queue: usize) {
        let Some(active) = self.active.as_mut() else { return };
        if queue >= active.queues.len() {
            return;
        }
        while let Some(chain) = active.queues[queue].pop(&active.memory) {
            let written = Self::serve(&mut self.server, &active.memory, &chain);
            active.complete(queue, chain.head, written);
        }
    }

    fn reset(&mut self) {
        // A guest reboot: what it had open is gone.
        self.active = None;
        if let Ok(fresh) = SharedDir::new(self.server.root()) {
            self.server = fresh;
        }
    }

    fn pci_class(&self) -> u32 {
        0x01_8000 // mass storage, other
    }
}
