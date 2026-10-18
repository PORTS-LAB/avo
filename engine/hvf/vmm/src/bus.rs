//! The MMIO bus: guest physical ranges that trap to device models.

use std::sync::Arc;

/// A device model reached through trapped loads and stores. `offset` is
/// relative to the start of the range it was registered at.
pub trait MmioHandler: Send + Sync {
    fn read(&self, offset: u64, data: &mut [u8]);
    fn write(&self, offset: u64, data: &[u8]);
}

struct Range {
    base: u64,
    size: u64,
    handler: Arc<dyn MmioHandler>,
}

#[derive(Default)]
pub struct Bus {
    ranges: Vec<Range>,
}

impl Bus {
    pub fn insert(&mut self, base: u64, size: u64, handler: Arc<dyn MmioHandler>) {
        assert!(
            !self.ranges.iter().any(|r| base < r.base + r.size && r.base < base + size),
            "overlapping MMIO range at {base:#x}"
        );
        self.ranges.push(Range { base, size, handler });
        self.ranges.sort_by_key(|r| r.base);
    }

    fn find(&self, address: u64) -> Option<&Range> {
        let index = self.ranges.partition_point(|r| r.base <= address);
        let range = self.ranges.get(index.checked_sub(1)?)?;
        (address < range.base + range.size).then_some(range)
    }

    /// Returns false when nothing is mapped at `address`.
    pub fn read(&self, address: u64, data: &mut [u8]) -> bool {
        match self.find(address) {
            Some(range) => {
                range.handler.read(address - range.base, data);
                true
            }
            None => false,
        }
    }

    pub fn write(&self, address: u64, data: &[u8]) -> bool {
        match self.find(address) {
            Some(range) => {
                range.handler.write(address - range.base, data);
                true
            }
            None => false,
        }
    }
}
