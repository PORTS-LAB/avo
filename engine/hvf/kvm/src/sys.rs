//! KVM uapi: constants, structures and ioctl numbers, transcribed from
//! Linux 6.12's `include/uapi/linux/kvm.h` and `arch/arm64/include/uapi/asm/kvm.h`.
#![allow(dead_code)] // the transcription is complete; the wrapper uses part of it

use std::os::raw::c_int;

/// The API version this wrapper targets (`KVM_GET_API_VERSION`).
pub const KVM_API_VERSION: c_int = 12;

const KVMIO: u64 = 0xAE;

const fn _ioc(dir: u64, nr: u64, size: u64) -> u64 {
    (dir << 30) | ((size & 0x3fff) << 16) | (KVMIO << 8) | nr
}
const fn _io(nr: u64) -> u64 {
    _ioc(0, nr, 0)
}
const fn _ior(nr: u64, size: u64) -> u64 {
    _ioc(2, nr, size)
}
const fn _iow(nr: u64, size: u64) -> u64 {
    _ioc(1, nr, size)
}
const fn _iowr(nr: u64, size: u64) -> u64 {
    _ioc(3, nr, size)
}

// /dev/kvm ioctls.
pub const KVM_GET_API_VERSION: u64 = _io(0x00);
pub const KVM_CREATE_VM: u64 = _io(0x01);
pub const KVM_CHECK_EXTENSION: u64 = _io(0x03);
pub const KVM_GET_VCPU_MMAP_SIZE: u64 = _io(0x04);

// VM ioctls.
pub const KVM_SET_USER_MEMORY_REGION: u64 = _iow(0x46, std::mem::size_of::<kvm_userspace_memory_region>() as u64);
pub const KVM_ENABLE_CAP: u64 = _iow(0xa3, std::mem::size_of::<kvm_enable_cap>() as u64);
/// Argument: the vCPU index (0 = boot; drives MPIDR and GIC affinity).
pub const KVM_CREATE_VCPU: u64 = _io(0x41);
pub const KVM_IRQ_LINE: u64 = _iow(0x61, std::mem::size_of::<kvm_irq_level>() as u64);

// vCPU ioctls.
pub const KVM_RUN: u64 = _io(0x80);
pub const KVM_GET_ONE_REG: u64 = _iow(0xab, std::mem::size_of::<kvm_one_reg>() as u64);
pub const KVM_SET_ONE_REG: u64 = _iow(0xac, std::mem::size_of::<kvm_one_reg>() as u64);
pub const KVM_GET_REG_LIST: u64 = _iowr(0xb0, std::mem::size_of::<kvm_reg_list>() as u64);
pub const KVM_GET_MP_STATE: u64 = _ior(0x98, std::mem::size_of::<kvm_mp_state>() as u64);
pub const KVM_SET_MP_STATE: u64 = _iow(0x99, std::mem::size_of::<kvm_mp_state>() as u64);
pub const KVM_ARM_VCPU_INIT: u64 = _iow(0xae, std::mem::size_of::<kvm_vcpu_init>() as u64);

// Device ioctls (fds from KVM_CREATE_DEVICE).
pub const KVM_CREATE_DEVICE: u64 = _iowr(0xe0, std::mem::size_of::<kvm_create_device>() as u64);
pub const KVM_SET_DEVICE_ATTR: u64 = _iow(0xe1, std::mem::size_of::<kvm_device_attr>() as u64);
pub const KVM_GET_DEVICE_ATTR: u64 = _iow(0xe2, std::mem::size_of::<kvm_device_attr>() as u64);

// KVM_EXIT_* reasons (exit_reason in kvm_run).
pub const KVM_EXIT_UNKNOWN: u32 = 0;
pub const KVM_EXIT_FAIL_ENTRY: u32 = 9;
pub const KVM_EXIT_MMIO: u32 = 6;
pub const KVM_EXIT_INTR: u32 = 10;
pub const KVM_EXIT_INTERNAL_ERROR: u32 = 17;
pub const KVM_EXIT_SYSTEM_EVENT: u32 = 24;
pub const KVM_EXIT_ARM_NISV: u32 = 28;

// KVM_EXIT_SYSTEM_EVENT types.
pub const KVM_SYSTEM_EVENT_SHUTDOWN: u32 = 1;
pub const KVM_SYSTEM_EVENT_RESET: u32 = 2;

