//! virtio-blk (virtio 1.2 §5.2) over a [`Disk`].

use super::queue::{Chain, Queue};
use super::{Active, Interrupt, TYPE_BLOCK, VirtioDevice};
use crate::disk::{Disk, SECTOR};
use crate::memory::GuestMemory;
use std::sync::Arc;

const F_SEG_MAX: u64 = 1 << 2;
const F_RO: u64 = 1 << 5;
const F_BLK_SIZE: u64 = 1 << 6;
const F_FLUSH: u64 = 1 << 9;

const T_IN: u32 = 0;
const T_OUT: u32 = 1;
const T_FLUSH: u32 = 4;
const T_GET_ID: u32 = 8;

const S_OK: u8 = 0;
const S_IOERR: u8 = 1;
const S_UNSUPP: u8 = 2;

const SEG_MAX: u32 = 126;

/// Reads and writes go between guest memory and the disk through a buffer
/// of at most this many bytes: their lengths are the guest's. Real requests
/// are far smaller (Linux sends at most 1280 KiB by default) and still take
/// one disk call.
const CHUNK: usize = 16 << 20;

pub struct Block {
    disk: Box<dyn Disk>,
    id: String,
    active: Option<Active>,
}

impl Block {
    pub fn new(disk: Box<dyn Disk>, id: &str) -> Block {
        Block { disk, id: id.to_string(), active: None }
    }

    /// The byte offset of `len` bytes at `sector`, if all of them are on
    /// the disk. Both come from the guest, so nothing here may wrap.
    fn extent(&self, sector: u64, len: usize) -> Option<u64> {
        let offset = sector.checked_mul(SECTOR)?;
        let end = offset.checked_add(len as u64)?;
        (end <= self.disk.size()).then_some(offset)
    }

    fn handle(&self, memory: &GuestMemory, chain: &Chain) -> u32 {
        // Layout: 16-byte header (readable), data, 1-byte status (writable, last).
        let Some(status) = chain.descriptors.last().filter(|d| d.write && d.len >= 1).copied() else {
            return 0;
        };
        // Saturates where it would wrap, to an address no write accepts.
        let status_address = status.address.saturating_add(status.len as u64 - 1);
        let mut header = [0u8; 16];
        let readable: Vec<_> = chain.readable().copied().collect();
        if !read_bytes(memory, &readable, 0, &mut header) {
            memory.write(status_address, &[S_IOERR]);
            return 1;
        }
        let kind = u32::from_le_bytes(header[0..4].try_into().unwrap());
        let sector = u64::from_le_bytes(header[8..16].try_into().unwrap());

        // Data buffers: writable ones before the status byte, or readable ones after the header.
        let mut data_in: Vec<(u64, usize)> = Vec::new();
        for (i, d) in chain.descriptors.iter().enumerate() {
            if d.write {
                let last = i == chain.descriptors.len() - 1;
                let len = if last { d.len as usize - 1 } else { d.len as usize };
                if len > 0 {
                    data_in.push((d.address, len));
                }
            }
        }

        let (code, written) = match kind {
            T_IN => {
                let total: usize = data_in.iter().map(|(_, l)| l).sum();
                match self.extent(sector, total) {
                    None => (S_IOERR, 0),
                    Some(offset) => {
                        let mut buffer = vec![0u8; total.min(CHUNK)];
                        let mut done = 0;
                        loop {
                            let n = (total - done).min(CHUNK);
                            if self.disk.read_at(&mut buffer[..n], offset + done as u64).is_err() {
                                break (S_IOERR, 0);
                            }
                            write_bytes(memory, &data_in, done, &buffer[..n]);
                            done += n;
                            if done == total {
                                break (S_OK, total as u32);
                            }
                        }
                    }
                }
            }
            T_OUT => {
                let total = chain.readable_len().saturating_sub(16);
                // All of it must be RAM before the first chunk reaches the
                // disk: a bad request fails whole, as when it was one piece.
                let in_ram = readable.iter().all(|d| memory.host_ptr(d.address, d.len as usize).is_some());
                match self.extent(sector, total) {
                    Some(offset) if in_ram && !self.disk.read_only() => {
                        let mut buffer = vec![0u8; total.min(CHUNK)];
                        let mut done = 0;
                        loop {
                            let n = (total - done).min(CHUNK);
                            if !read_bytes(memory, &readable, 16 + done, &mut buffer[..n])
                                || self.disk.write_at(&buffer[..n], offset + done as u64).is_err()
                            {
                                break (S_IOERR, 0);
                            }
                            done += n;
                            if done == total {
                                break (S_OK, 0);
                            }
                        }
                    }
                    _ => (S_IOERR, 0),
                }
            }
            T_FLUSH => match self.disk.flush() {
                Ok(()) => (S_OK, 0),
                Err(_) => (S_IOERR, 0),
            },
            T_GET_ID => {
                let mut id = [0u8; 20];
                let bytes = self.id.as_bytes();
                id[..bytes.len().min(20)].copy_from_slice(&bytes[..bytes.len().min(20)]);
                let mut at = 0;
                for (address, len) in &data_in {
                    let n = (*len).min(20 - at);
                    memory.write(*address, &id[at..at + n]);
                    at += n;
                    if at == 20 {
                        break;
                    }
                }
                (S_OK, at as u32)
            }
            _ => (S_UNSUPP, 0),
        };
        memory.write(status_address, &[code]);
        written + 1
    }
}

