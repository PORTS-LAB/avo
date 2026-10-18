//! virtio-net (virtio 1.2 §5.1) with one receive and one transmit queue and
//! the MAC and link status in the configuration space. Frames the guest sends
//! go to the port's uplink (the user-mode network in net.rs); frames for the
//! guest come back through its [`Downlink`]. A port without an uplink reports
//! no carrier, so Android leaves its interface down.

use super::queue::Queue;
use super::{Active, Interrupt, VirtioDevice};
use crate::memory::GuestMemory;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

pub const TYPE_NET: u16 = 1;

const F_MAC: u64 = 1 << 5;
const F_STATUS: u64 = 1 << 16;
const S_LINK_UP: u16 = 1;

/// `struct virtio_net_hdr` with `num_buffers` (always there with VERSION_1).
const HEADER: usize = 12;
const RX: usize = 0;
const TX: usize = 1;
/// Frames that wait for receive buffers before newer ones are dropped
/// (TCP sends them again).
const MAX_PENDING: usize = 2048;

/// Where the guest's frames go.
pub type Uplink = Box<dyn Fn(Vec<Vec<u8>>) + Send>;

struct Shared {
    active: Option<Active>,
    pending: VecDeque<Vec<u8>>,
}

/// Cloneable handle that hands frames to the guest.
#[derive(Clone)]
pub struct Downlink(Arc<Mutex<Shared>>);

impl Downlink {
    pub fn deliver(&self, frames: impl IntoIterator<Item = Vec<u8>>) {
        let mut shared = self.0.lock().unwrap();
        for frame in frames {
            if shared.pending.len() == MAX_PENDING {
                shared.pending.pop_front();
            }
            shared.pending.push_back(frame);
        }
        Net::fill_receive(&mut shared);
    }
}

pub struct Net {
    mac: [u8; 6],
    shared: Arc<Mutex<Shared>>,
    uplink: Option<Uplink>,
}

impl Net {
    pub fn new(mac: [u8; 6]) -> Net {
        Net { mac, shared: Arc::new(Mutex::new(Shared { active: None, pending: VecDeque::new() })), uplink: None }
    }

    pub fn downlink(&self) -> Downlink {
        Downlink(self.shared.clone())
    }

    /// Connects the port: the guest sees a carrier and its frames go to `uplink`.
    pub fn connect(&mut self, uplink: Uplink) {
        self.uplink = Some(uplink);
    }

    fn fill_receive(shared: &mut Shared) {
        let Shared { active, pending } = shared;
        let Some(active) = active.as_mut() else { return };
        let mut delivered = false;
        while let Some(frame) = pending.front() {
            let Some(chain) = active.queues[RX].pop(&active.memory) else { break };
            let mut packet = Vec::with_capacity(HEADER + frame.len());
            packet.extend_from_slice(&[0; 10]);
            packet.extend_from_slice(&1u16.to_le_bytes()); // num_buffers
            packet.extend_from_slice(frame);
            // A buffer too small for the frame goes back empty; the driver drops it.
            let written = if chain.writable_len() >= packet.len() { chain.write_all(&active.memory, &packet) } else { 0 };
            active.queues[RX].add_used(&active.memory, chain.head, written as u32);
            pending.pop_front();
            delivered = true;
        }
        if delivered && active.queues[RX].wants_interrupt(&active.memory) {
            active.interrupt.signal_queue();
        }
    }

    fn drain_transmit(&mut self) {
        let mut frames = Vec::new();
        {
            let mut shared = self.shared.lock().unwrap();
            let Some(active) = shared.active.as_mut() else { return };
            let mut done = false;
            while let Some(chain) = active.queues[TX].pop(&active.memory) {
                if self.uplink.is_some() {
                    if let Some(bytes) = chain.read_all(&active.memory) {
                        if bytes.len() > HEADER {
                            frames.push(bytes[HEADER..].to_vec());
                        }
                    }
                }
                active.queues[TX].add_used(&active.memory, chain.head, 0);
                done = true;
            }
            if done && active.queues[TX].wants_interrupt(&active.memory) {
                active.interrupt.signal_queue();
            }
        }
        if let Some(uplink) = &self.uplink {
            if !frames.is_empty() {
                uplink(frames);
            }
        }
    }
}

impl VirtioDevice for Net {
    fn device_type(&self) -> u16 {
        TYPE_NET
    }

    fn features(&self) -> u64 {
        F_MAC | F_STATUS
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![256, 256]
    }

    fn config(&self) -> Vec<u8> {
        let mut config = self.mac.to_vec();
        let status = if self.uplink.is_some() { S_LINK_UP } else { 0 };
        config.extend_from_slice(&status.to_le_bytes());
        config.extend_from_slice(&1u16.to_le_bytes()); // max_virtqueue_pairs
        config.extend_from_slice(&1500u16.to_le_bytes()); // mtu
        config
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        let mut shared = self.shared.lock().unwrap();
        shared.pending.clear();
        shared.active = Some(Active { memory, queues, interrupt });
    }

    fn notify(&mut self, queue: usize) {
        match queue {
            TX => self.drain_transmit(),
            RX => Net::fill_receive(&mut self.shared.lock().unwrap()),
            _ => {}
        }
    }

    fn reset(&mut self) {
        let mut shared = self.shared.lock().unwrap();
        shared.active = None;
        shared.pending.clear();
    }

    fn pci_class(&self) -> u32 {
        0x02_0000 // network controller, Ethernet
    }
}
