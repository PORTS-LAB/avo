//! PCI: a CAM host bridge ("pci-host-cam-generic") with one bus, and type 0
//! configuration space for endpoint functions. Same shape as crosvm's
//! aarch64 machine, so Cuttlefish's `androidboot.boot_devices=10000.pci`
//! and its sysfs expectations hold.

use crate::bus::MmioHandler;
use std::sync::{Arc, Mutex, RwLock};

pub const CAM_BASE: u64 = 0x1_0000;
pub const CAM_SIZE: u64 = 0x100_0000;
/// 32-bit memory window the guest assigns BARs from.
pub const MEM_BASE: u64 = 0x200_0000;
pub const MEM_SIZE: u64 = 0x200_0000;
/// 64-bit prefetchable window for large BARs (the GPU's 8 GiB host-visible
/// memory): above RAM and inside the default 36-bit IPA space. The device
/// tree lists it only when a function has a 64-bit BAR.
pub const MEM64_BASE: u64 = 0x8_0000_0000;
pub const MEM64_SIZE: u64 = 0x8_0000_0000;
pub const MAX_DEVICES: usize = 32;

/// A PCI function's BAR space (the device side of the transport).
pub trait PciFunction: Send {
    fn bar_read(&mut self, bar: usize, offset: u64, data: &mut [u8]);
    fn bar_write(&mut self, bar: usize, offset: u64, data: &[u8]);
    /// A 64-bit BAR got a usable base, or lost it (`None`: decoding off,
    /// unassigned, or not an aligned range inside the 64-bit window).
    fn bar_moved(&mut self, _bar: usize, _base: Option<u64>) {}
}

#[derive(Clone, Copy)]
pub struct Bar {
    pub size: u64,
    pub prefetchable: bool,
}

/// Type 0 header plus capabilities, with write masks for the registers the
/// guest may change.
pub struct ConfigSpace {
    regs: [u32; 64],
    writable: [u32; 64],
    bars: [Option<Bar>; 6],
    /// 64-bit BARs (each also uses the next register) and the base last
    /// reported to the function through `bar_moved`.
    wide: [bool; 6],
    reported: [Option<u64>; 6],
}

impl ConfigSpace {
    pub fn new(vendor: u16, device: u16, class: u32, revision: u8, subsystem: (u16, u16)) -> ConfigSpace {
        let mut regs = [0u32; 64];
        let mut writable = [0u32; 64];
        regs[0] = vendor as u32 | (device as u32) << 16;
        // Command: memory space, bus master and INTx disable are writable.
        writable[1] = 0x0000_0406;
        regs[2] = revision as u32 | class << 8;
        regs[11] = subsystem.0 as u32 | (subsystem.1 as u32) << 16;
        // Interrupt pin INTA; the line register is scratch for the OS.
        regs[15] = 1 << 8;
        writable[15] = 0xff;
        ConfigSpace { regs, writable, bars: [None; 6], wide: [false; 6], reported: [None; 6] }
    }

    /// Marks function 0 of a device that has more functions (header type bit 7).
    pub fn set_multifunction(&mut self, enabled: bool) {
        if enabled {
            self.regs[3] |= 0x80 << 16;
        } else {
            self.regs[3] &= !(0x80 << 16);
        }
    }

    pub fn add_bar(&mut self, index: usize, bar: Bar) {
        assert!(bar.size.is_power_of_two() && bar.size >= 16);
        self.bars[index] = Some(bar);
        self.regs[4 + index] = if bar.prefetchable { 1 << 3 } else { 0 };
        self.writable[4 + index] = !(bar.size as u32 - 1);
    }

    /// A 64-bit memory BAR in registers `index` and `index + 1`; the guest
    /// places it in the 64-bit window (MEM64_BASE) when it is prefetchable.
    pub fn add_bar64(&mut self, index: usize, bar: Bar) {
        assert!(index < 5 && bar.size.is_power_of_two() && bar.size >= 16);
        let mask = !(bar.size - 1);
        self.bars[index] = Some(bar);
        self.wide[index] = true;
        self.regs[4 + index] = 0x4 | if bar.prefetchable { 1 << 3 } else { 0 };
        self.writable[4 + index] = mask as u32 & !0xf;
        self.writable[5 + index] = (mask >> 32) as u32;
    }

