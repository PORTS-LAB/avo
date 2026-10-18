use std::ptr::NonNull;

/// Anonymous host memory mapped into the guest at `guest_address`.
/// 16 KiB aligned, the host page size on Apple Silicon.
pub struct GuestRegion {
    ptr: NonNull<u8>,
    len: usize,
    guest_address: u64,
}

// The region is plain memory; synchronization is the users' job, as with
// crosvm's GuestMemory.
unsafe impl Send for GuestRegion {}
unsafe impl Sync for GuestRegion {}

pub const PAGE_SIZE: usize = 16 * 1024;

unsafe extern "C" {
    fn mmap(addr: *mut u8, len: usize, prot: i32, flags: i32, fd: i32, offset: i64) -> *mut u8;
    fn munmap(addr: *mut u8, len: usize) -> i32;
}
const PROT_READ: i32 = 1;
const PROT_WRITE: i32 = 2;
const MAP_PRIVATE: i32 = 0x0002;
const MAP_ANON: i32 = 0x1000;

impl GuestRegion {
    pub fn new(guest_address: u64, len: usize) -> std::io::Result<GuestRegion> {
        assert!(len % PAGE_SIZE == 0 && guest_address % PAGE_SIZE as u64 == 0, "regions must be 16 KiB aligned");
        let ptr = unsafe { mmap(std::ptr::null_mut(), len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0) };
        if ptr as isize == -1 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(GuestRegion { ptr: NonNull::new(ptr).unwrap(), len, guest_address })
    }

    pub fn as_ptr(&self) -> *mut u8 {
        self.ptr.as_ptr()
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn guest_address(&self) -> u64 {
        self.guest_address
    }

    /// Whether `len` bytes at `address` are all in the region. Both come
    /// from the guest, so their sum may not fit in 64 bits.
    pub fn contains(&self, address: u64, len: usize) -> bool {
        address >= self.guest_address
            && address.checked_add(len as u64).is_some_and(|end| end <= self.guest_address + self.len as u64)
    }

    /// Copies `bytes` to guest physical `address`.
    pub fn write(&self, address: u64, bytes: &[u8]) {
        assert!(self.contains(address, bytes.len()), "write outside the region");
        let offset = (address - self.guest_address) as usize;
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), self.ptr.as_ptr().add(offset), bytes.len()) }
    }

    pub fn read(&self, address: u64, out: &mut [u8]) {
        assert!(self.contains(address, out.len()), "read outside the region");
        let offset = (address - self.guest_address) as usize;
        unsafe { std::ptr::copy_nonoverlapping(self.ptr.as_ptr().add(offset), out.as_mut_ptr(), out.len()) }
    }
}

impl Drop for GuestRegion {
    fn drop(&mut self) {
        unsafe {
            munmap(self.ptr.as_ptr(), self.len);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_that_wrap_past_the_top_are_outside() {
        let base = 0x8000_0000;
        let region = GuestRegion::new(base, PAGE_SIZE).unwrap();
        assert!(region.contains(base, PAGE_SIZE));
        assert!(region.contains(base + PAGE_SIZE as u64, 0), "an empty range at the end");
        assert!(!region.contains(base, PAGE_SIZE + 1));
        assert!(!region.contains(base - 1, 1));
        assert!(!region.contains(base + 0x1000, usize::MAX), "address plus length wraps");
        assert!(!region.contains(u64::MAX, 2));
    }
}