/// Copies bytes starting `skip` bytes into the readable buffers.
fn read_bytes(memory: &GuestMemory, buffers: &[super::queue::Descriptor], skip: usize, out: &mut [u8]) -> bool {
    let mut position = 0usize;
    let mut filled = 0usize;
    for d in buffers {
        let len = d.len as usize;
        if position + len <= skip {
            position += len;
            continue;
        }
        let start = skip.saturating_sub(position);
        let take = (len - start).min(out.len() - filled);
        let Some(address) = d.address.checked_add(start as u64) else { return false };
        if !memory.read(address, &mut out[filled..filled + take]) {
            return false;
        }
        filled += take;
        position += len;
        if filled == out.len() {
            return true;
        }
    }
    filled == out.len()
}

/// Copies `data` into the writable buffers, starting `skip` bytes into them.
fn write_bytes(memory: &GuestMemory, buffers: &[(u64, usize)], skip: usize, data: &[u8]) {
    let mut position = 0usize;
    let mut written = 0usize;
    for &(address, len) in buffers {
        if written == data.len() {
            return;
        }
        if position + len <= skip {
            position += len;
            continue;
        }
        let start = skip.saturating_sub(position);
        let take = (len - start).min(data.len() - written);
        memory.write(address.saturating_add(start as u64), &data[written..written + take]);
        written += take;
        position += len;
    }
}

impl VirtioDevice for Block {
    fn device_type(&self) -> u16 {
        TYPE_BLOCK
    }

    fn features(&self) -> u64 {
        F_SEG_MAX | F_BLK_SIZE | F_FLUSH | if self.disk.read_only() { F_RO } else { 0 }
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![256]
    }

    fn config(&self) -> Vec<u8> {
        let mut config = vec![0u8; 60];
        config[0..8].copy_from_slice(&(self.disk.size() / SECTOR).to_le_bytes());
        config[12..16].copy_from_slice(&SEG_MAX.to_le_bytes());
        config[20..24].copy_from_slice(&(SECTOR as u32).to_le_bytes());
        config
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        self.active = Some(Active { memory, queues, interrupt });
    }

    fn notify(&mut self, _queue: usize) {
        let Some(mut active) = self.active.take() else { return };
        while let Some(chain) = active.queues[0].pop(&active.memory) {
            let len = self.handle(&active.memory, &chain);
            active.complete(0, chain.head, len);
        }
        self.active = Some(active);
    }

    fn reset(&mut self) {
        self.active = None;
    }

    fn pci_class(&self) -> u32 {
        0x01_8000 // mass storage, other
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::virtio::queue::Descriptor;
    use hv::GuestRegion;
    use std::sync::Mutex;

    const RAM: u64 = 0x8000_0000;

    /// A disk of `size` bytes, the first of them in `bytes` (the rest read
    /// as zeros), that keeps every read and write reaching it.
    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Recorded>>);

    #[derive(Default)]
    struct Recorded {
        size: u64,
        bytes: Vec<u8>,
        /// (write, offset, length)
        calls: Vec<(bool, u64, usize)>,
    }