    /// Writes a capability list starting at 0x40 from raw capability bodies
    /// (each starting with its ID byte); fills in the next pointers.
    pub fn set_capabilities(&mut self, capabilities: &[Vec<u8>]) {
        let mut offset = 0x40usize;
        let mut bytes = [0u8; 256];
        for (i, raw) in capabilities.iter().enumerate() {
            let next = if i + 1 < capabilities.len() { offset + raw.len().next_multiple_of(4) } else { 0 };
            bytes[offset..offset + raw.len()].copy_from_slice(raw);
            bytes[offset + 1] = next as u8;
            offset += raw.len().next_multiple_of(4);
        }
        for reg in 16..64 {
            self.regs[reg] = u32::from_le_bytes(bytes[reg * 4..reg * 4 + 4].try_into().unwrap());
        }
        if !capabilities.is_empty() {
            self.regs[13] = 0x40; // capabilities pointer
            self.regs[1] |= 1 << 20; // status: capabilities list
        }
    }

    pub fn read(&self, reg: usize) -> u32 {
        self.regs.get(reg).copied().unwrap_or(0)
    }

    /// Byte-granular write into register `reg`.
    pub fn write(&mut self, reg: usize, offset: usize, data: &[u8]) {
        if reg >= 64 || offset + data.len() > 4 {
            return;
        }
        let mut value = self.regs[reg].to_le_bytes();
        let mask = self.writable[reg].to_le_bytes();
        for (i, byte) in data.iter().enumerate() {
            let at = offset + i;
            value[at] = (value[at] & !mask[at]) | (byte & mask[at]);
        }
        self.regs[reg] = u32::from_le_bytes(value);
    }

    pub fn memory_enabled(&self) -> bool {
        self.regs[1] & 0x2 != 0
    }

    /// Current address of BAR `index` while memory decoding is on.
    pub fn bar_address(&self, index: usize) -> Option<(u64, u64)> {
        let bar = self.bars[index]?;
        let mut address = (self.regs[4 + index] & !0xf) as u64;
        // What reads back after the OS wrote all ones to size the BAR.
        let mut sizing = !(bar.size - 1) & 0xffff_fff0;
        if self.wide[index] {
            address |= (self.regs[5 + index] as u64) << 32;
            sizing = !(bar.size - 1) & !0xf;
        }
        if !self.memory_enabled() || address == 0 || address == sizing {
            return None;
        }
        Some((address, bar.size))
    }
}

pub struct Slot {
    pub config: ConfigSpace,
    pub function: Box<dyn PciFunction>,
}

/// PCI device and function number (bus 0).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DevFn {
    pub device: usize,
    pub function: usize,
}

impl DevFn {
    /// The 8-bit devfn used in device tree unit addresses.
    pub fn number(self) -> u32 {
        (self.device as u32) << 3 | self.function as u32
    }
}

#[derive(Clone, Copy)]
struct BarMapping {
    base: u64,
    size: u64,
    at: DevFn,
    bar: usize,
}

/// Bus 0 of the host bridge: configuration space through CAM and the BARs
/// the guest placed in the memory window.
pub struct PciRoot {
    slots: Vec<[Option<Arc<Mutex<Slot>>>; 8]>,
    mappings: RwLock<Vec<BarMapping>>,
}

impl PciRoot {
    pub fn new() -> PciRoot {
        PciRoot { slots: (0..MAX_DEVICES).map(|_| Default::default()).collect(), mappings: RwLock::new(Vec::new()) }
    }

    /// Adds functions 0, 1, ... of the next free device number (device 0 is
    /// left free, like a host bridge slot). Returns where each one went.
    pub fn add_device(&mut self, functions: Vec<Slot>) -> Vec<DevFn> {
        assert!(!functions.is_empty() && functions.len() <= 8);
        let device = (1..MAX_DEVICES).find(|&d| self.slots[d].iter().all(Option::is_none)).expect("PCI bus full");
        let multifunction = functions.len() > 1;
        let mut placed = Vec::new();
        for (function, mut slot) in functions.into_iter().enumerate() {
            if function == 0 {
                slot.config.set_multifunction(multifunction);
            }
            self.slots[device][function] = Some(Arc::new(Mutex::new(slot)));
            placed.push(DevFn { device, function });
        }
        placed
    }

