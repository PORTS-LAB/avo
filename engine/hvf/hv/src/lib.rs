//! Avo's engine facade: the `hvf` wrapper on macOS, the `kvm` wrapper on
//! Linux (docs/linux-port.md). One API for callers, two hypervisors behind
//! it.

#[cfg(target_os = "macos")]
pub use hvf as imp;
#[cfg(not(target_os = "macos"))]
pub use kvm as imp;

pub use imp::{
    decode_exception, ExceptionClass, Exit, GicLayout, GuestRegion, MmioAccess, Protection, Vcpu, VcpuHandle, Vm,
};
pub use imp::{map_host, set_spi, unmap};

// The backend's error type (`Error { call, code }`) and its `Result` alias.
// Qualify as `hv::Result<()>` — importing it unqualified would shadow the
// standard `Result` where callers use two-parameter results.
pub use imp::{Error, Result};

// System-register ids, uniform across backends.
pub use imp::{
    HV_SYS_REG_CNTV_CVAL_EL0 as SYS_REG_CNTV_CVAL_EL0, HV_SYS_REG_CNTV_CTL_EL0 as SYS_REG_CNTV_CTL_EL0,
    HV_SYS_REG_MPIDR_EL1 as SYS_REG_MPIDR_EL1, HV_SYS_REG_SCTLR_EL1 as SYS_REG_SCTLR_EL1,
    HV_SYS_REG_SP_EL1 as SYS_REG_SP_EL1,
};

/// Whether the kernel handles PSCI: its HVC/SMC calls never exit to user
/// space, and SYSTEM_OFF/SYSTEM_RESET surface as `Exit::SystemEvent`. On
/// Hypervisor.framework the vmm implements PSCI itself (`Exit::Hvc`).
#[cfg(not(target_os = "macos"))]
pub const PSCI_IN_KERNEL: bool = true;
#[cfg(target_os = "macos")]
pub const PSCI_IN_KERNEL: bool = false;