// MP states (arm64 creates vCPUs STOPPED).
pub const KVM_MP_STATE_RUNNABLE: u32 = 0;
pub const KVM_MP_STATE_STOPPED: u32 = 5;

// Capability numbers (KVM_CHECK_EXTENSION arguments).
pub const KVM_CAP_NR_MEMSLOTS: libc::c_int = 10;
pub const KVM_CAP_MP_STATE: libc::c_int = 14;
pub const KVM_CAP_ONE_REG: libc::c_int = 70;
pub const KVM_CAP_DEVICE_CTRL: libc::c_int = 89;
pub const KVM_CAP_ARM_PSCI_0_2: libc::c_int = 102;
pub const KVM_CAP_IMMEDIATE_EXIT: libc::c_int = 136;
pub const KVM_CAP_ARM_VM_IPA_SIZE: libc::c_int = 165;
pub const KVM_CAP_ARM_NISV_TO_USER: libc::c_int = 177;
pub const KVM_CAP_COUNTER_OFFSET: libc::c_int = 227;

pub const KVM_MEM_READONLY: u32 = 1 << 1;

/// On arm64, `KVM_CREATE_VM`'s argument: bits [7:0] request the guest IPA
/// size; 0 means the kernel default (40).
pub const KVM_VM_TYPE_ARM_IPA_SIZE_MASK: u64 = 0xff;

// In-kernel GICv3 device (KVM_CREATE_DEVICE type and attributes).
pub const KVM_DEV_TYPE_ARM_VGIC_V3: u32 = 7;
pub const KVM_DEV_ARM_VGIC_GRP_ADDR: u64 = 0;
pub const KVM_DEV_ARM_VGIC_GRP_NR_IRQS: u64 = 3;
pub const KVM_DEV_ARM_VGIC_GRP_CTRL: u64 = 4;
pub const KVM_DEV_ARM_VGIC_CTRL_INIT: u64 = 0;
pub const KVM_VGIC_V3_ADDR_TYPE_DIST: u64 = 2;
pub const KVM_VGIC_V3_ADDR_TYPE_REDIST: u64 = 3;
pub const KVM_VGIC_V3_DIST_SIZE: u64 = 0x1_0000; // SZ_64K
pub const KVM_VGIC_V3_REDIST_SIZE: u64 = 0x2_0000; // 2 * SZ_64K, per vCPU

// KVM_IRQ_LINE on arm64: (irq_type << 24) | irq_number; for SPIs the number
// is the SPI index, INTID - 32.
pub const KVM_ARM_IRQ_TYPE_SPI: u32 = 1;
pub const KVM_ARM_IRQ_TYPE_SHIFT: u32 = 24;

pub const KVM_ARM_TARGET_GENERIC_V8: u32 = 5;
pub const KVM_ARM_VCPU_PSCI_0_2: u32 = 2;

// Register IDs: arch in bits 63:56, size in 55:52, coproc in 31:16, offset below.
pub const KVM_REG_ARM64: u64 = 0x6000_0000_0000_0000;
pub const KVM_REG_SIZE_U64: u64 = 0x0030_0000_0000_0000;
pub const KVM_REG_ARM_CORE: u64 = 0x0010 << 16;
pub const KVM_REG_ARM64_SYSREG: u64 = 0x0013 << 16;

/// Core register ID for the 32-bit-word offset given by
/// `KVM_REG_ARM_CORE_REG(name)` (`offsetof(kvm_regs, name) / sizeof(__u32)`).
pub const fn core_reg(offset_words: u64) -> u64 {
    KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | offset_words
}
// struct user_pt_regs: __u64 regs[31]; __u64 sp; __u64 pc; __u64 pstate;
pub const CORE_X0: u64 = 0;
pub const CORE_SP: u64 = 248 / 4;
pub const CORE_PC: u64 = 256 / 4;
pub const CORE_PSTATE: u64 = 264 / 4;

/// `ARM64_SYS_REG(op0, op1, crn, crm, op2)`.
pub const fn arm64_sysreg(op0: u32, op1: u32, crn: u32, crm: u32, op2: u32) -> u64 {
    KVM_REG_ARM64
        | KVM_REG_SIZE_U64
        | KVM_REG_ARM64_SYSREG
        | (((op0 & 0x3) as u64) << 14)
        | (((op1 & 0x7) as u64) << 11)
        | (((crn & 0xf) as u64) << 7)
        | (((crm & 0xf) as u64) << 3)
        | ((op2 & 0x7) as u64)
}