    /// The device number `add_device` will use next.
    pub fn next_device(&self) -> Option<usize> {
        (1..MAX_DEVICES).find(|&d| self.slots[d].iter().all(Option::is_none))
    }

    /// Whether any function has a 64-bit BAR (the machine then adds the
    /// 64-bit window to the device tree and the bus).
    pub fn has_mem64(&self) -> bool {
        self.slots.iter().flat_map(|device| device.iter().flatten()).any(|slot| slot.lock().unwrap().config.wide.contains(&true))
    }

    fn remap(&self, at: DevFn, slot: &mut Slot) {
        {
            let mut mappings = self.mappings.write().unwrap();
            mappings.retain(|m| m.at != at);
            for bar in 0..6 {
                if let Some((base, size)) = slot.config.bar_address(bar) {
                    mappings.push(BarMapping { base, size, at, bar });
                }
            }
        }
        // 64-bit BARs map host memory into the guest at their base, so the
        // function hears every change. The OS writes the two halves one at a
        // time; only an aligned range inside the window counts.
        for bar in 0..6 {
            if !slot.config.wide[bar] {
                continue;
            }
            let base = slot
                .config
                .bar_address(bar)
                .filter(|&(base, size)| {
                    base >= MEM64_BASE && base % size == 0 && base.checked_add(size).is_some_and(|end| end <= MEM64_BASE + MEM64_SIZE)
                })
                .map(|(base, _)| base);
            if slot.config.reported[bar] != base {
                slot.config.reported[bar] = base;
                slot.function.bar_moved(bar, base);
            }
        }
    }

    fn config_access(&self, offset: u64, data: &mut [u8], write: bool) {
        let bus = (offset >> 16) & 0xff;
        let device = ((offset >> 11) & 0x1f) as usize;
        let function = ((offset >> 8) & 0x7) as usize;
        let register = (offset & 0xff) as usize;
        let slot = if bus == 0 { self.slots[device][function].as_ref() } else { None };
        let Some(slot) = slot else {
            if !write {
                data.fill(0xff);
            }
            return;
        };
        let mut guard = slot.lock().unwrap();
        let reg = register / 4;
        let within = register % 4;
        if write {
            guard.config.write(reg, within, data);
            if reg == 1 || (4..10).contains(&reg) {
                self.remap(DevFn { device, function }, &mut guard);
            }
        } else {
            let value = guard.config.read(reg).to_le_bytes();
            let len = data.len().min(4 - within);
            data[..len].copy_from_slice(&value[within..within + len]);
        }
    }

    fn bar_access(&self, address: u64, data: &mut [u8], write: bool) {
        let mapping = {
            let mappings = self.mappings.read().unwrap();
            mappings.iter().find(|m| address >= m.base && address + data.len() as u64 <= m.base + m.size).copied()
        };
        let Some(mapping) = mapping else {
            if !write {
                data.fill(0);
            }
            return;
        };
        let slot = self.slots[mapping.at.device][mapping.at.function].as_ref().unwrap();
        let mut guard = slot.lock().unwrap();
        if write {
            guard.function.bar_write(mapping.bar, address - mapping.base, data);
        } else {
            guard.function.bar_read(mapping.bar, address - mapping.base, data);
        }
    }
}

/// CAM configuration window.
pub struct PciConfigWindow(pub Arc<PciRoot>);

impl MmioHandler for PciConfigWindow {
    fn read(&self, offset: u64, data: &mut [u8]) {
        self.0.config_access(offset, data, false);
    }

    fn write(&self, offset: u64, data: &[u8]) {
        let mut copy = data.to_vec();
        self.0.config_access(offset, &mut copy, true);
    }
}

/// Memory window holding device BARs.
pub struct PciMemoryWindow(pub Arc<PciRoot>);

