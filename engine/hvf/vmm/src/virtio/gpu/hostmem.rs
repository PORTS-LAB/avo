//! Host-visible GPU memory (GPU mode): the virtio-gpu shared memory region
//! (BAR 2, shmid 1) where blobs the renderer allocated on the Mac show up
//! in the guest. RESOURCE_MAP_BLOB puts a blob's host pages at an offset of
//! the region with hv_vm_map, synchronously, before the guest hears back,
//! so the guest never touches the range before it is backed.
//!
//! Everything is in whole host pages (16 KiB): gfxstream tells the guest
//! to align blobs to 16 KiB (capset blobAlignment), and a map that is not
//! aligned, or would reach past its blob or the region, is refused and
//! counted rather than rounded.

use std::collections::BTreeMap;

pub const PAGE: u64 = 16384;

/// Puts host memory into guest physical space (the VM, or a test recorder).
pub trait Mapper: Send {
    fn map(&mut self, host: usize, guest: u64, len: u64) -> Result<(), String>;
    fn unmap(&mut self, guest: u64, len: u64) -> Result<(), String>;
}

/// The process's VM.
pub struct Hvf;

impl Mapper for Hvf {
    fn map(&mut self, host: usize, guest: u64, len: u64) -> Result<(), String> {
        // SAFETY: the renderer keeps the blob's memory until its resource is
        // unreferenced, and `HostVisible` unmaps it before that (render.rs).
        unsafe { hv::map_host(host as *mut u8, guest, len as usize, hv::Protection::RW) }.map_err(|e| e.to_string())
    }

    fn unmap(&mut self, guest: u64, len: u64) -> Result<(), String> {
        hv::unmap(guest, len as usize).map_err(|e| e.to_string())
    }
}

#[derive(Debug, Clone, Copy)]
struct Map {
    len: u64,
    host: usize,
    resource: u32,
}

#[derive(Debug, PartialEq, Eq)]
pub enum MapError {
    /// The guest has not placed the BAR (or turned decoding off).
    NoBase,
    Misaligned,
    OutOfRange,
    Overlap,
    AlreadyMapped,
    Failed(String),
}

pub struct HostVisible<M: Mapper> {
    pub size: u64,
    base: Option<u64>,
    /// By offset in the region.
    maps: BTreeMap<u64, Map>,
    mapper: M,
    /// Maps refused since start.
    pub rejected: u64,
}

impl<M: Mapper> HostVisible<M> {
    pub fn new(size: u64, mapper: M) -> HostVisible<M> {
        HostVisible { size, base: None, maps: BTreeMap::new(), mapper, rejected: 0 }
    }

    #[cfg(test)]
    pub fn count(&self) -> usize {
        self.maps.len()
    }

    pub fn mapped_bytes(&self) -> u64 {
        self.maps.values().map(|m| m.len).sum()
    }

    /// Maps `len` bytes of host memory at `host` for `resource` at `offset`.
    pub fn map(&mut self, resource: u32, offset: u64, host: usize, len: u64) -> Result<(), MapError> {
        let result = self.try_map(resource, offset, host, len);
        if result.is_err() {
            self.rejected += 1;
        }
        result
    }

    fn try_map(&mut self, resource: u32, offset: u64, host: usize, len: u64) -> Result<(), MapError> {
        let base = self.base.ok_or(MapError::NoBase)?;
        if len == 0 || offset % PAGE != 0 || host as u64 % PAGE != 0 || len % PAGE != 0 {
            return Err(MapError::Misaligned);
        }
        let end = offset.checked_add(len).filter(|&end| end <= self.size).ok_or(MapError::OutOfRange)?;
        if self.maps.values().any(|m| m.resource == resource) {
            return Err(MapError::AlreadyMapped);
        }
        // Maps never overlap, so only the last one starting before `end` can.
        if let Some((&start, map)) = self.maps.range(..end).next_back()
            && start + map.len > offset
        {
            return Err(MapError::Overlap);
        }
        self.mapper.map(host, base + offset, len).map_err(MapError::Failed)?;
        self.maps.insert(offset, Map { len, host, resource });
        Ok(())
    }

    /// Takes `resource`'s blob out of the region; false if it had none.
    pub fn unmap(&mut self, resource: u32) -> bool {
        let Some((&offset, _)) = self.maps.iter().find(|(_, m)| m.resource == resource) else { return false };
        let map = self.maps.remove(&offset).unwrap();
        if let Some(base) = self.base {
            let _ = self.mapper.unmap(base + offset, map.len);
        }
        true
    }