/// The virtual counter (`KVM_REG_ARM_TIMER_CNT`): the uapi notes its encoding
/// was accidentally swapped with `KVM_REG_ARM_TIMER_CVAL`'s and must be used
/// as defined. Writing it sets the counter now (what QEMU's kvm-adjvtime does).
pub const KVM_REG_ARM_TIMER_CNT: u64 = arm64_sysreg(3, 3, 14, 3, 2);
/// CNTFRQ_EL0 (the counter frequency, in Hz).
pub const KVM_REG_ARM_CNTFRQ_EL0: u64 = arm64_sysreg(3, 3, 14, 0, 0);

// The five system registers `vmm` and `probe` touch, as 16-bit encodings
// (op0 << 14 | op1 << 11 | crn << 7 | crm << 3 | op2) — byte-for-byte the
// values the `hvf` wrapper's constants carry, so one set of constants serves
// both backends. Where the kernel's uapi numbers them differently,
// `sysreg_id` translates.
pub const HV_SYS_REG_MPIDR_EL1: u16 = (3 << 14) | (0 << 11) | (0 << 7) | (0 << 3) | 5;
pub const HV_SYS_REG_SCTLR_EL1: u16 = (3 << 14) | (0 << 11) | (1 << 7) | (0 << 3) | 0;
/// Hypervisor.framework numbers SP_EL1 unconventionally (not the natural
/// (3,0,4,1,0) = 0xC208); `sysreg_id` maps it back.
pub const HV_SYS_REG_SP_EL1: u16 = (3 << 14) | (4 << 11) | (4 << 7) | (1 << 3) | 0;
pub const HV_SYS_REG_CNTV_CTL_EL0: u16 = (3 << 14) | (3 << 11) | (14 << 7) | (3 << 3) | 1;
/// Hypervisor.framework numbers CNTV_CVAL_EL0 by its natural encoding —
/// which, per the swap note in asm/kvm.h, is the kernel uapi's id for the
/// counter, not the comparator. `sysreg_id` maps it to the kernel's
/// `KVM_REG_ARM_TIMER_CVAL`.
pub const HV_SYS_REG_CNTV_CVAL_EL0: u16 = (3 << 14) | (3 << 11) | (14 << 7) | (3 << 3) | 2;

/// The kernel register id for a 16-bit Hypervisor.framework encoding.
pub fn sysreg_id(reg: u16) -> u64 {
    match reg {
        HV_SYS_REG_CNTV_CVAL_EL0 => arm64_sysreg(3, 3, 14, 0, 2),
        HV_SYS_REG_SP_EL1 => arm64_sysreg(3, 0, 4, 1, 0),
        _ => KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM64_SYSREG | reg as u64,
    }
}