    impl Disk for Recorder {
        fn size(&self) -> u64 {
            self.0.lock().unwrap().size
        }
        fn read_only(&self) -> bool {
            false
        }
        fn read_at(&self, buf: &mut [u8], offset: u64) -> std::io::Result<()> {
            let mut disk = self.0.lock().unwrap();
            disk.calls.push((false, offset, buf.len()));
            buf.fill(0);
            let start = (offset as usize).min(disk.bytes.len());
            let end = (start + buf.len()).min(disk.bytes.len());
            buf[..end - start].copy_from_slice(&disk.bytes[start..end]);
            Ok(())
        }
        fn write_at(&self, buf: &[u8], offset: u64) -> std::io::Result<()> {
            let mut disk = self.0.lock().unwrap();
            disk.calls.push((true, offset, buf.len()));
            let start = (offset as usize).min(disk.bytes.len());
            let end = (start + buf.len()).min(disk.bytes.len());
            disk.bytes[start..end].copy_from_slice(&buf[..end - start]);
            Ok(())
        }
        fn flush(&self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn device(size: u64, bytes: Vec<u8>) -> (Block, Recorder, GuestMemory) {
        let disk = Recorder::default();
        *disk.0.lock().unwrap() = Recorded { size, bytes, calls: Vec::new() };
        let memory = GuestMemory::new(GuestRegion::new(RAM, 1 << 20).unwrap());
        (Block::new(Box::new(disk.clone()), "test"), disk, memory)
    }

    fn readable(address: u64, len: u32) -> Descriptor {
        Descriptor { address, len, write: false }
    }

    fn writable(address: u64, len: u32) -> Descriptor {
        Descriptor { address, len, write: true }
    }

    /// Runs one request (header at RAM, status at RAM + 16); its status and
    /// the length the device reports.
    fn run(block: &Block, memory: &GuestMemory, kind: u32, sector: u64, data: Vec<Descriptor>) -> (u8, u32) {
        let mut header = [0u8; 16];
        header[0..4].copy_from_slice(&kind.to_le_bytes());
        header[8..16].copy_from_slice(&sector.to_le_bytes());
        memory.write(RAM, &header);
        let mut descriptors = vec![readable(RAM, 16)];
        descriptors.extend(data);
        descriptors.push(writable(RAM + 16, 1));
        let len = block.handle(memory, &Chain { head: 0, descriptors });
        let mut status = [0xff];
        memory.read(RAM + 16, &mut status);
        (status[0], len)
    }

    #[test]
    fn reads_and_writes_on_the_disk_take_one_call_each() {
        let (block, disk, memory) = device(64 << 10, (0..64 << 10).map(|i| (i / 512) as u8).collect());
        assert_eq!(run(&block, &memory, T_IN, 2, vec![writable(RAM + 0x1000, 1000), writable(RAM + 0x2000, 24)]), (S_OK, 1025));
        let mut data = [0u8; 1024];
        memory.read(RAM + 0x1000, &mut data[..1000]);
        memory.read(RAM + 0x2000, &mut data[1000..]);
        assert_eq!(data[..], disk.0.lock().unwrap().bytes[1024..2048]);

        memory.write(RAM + 0x3000, &[0xab; 512]);
        assert_eq!(run(&block, &memory, T_OUT, 4, vec![readable(RAM + 0x3000, 512)]), (S_OK, 1));
        let disk = disk.0.lock().unwrap();
        assert_eq!(disk.bytes[2048..2560], [0xab; 512]);
        assert_eq!(disk.calls, [(false, 1024, 1024), (true, 2048, 512)]);
    }

    #[test]
    fn requests_that_do_not_fit_the_disk_fail_without_reaching_it() {
        let (block, disk, memory) = device(64 << 10, vec![0; 64 << 10]);
        let huge = || vec![writable(RAM, u32::MAX), writable(RAM, u32::MAX)];
        let cases = [
            (T_IN, 0, huge(), "a huge length"),
            (T_OUT, 0, vec![readable(RAM + 0x1000, u32::MAX)], "a huge length"),
            (T_IN, u64::MAX / SECTOR + 1, vec![writable(RAM + 0x1000, 512)], "the sector's offset overflows"),
            (T_OUT, u64::MAX / SECTOR, vec![readable(RAM + 0x1000, 1024)], "the end overflows"),
            (T_IN, 127, vec![writable(RAM + 0x1000, 1024)], "past the end"),
            (T_OUT, 128, vec![readable(RAM + 0x1000, 512)], "past the end"),
        ];
        for (kind, sector, data, why) in cases {
            assert_eq!(run(&block, &memory, kind, sector, data), (S_IOERR, 1), "{why}");
        }
        assert!(disk.0.lock().unwrap().calls.is_empty());
        // The last sector is still on the disk.
        assert_eq!(run(&block, &memory, T_IN, 127, vec![writable(RAM + 0x1000, 512)]), (S_OK, 513));
    }

    #[test]
    fn a_request_larger_than_a_chunk_goes_through_in_chunks() {
        // 40 MiB on a large disk, from 1 MiB of RAM named again and again.
        let (block, disk, memory) = device(1 << 40, Vec::new());
        let total = 40 << 20;
        assert_eq!(run(&block, &memory, T_IN, 8, vec![writable(RAM, 1 << 20); 40]), (S_OK, total as u32 + 1));
        assert_eq!(run(&block, &memory, T_OUT, 8, vec![readable(RAM, 1 << 20); 40]), (S_OK, 1));
        for write in [false, true] {
            let calls: Vec<_> = disk.0.lock().unwrap().calls.iter().filter(|c| c.0 == write).copied().collect();
            assert_eq!(calls.len(), 3);
            assert!(calls.iter().all(|&(_, _, len)| len <= CHUNK));
            assert_eq!(calls.iter().map(|c| c.2).sum::<usize>(), total);
            assert_eq!(calls[0].1, 8 * SECTOR);
            assert!(calls.windows(2).all(|w| w[0].1 + w[0].2 as u64 == w[1].1), "in order, end to end");
        }
    }
}
