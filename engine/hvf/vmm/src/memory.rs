//! Guest RAM as seen by devices: bounds-checked access by guest physical
//! address. vCPU threads and device threads share it, like crosvm's
//! GuestMemory; virtqueue code adds the memory barriers the protocol needs.

use hvf::GuestRegion;

pub struct GuestMemory {
    region: GuestRegion,
}

impl GuestMemory {
    pub fn new(region: GuestRegion) -> GuestMemory {
        GuestMemory { region }
    }

    pub fn base(&self) -> u64 {
        self.region.guest_address()
    }

    pub fn size(&self) -> u64 {
        self.region.len() as u64
    }

    /// Host pointer for `len` bytes at `address`, if they are all RAM (an
    /// empty range may sit right at the end).
    pub fn host_ptr(&self, address: u64, len: usize) -> Option<*mut u8> {
        if !self.region.contains(address, len) {
            return None;
        }
        Some(unsafe { self.region.as_ptr().add((address - self.base()) as usize) })
    }

    pub fn read(&self, address: u64, out: &mut [u8]) -> bool {
        match self.host_ptr(address, out.len()) {
            Some(ptr) => {
                unsafe { std::ptr::copy_nonoverlapping(ptr, out.as_mut_ptr(), out.len()) };
                true
            }
            None => false,
        }
    }

    pub fn write(&self, address: u64, data: &[u8]) -> bool {
        match self.host_ptr(address, data.len()) {
            Some(ptr) => {
                unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), ptr, data.len()) };
                true
            }
            None => false,
        }
    }

    pub fn read_u16(&self, address: u64) -> Option<u16> {
        let ptr = self.host_ptr(address, 2)? as *const u16;
        Some(u16::from_le(unsafe { ptr.read_volatile() }))
    }

    pub fn read_u32(&self, address: u64) -> Option<u32> {
        let ptr = self.host_ptr(address, 4)? as *const u32;
        Some(u32::from_le(unsafe { ptr.read_unaligned() }))
    }

    pub fn read_u64(&self, address: u64) -> Option<u64> {
        let ptr = self.host_ptr(address, 8)? as *const u64;
        Some(u64::from_le(unsafe { ptr.read_unaligned() }))
    }

    pub fn write_u16(&self, address: u64, value: u16) -> bool {
        match self.host_ptr(address, 2) {
            Some(ptr) => {
                unsafe { (ptr as *mut u16).write_volatile(value.to_le()) };
                true
            }
            None => false,
        }
    }

    pub fn write_u32(&self, address: u64, value: u32) -> bool {
        match self.host_ptr(address, 4) {
            Some(ptr) => {
                unsafe { (ptr as *mut u32).write_unaligned(value.to_le()) };
                true
            }
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_ranges_inside_ram_get_a_host_pointer() {
        let memory = GuestMemory::new(GuestRegion::new(0x8000_0000, 1 << 16).unwrap());
        let end = memory.base() + memory.size();
        assert!(memory.host_ptr(memory.base(), 1 << 16).is_some());
        assert!(memory.host_ptr(end, 0).is_some(), "empty, at the end");
        assert!(memory.host_ptr(end + 1, 0).is_none());
        assert!(memory.host_ptr(end - 4, 8).is_none());
        assert!(memory.host_ptr(u64::MAX - 7, 16).is_none(), "wraps past the top");
        assert!(memory.host_ptr(memory.base() + 16, usize::MAX).is_none());
        assert!(!memory.write(u64::MAX, &[0; 2]));
    }
}