    /// The guest moved the BAR: every blob moves with it (or waits, unmapped,
    /// while there is no base).
    pub fn rebase(&mut self, base: Option<u64>) {
        if base == self.base {
            return;
        }
        if let Some(old) = self.base {
            for (offset, map) in &self.maps {
                let _ = self.mapper.unmap(old + offset, map.len);
            }
        }
        self.base = base;
        if let Some(new) = base {
            for (offset, map) in &self.maps {
                // Counted, and kept: the guest was told the blob is mapped
                // there, so no other blob may take the range, and the next
                // move tries again. Unmapping it meanwhile is harmless.
                if self.mapper.map(map.host, new + offset, map.len).is_err() {
                    self.rejected += 1;
                }
            }
        }
    }

    /// Unmaps everything (device reset or the end of a boot); the base stays.
    /// Unmap errors are ignored: after the VM is gone nothing is mapped.
    pub fn purge(&mut self) {
        if let Some(base) = self.base {
            for (offset, map) in &self.maps {
                let _ = self.mapper.unmap(base + offset, map.len);
            }
        }
        self.maps.clear();
    }
}

#[repr(C, packed(4))]
#[derive(Default)]
struct RegionBasicInfo64 {
    protection: i32,
    max_protection: i32,
    inheritance: u32,
    shared: u32,
    reserved: u32,
    offset: u64,
    behavior: i32,
    user_wired_count: u16,
}

unsafe extern "C" {
    static mach_task_self_: u32;
    fn mach_vm_region(task: u32, address: *mut u64, size: *mut u64, flavor: i32, info: *mut RegionBasicInfo64, count: *mut u32, object: *mut u32)
    -> i32;
}

const VM_REGION_BASIC_INFO_64: i32 = 9;
const VM_PROT_READ: i32 = 1;
const VM_PROT_WRITE: i32 = 2;