// Register selects for `reg`/`set_reg` (the `hvf` wrapper's hv_reg_t shape).
pub const HV_REG_X0: u32 = 0;
pub const HV_REG_PC: u32 = 0x1000_0000;
pub const HV_REG_CPSR: u32 = 0x1000_0001;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_userspace_memory_region {
    pub slot: u32,
    pub flags: u32,
    pub guest_phys_addr: u64,
    pub memory_size: u64,
    pub userspace_addr: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_enable_cap {
    pub cap: u32,
    pub flags: u32,
    pub args: [u64; 4],
    pub pad: [u8; 64],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_one_reg {
    pub id: u64,
    /// Pointer to the value.
    pub addr: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_reg_list {
    pub n: u64,
    /// Pointer to `n` register IDs.
    pub reg: *mut u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_vcpu_init {
    pub target: u32,
    pub features: [u32; 7],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_mp_state {
    pub mp_state: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_irq_level {
    /// For arm64 SPIs: `(KVM_ARM_IRQ_TYPE_SPI << 24) | (INTID - 32)`.
    pub irq: u32,
    pub level: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_create_device {
    pub type_: u32,
    /// Out: the device fd.
    pub fd: u32,
    pub flags: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_device_attr {
    pub flags: u32,
    pub group: u32,
    pub attr: u64,
    /// Userspace address of the attr data (the address itself for VGIC
    /// base addresses).
    pub addr: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_mmio {
    pub phys_addr: u64,
    pub data: [u8; 8],
    pub len: u32,
    pub is_write: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_system_event {
    pub type_: u32,
    pub ndata: u32,
    /// `data[0]` is `flags`.
    pub data: [u64; 16],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_arm_nisv {
    pub esr_iss: u64,
    pub fault_ipa: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_fail_entry {
    pub hardware_entry_failure_reason: u64,
    pub cpu: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_internal {
    pub suberror: u32,
    pub ndata: u32,
    pub data: [u64; 16],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct kvm_hw_reason {
    pub hardware_exit_reason: u64,
}

/// `struct kvm_run`: the common prefix and the exit union at the kernel's
/// offsets. The kernel's union is padded far beyond these members; this copy
/// only needs correct offsets and must not exceed the mmap size.
#[repr(C)]
pub struct kvm_run {
    pub request_interrupt_window: u8,
    /// Set by a kick: makes the running or next `KVM_RUN` return at once.
    pub immediate_exit: u8,
    pub padding1: [u8; 6],
    pub exit_reason: u32,
    pub ready_for_interrupt_injection: u8,
    pub if_flag: u8,
    pub flags: u16,
    pub cr8: u64,
    pub apic_base: u64,
    pub exit: kvm_run_exit,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union kvm_run_exit {
    pub hw: kvm_hw_reason,
    pub fail_entry: kvm_fail_entry,
    pub mmio: kvm_mmio,
    pub system_event: kvm_system_event,
    pub arm_nisv: kvm_arm_nisv,
    pub internal: kvm_internal,
    pub pad: [u8; 4064],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ioctl_numbers_match_the_kernel() {
        assert_eq!(KVM_GET_API_VERSION, 0x0000_AE00);
        assert_eq!(KVM_CREATE_VM, 0x0000_AE01);
        assert_eq!(KVM_CHECK_EXTENSION, 0x0000_AE03);
        assert_eq!(KVM_GET_VCPU_MMAP_SIZE, 0x0000_AE04);
        assert_eq!(KVM_SET_USER_MEMORY_REGION, 0x4020_AE46);
        assert_eq!(KVM_ENABLE_CAP, 0x4068_AEA3);
        assert_eq!(KVM_CREATE_VCPU, 0x0000_AE41);
        assert_eq!(KVM_IRQ_LINE, 0x4008_AE61);
        assert_eq!(KVM_RUN, 0x0000_AE80);
        assert_eq!(KVM_GET_ONE_REG, 0x4010_AEAB);
        assert_eq!(KVM_SET_ONE_REG, 0x4010_AEAC);
        assert_eq!(KVM_GET_REG_LIST, 0xC010_AEB0);
        assert_eq!(KVM_GET_MP_STATE, 0x8004_AE98);
        assert_eq!(KVM_SET_MP_STATE, 0x4004_AE99);
        assert_eq!(KVM_ARM_VCPU_INIT, 0x4020_AEAE);
        assert_eq!(KVM_CREATE_DEVICE, 0xC00C_AEE0);
        assert_eq!(KVM_SET_DEVICE_ATTR, 0x4018_AEE1);
        assert_eq!(KVM_GET_DEVICE_ATTR, 0x4018_AEE2);
    }

    #[test]
    fn register_ids_match_known_values() {
        assert_eq!(arm64_sysreg(3, 0, 0, 0, 5), 0x6030_0000_0013_C005); // MPIDR_EL1
        assert_eq!(core_reg(CORE_X0), 0x6030_0000_0010_0000); // X0
        assert_eq!(core_reg(CORE_SP), 0x6030_0000_0010_003E); // SP
        assert_eq!(core_reg(CORE_PC), 0x6030_0000_0010_0040); // PC
        assert_eq!(core_reg(CORE_PSTATE), 0x6030_0000_0010_0042); // PSTATE
        assert_eq!(KVM_REG_ARM_TIMER_CNT, 0x6030_0000_0013_DF1A);
        assert_eq!(KVM_REG_ARM_CNTFRQ_EL0, 0x6030_0000_0013_DF00);
        assert_eq!(sysreg_id(HV_SYS_REG_SP_EL1), 0x6030_0000_0013_C208);
        assert_eq!(sysreg_id(HV_SYS_REG_CNTV_CVAL_EL0), 0x6030_0000_0013_DF02);
    }
}
