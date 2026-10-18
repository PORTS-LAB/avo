//! virtio-console with a single port (one device per `/dev/hvcN`, like
//! crosvm's `--serial hardware=virtio-console`).

use super::queue::Queue;
use super::{Active, Interrupt, TYPE_CONSOLE, VirtioDevice};
use crate::memory::GuestMemory;
use std::collections::VecDeque;
use std::io::Write;
use std::sync::{Arc, Mutex};

const RX: usize = 0;
const TX: usize = 1;

/// Where guest output goes.
pub type Sink = Box<dyn Write + Send>;

struct Shared {
    active: Option<Active>,
    /// Host input waiting for receive buffers.
    pending: VecDeque<u8>,
}

/// Cloneable handle that feeds host input to the guest side of the port.
#[derive(Clone)]
pub struct ConsoleInput(Arc<Mutex<Shared>>);

impl ConsoleInput {
    pub fn send(&self, bytes: &[u8]) {
        let mut shared = self.0.lock().unwrap();
        shared.pending.extend(bytes);
        Console::fill_receive(&mut shared);
    }
}

pub struct Console {
    shared: Arc<Mutex<Shared>>,
    sink: Option<Sink>,
}

impl Console {
    /// `sink` receives everything the guest writes; None drops it.
    pub fn new(sink: Option<Sink>) -> Console {
        Console { shared: Arc::new(Mutex::new(Shared { active: None, pending: VecDeque::new() })), sink }
    }

    pub fn input(&self) -> ConsoleInput {
        ConsoleInput(self.shared.clone())
    }

    fn fill_receive(shared: &mut Shared) {
        let Shared { active, pending } = shared;
        let Some(active) = active.as_mut() else { return };
        let mut delivered = false;
        while !pending.is_empty() {
            let Some(chain) = active.queues[RX].pop(&active.memory) else { break };
            let room = chain.writable_len();
            let take = room.min(pending.len());
            let bytes: Vec<u8> = pending.drain(..take).collect();
            let written = chain.write_all(&active.memory, &bytes);
            active.queues[RX].add_used(&active.memory, chain.head, written as u32);
            delivered = true;
        }
        if delivered {
            active.interrupt.signal_queue();
        }
    }

    fn drain_transmit(&mut self) {
        // Collect under the lock, write after releasing it: a sink may answer
        // through this console's own input (the sensors port does).
        let mut output = Vec::new();
        {
            let mut shared = self.shared.lock().unwrap();
            let Some(active) = shared.active.as_mut() else { return };
            let mut done = false;
            while let Some(chain) = active.queues[TX].pop(&active.memory) {
                if self.sink.is_some() {
                    if let Some(bytes) = chain.read_all(&active.memory) {
                        output.extend_from_slice(&bytes);
                    }
                }
                active.queues[TX].add_used(&active.memory, chain.head, 0);
                done = true;
            }
            if done && active.queues[TX].wants_interrupt(&active.memory) {
                active.interrupt.signal_queue();
            }
        }
        if let Some(sink) = self.sink.as_mut() {
            if !output.is_empty() {
                let _ = sink.write_all(&output);
                let _ = sink.flush();
            }
        }
    }
}

impl VirtioDevice for Console {
    fn device_type(&self) -> u16 {
        TYPE_CONSOLE
    }

    fn features(&self) -> u64 {
        0
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![256, 256]
    }

    fn config(&self) -> Vec<u8> {
        // cols, rows, max_nr_ports, emerg_wr: unused without their features.
        vec![0; 12]
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        let mut shared = self.shared.lock().unwrap();
        shared.active = Some(Active { memory, queues, interrupt });
        Console::fill_receive(&mut shared);
    }

    fn notify(&mut self, queue: usize) {
        match queue {
            TX => self.drain_transmit(),
            RX => Console::fill_receive(&mut self.shared.lock().unwrap()),
            _ => {}
        }
    }

    fn reset(&mut self) {
        self.shared.lock().unwrap().active = None;
    }

    fn pci_class(&self) -> u32 {
        0x07_8000 // simple communication controller, other
    }
}