impl MmioHandler for PciMemoryWindow {
    fn read(&self, offset: u64, data: &mut [u8]) {
        self.0.bar_access(MEM_BASE + offset, data, false);
    }

    fn write(&self, offset: u64, data: &[u8]) {
        let mut copy = data.to_vec();
        self.0.bar_access(MEM_BASE + offset, &mut copy, true);
    }
}

/// The 64-bit window: accesses that trap there reach a 64-bit BAR's
/// function (parts of the GPU's host-visible BAR with no memory mapped).
pub struct PciMemory64Window(pub Arc<PciRoot>);

impl MmioHandler for PciMemory64Window {
    fn read(&self, offset: u64, data: &mut [u8]) {
        self.0.bar_access(MEM64_BASE + offset, data, false);
    }

    fn write(&self, offset: u64, data: &[u8]) {
        let mut copy = data.to_vec();
        self.0.bar_access(MEM64_BASE + offset, &mut copy, true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Echo(Vec<u8>);
    impl PciFunction for Echo {
        fn bar_read(&mut self, _bar: usize, offset: u64, data: &mut [u8]) {
            let o = offset as usize;
            data.copy_from_slice(&self.0[o..o + data.len()]);
        }
        fn bar_write(&mut self, _bar: usize, offset: u64, data: &[u8]) {
            let o = offset as usize;
            self.0[o..o + data.len()].copy_from_slice(data);
        }
    }

    fn cam(device: u64, reg: u64) -> u64 {
        device << 11 | reg
    }

    #[test]
    fn functions_share_a_device() {
        let mut root = PciRoot::new();
        let slot = || {
            let config = ConfigSpace::new(0x1af4, 0x1043, 0x078000, 1, (0x1af4, 0x40));
            Slot { config, function: Box::new(Echo(vec![0; 16])) }
        };
        let placed = root.add_device(vec![slot(), slot(), slot()]);
        assert_eq!(placed[2], DevFn { device: 1, function: 2 });
        let root = Arc::new(root);
        let window = PciConfigWindow(root.clone());
        let mut header = [0u8; 4];
        window.read(cam(1, 0x0c), &mut header);
        assert_eq!(header[2] & 0x80, 0x80, "function 0 is multi-function");
        let mut id = [0u8; 4];
        window.read(cam(1, 0) | 2 << 8, &mut id);
        assert_eq!(u32::from_le_bytes(id), 0x1043_1af4);
        window.read(cam(1, 0) | 3 << 8, &mut id);
        assert_eq!(id, [0xff; 4]);
    }

    #[test]
    fn bar_sizing_and_routing() {
        let mut root = PciRoot::new();
        let mut config = ConfigSpace::new(0x1af4, 0x1042, 0x018000, 1, (0x1af4, 0x40));
        config.add_bar(0, Bar { size: 0x4000, prefetchable: false });
        let placed = root.add_device(vec![Slot { config, function: Box::new(Echo(vec![0; 0x4000])) }]);
        assert_eq!(placed, vec![DevFn { device: 1, function: 0 }]);
        let root = Arc::new(root);
        let window = PciConfigWindow(root.clone());

        let mut id = [0u8; 4];
        window.read(cam(1, 0), &mut id);
        assert_eq!(u32::from_le_bytes(id), 0x1042_1af4);
        let mut missing = [0u8; 4];
        window.read(cam(2, 0), &mut missing);
        assert_eq!(missing, [0xff; 4]);

        // Sizing: all ones in, size mask out.
        window.write(cam(1, 0x10), &0xffff_ffffu32.to_le_bytes());
        let mut bar = [0u8; 4];
        window.read(cam(1, 0x10), &mut bar);
        assert_eq!(u32::from_le_bytes(bar), 0xffff_c000);

        // Place it and enable memory decoding.
        window.write(cam(1, 0x10), &0x0200_4000u32.to_le_bytes());
        window.write(cam(1, 0x04), &[0x06, 0x00]);
        let memory = PciMemoryWindow(root.clone());
        memory.write(0x4000 + 8, &[1, 2, 3, 4]);
        let mut back = [0u8; 4];
        memory.read(0x4000 + 8, &mut back);
        assert_eq!(back, [1, 2, 3, 4]);
    }

    /// Records `bar_moved` calls.
    struct Moves(Arc<Mutex<Vec<(usize, Option<u64>)>>>);
    impl PciFunction for Moves {
        fn bar_read(&mut self, _bar: usize, _offset: u64, data: &mut [u8]) {
            data.fill(0);
        }
        fn bar_write(&mut self, _bar: usize, _offset: u64, _data: &[u8]) {}
        fn bar_moved(&mut self, bar: usize, base: Option<u64>) {
            self.0.lock().unwrap().push((bar, base));
        }
    }

    fn wide_device() -> (Arc<PciRoot>, Arc<Mutex<Vec<(usize, Option<u64>)>>>) {
        let mut root = PciRoot::new();
        let mut config = ConfigSpace::new(0x1af4, 0x1050, 0x038000, 1, (0x1af4, 0x40));
        config.add_bar(0, Bar { size: 0x4000, prefetchable: false });
        config.add_bar64(2, Bar { size: 8 << 30, prefetchable: true });
        let moves = Arc::new(Mutex::new(Vec::new()));
        root.add_device(vec![Slot { config, function: Box::new(Moves(moves.clone())) }]);
        assert!(root.has_mem64());
        (Arc::new(root), moves)
    }

    fn read32(window: &PciConfigWindow, reg: u64) -> u32 {
        let mut value = [0u8; 4];
        window.read(cam(1, reg), &mut value);
        u32::from_le_bytes(value)
    }

    #[test]
    fn sixty_four_bit_bar_sizing() {
        let (root, _) = wide_device();
        let window = PciConfigWindow(root.clone());
        assert_eq!(read32(&window, 0x18), 0x0000_000c, "64-bit, prefetchable");
        window.write(cam(1, 0x18), &u32::MAX.to_le_bytes());
        window.write(cam(1, 0x1c), &u32::MAX.to_le_bytes());
        assert_eq!(read32(&window, 0x18), 0x0000_000c, "8 GiB: no address bits in the low half");
        assert_eq!(read32(&window, 0x1c), 0xffff_fffe);
        let mut none = PciRoot::new();
        none.add_device(vec![Slot {
            config: ConfigSpace::new(0x1af4, 0x1042, 0x018000, 1, (0x1af4, 0x40)),
            function: Box::new(Echo(vec![0; 16])),
        }]);
        assert!(!none.has_mem64());
    }

    #[test]
    fn sixty_four_bit_bar_placement_reports_its_base() {
        let (root, moves) = wide_device();
        let window = PciConfigWindow(root.clone());
        // Sizing with decoding off reports nothing.
        window.write(cam(1, 0x18), &u32::MAX.to_le_bytes());
        window.write(cam(1, 0x1c), &u32::MAX.to_le_bytes());
        // Placed at the window's base, half by half, then decoding on.
        window.write(cam(1, 0x18), &0u32.to_le_bytes());
        window.write(cam(1, 0x1c), &((MEM64_BASE >> 32) as u32).to_le_bytes());
        assert!(moves.lock().unwrap().is_empty(), "no base while memory decoding is off");
        window.write(cam(1, 0x04), &[0x06, 0x00]);
        assert_eq!(*moves.lock().unwrap(), vec![(2, Some(MEM64_BASE))]);
        // An access to the BAR reaches the function (zeros here).
        let memory = PciMemory64Window(root.clone());
        let mut data = [0xffu8; 8];
        memory.read(0x1000, &mut data);
        assert_eq!(data, [0; 8]);
        // Decoding off: the base goes away; register 3 is BAR 2's top half, never a BAR.
        window.write(cam(1, 0x04), &[0x00, 0x00]);
        assert_eq!(moves.lock().unwrap().last(), Some(&(2, None)));
        assert!(moves.lock().unwrap().iter().all(|(bar, _)| *bar == 2));
        // A base outside the window does not count.
        window.write(cam(1, 0x1c), &1u32.to_le_bytes());
        window.write(cam(1, 0x04), &[0x06, 0x00]);
        assert_eq!(moves.lock().unwrap().len(), 2, "0x1_0000_0000 is outside the 64-bit window");
    }
}