/// Whether `[host, host + len)` lies inside one readable and writable VM
/// region of this process: a Vulkan blob's size comes from the guest, and
/// mapping past its allocation would hand the guest other host memory.
pub fn host_range_ok(host: usize, len: u64) -> bool {
    let (mut address, mut size) = (host as u64, 0u64);
    let mut info = RegionBasicInfo64::default();
    let mut count = (size_of::<RegionBasicInfo64>() / 4) as u32;
    let mut object = 0u32;
    let result = unsafe { mach_vm_region(mach_task_self_, &mut address, &mut size, VM_REGION_BASIC_INFO_64, &mut info, &mut count, &mut object) };
    let protection = info.protection;
    result == 0
        && address <= host as u64
        && (host as u64).checked_add(len).is_some_and(|end| end <= address + size)
        && protection & (VM_PROT_READ | VM_PROT_WRITE) == VM_PROT_READ | VM_PROT_WRITE
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Vec<String>>>);

    impl Mapper for Recorder {
        fn map(&mut self, host: usize, guest: u64, len: u64) -> Result<(), String> {
            self.0.lock().unwrap().push(format!("map {host:#x} at {guest:#x} +{len:#x}"));
            Ok(())
        }
        fn unmap(&mut self, guest: u64, len: u64) -> Result<(), String> {
            self.0.lock().unwrap().push(format!("unmap {guest:#x} +{len:#x}"));
            Ok(())
        }
    }

    fn region() -> (HostVisible<Recorder>, Recorder) {
        let recorder = Recorder::default();
        let mut region = HostVisible::new(8 << 30, recorder.clone());
        region.rebase(Some(0x8_0000_0000));
        (region, recorder)
    }

    #[test]
    fn maps_need_a_base_and_whole_pages() {
        let mut region = HostVisible::new(8 << 30, Recorder::default());
        assert_eq!(region.map(1, 0, 0x4000, PAGE), Err(MapError::NoBase));
        region.rebase(Some(0x8_0000_0000));
        assert_eq!(region.map(1, 0x1000, 0x4000, PAGE), Err(MapError::Misaligned), "offset");
        assert_eq!(region.map(1, 0, 0x5000, PAGE), Err(MapError::Misaligned), "host address");
        assert_eq!(region.map(1, 0, 0x4000, 0x1000), Err(MapError::Misaligned), "length");
        assert_eq!(region.map(1, 0, 0x4000, 0), Err(MapError::Misaligned), "nothing");
        assert_eq!(region.rejected, 5);
        assert_eq!(region.map(1, 0, 0x4000, PAGE), Ok(()));
        assert_eq!(region.mapped_bytes(), PAGE);
    }

    #[test]
    fn maps_stay_inside_the_region() {
        let (mut region, _) = region();
        assert_eq!(region.map(1, (8 << 30) - PAGE, 0x4000, 2 * PAGE), Err(MapError::OutOfRange));
        assert_eq!(region.map(1, u64::MAX - PAGE + 1, 0x4000, PAGE), Err(MapError::OutOfRange), "no overflow");
        assert_eq!(region.map(1, (8 << 30) - PAGE, 0x4000, PAGE), Ok(()));
    }

    #[test]
    fn maps_do_not_overlap_and_resources_map_once() {
        let (mut region, _) = region();
        assert_eq!(region.map(1, 2 * PAGE, 0x10000, 2 * PAGE), Ok(()));
        assert_eq!(region.map(2, 3 * PAGE, 0x40000, PAGE), Err(MapError::Overlap), "inside");
        assert_eq!(region.map(2, PAGE, 0x40000, 2 * PAGE), Err(MapError::Overlap), "reaching in");
        assert_eq!(region.map(2, 0, 0x40000, 8 * PAGE), Err(MapError::Overlap), "around");
        assert_eq!(region.map(1, 8 * PAGE, 0x40000, PAGE), Err(MapError::AlreadyMapped));
        assert_eq!(region.map(2, 0, 0x40000, 2 * PAGE), Ok(()), "right before");
        assert_eq!(region.map(3, 4 * PAGE, 0x80000, PAGE), Ok(()), "right after");
        assert!(region.unmap(1));
        assert!(!region.unmap(1));
        assert_eq!(region.map(4, 2 * PAGE, 0xc0000, 2 * PAGE), Ok(()), "the hole can be reused");
    }

    #[test]
    fn rebase_moves_every_map_and_purge_drops_them() {
        let (mut region, recorder) = region();
        region.map(7, PAGE, 0x10000, PAGE).unwrap();
        recorder.0.lock().unwrap().clear();
        region.rebase(Some(0xa_0000_0000));
        assert_eq!(*recorder.0.lock().unwrap(), ["unmap 0x800004000 +0x4000", "map 0x10000 at 0xa00004000 +0x4000"]);
        recorder.0.lock().unwrap().clear();
        region.rebase(None);
        assert_eq!(*recorder.0.lock().unwrap(), ["unmap 0xa00004000 +0x4000"]);
        assert_eq!(region.count(), 1, "kept for when the BAR comes back");
        region.rebase(Some(0x8_0000_0000));
        recorder.0.lock().unwrap().clear();
        region.purge();
        assert_eq!(*recorder.0.lock().unwrap(), ["unmap 0x800004000 +0x4000"]);
        assert_eq!(region.count(), 0);
    }

    /// Refuses maps at or above its address (a BAR the VM cannot back there).
    struct Refusing(Recorder, u64);

    impl Mapper for Refusing {
        fn map(&mut self, host: usize, guest: u64, len: u64) -> Result<(), String> {
            if guest >= self.1 {
                return Err("refused".into());
            }
            self.0.map(host, guest, len)
        }
        fn unmap(&mut self, guest: u64, len: u64) -> Result<(), String> {
            self.0.unmap(guest, len)
        }
    }

    #[test]
    fn a_blob_a_moved_bar_cannot_take_stays_the_guests_until_the_next_move() {
        let recorder = Recorder::default();
        let mut region = HostVisible::new(8 << 30, Refusing(recorder.clone(), 0xa_0000_0000));
        region.rebase(Some(0x8_0000_0000));
        region.map(7, PAGE, 0x10000, PAGE).unwrap();
        region.rebase(Some(0xa_0000_0000));
        assert_eq!((region.rejected, region.count()), (1, 1), "counted, and still the guest's");
        assert_eq!(region.map(8, PAGE, 0x20000, PAGE), Err(MapError::Overlap), "nothing else takes its range");
        recorder.0.lock().unwrap().clear();
        region.rebase(Some(0x9_0000_0000));
        assert_eq!(*recorder.0.lock().unwrap(), ["unmap 0xa00004000 +0x4000", "map 0x10000 at 0x900004000 +0x4000"]);
        assert!(region.unmap(7));
    }

    #[test]
    fn host_ranges_must_lie_in_one_region() {
        let len = 4 * PAGE as usize;
        let map = unsafe { libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_ANON | libc::MAP_PRIVATE, -1, 0) };
        assert_ne!(map, libc::MAP_FAILED);
        let host = map as usize;
        assert!(host_range_ok(host, len as u64));
        assert!(host_range_ok(host + PAGE as usize, PAGE));
        unsafe { libc::munmap((host + 3 * PAGE as usize) as *mut libc::c_void, PAGE as usize) };
        assert!(!host_range_ok(host, len as u64), "past the end of the allocation");
        unsafe { libc::mprotect(map, PAGE as usize, libc::PROT_READ) };
        assert!(!host_range_ok(host, PAGE), "read-only");
        unsafe { libc::munmap(map, 3 * PAGE as usize) };
    }
}
