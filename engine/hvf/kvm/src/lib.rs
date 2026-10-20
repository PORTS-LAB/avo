//! Safe wrapper over KVM for aarch64 Linux, shaped like the `hvf` wrapper so
//! the two backends are interchangeable behind the `hv` facade
//! (docs/linux-port.md). One VM per process, like Hypervisor.framework.

mod exit;
mod memory;
mod sys;

pub use exit::{decode_exception, ExceptionClass, Exit, MmioAccess};
pub use memory::GuestRegion;
pub use sys::{
    HV_SYS_REG_CNTV_CVAL_EL0, HV_SYS_REG_CNTV_CTL_EL0, HV_SYS_REG_MPIDR_EL1, HV_SYS_REG_SCTLR_EL1, HV_SYS_REG_SP_EL1,
};

use std::fmt;
use std::fs::{File, OpenOptions};
use std::marker::PhantomData;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::raw::c_int;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Error {
    pub call: &'static str,
    pub code: i32,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} failed: {}", self.call, std::io::Error::from_raw_os_error(self.code))
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

fn os_error(call: &'static str, error: std::io::Error) -> Error {
    Error { call, code: error.raw_os_error().unwrap_or(libc::EIO) }
}

fn errno(call: &'static str) -> Error {
    os_error(call, std::io::Error::last_os_error())
}

/// An `ioctl` that returns -1 with errno on failure.
fn check(call: &'static str, result: c_int) -> Result<c_int> {
    if result < 0 { Err(errno(call)) } else { Ok(result) }
}

fn open_kvm() -> Result<File> {
    OpenOptions::new().read(true).write(true).open("/dev/kvm").map_err(|error| os_error("open /dev/kvm", error))
}

fn extension(fd: RawFd, capability: c_int) -> c_int {
    unsafe { libc::ioctl(fd, sys::KVM_CHECK_EXTENSION as libc::c_ulong, capability as libc::c_ulong) }
}

/// The signal that kicks a vCPU out of `KVM_RUN`. The handler is empty: the
/// point is only to interrupt the ioctl, and with `SA_RESTART` the kernel
/// would resume it instead of returning `EINTR`.
fn kick_signal() -> c_int {
    libc::SIGRTMIN()
}

extern "C" fn kick_handler(_signal: c_int) {}

fn install_kick_signal() {
    static INSTALLED: OnceLock<()> = OnceLock::new();
    INSTALLED.get_or_init(|| {
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        action.sa_sigaction = kick_handler as extern "C" fn(c_int) as usize;
        action.sa_flags = libc::SA_SIGINFO; // no SA_RESTART: KVM_RUN must observe EINTR
        if unsafe { libc::sigaction(kick_signal(), &action, std::ptr::null_mut()) } != 0 {
            panic!("sigaction for the kick signal failed");
        }
    });
}

/// Where a vCPU's kick target lives: its thread and its `kvm_run` page.
#[derive(Clone, Copy)]
struct Registration {
    thread: libc::pthread_t,
    run: NonNull<sys::kvm_run>,
}
unsafe impl Send for Registration {}
unsafe impl Sync for Registration {}

/// One guest memory slot, as the kernel knows it.
#[derive(Clone, Copy)]
struct Slot {
    guest: u64,
    len: usize,
    host: usize,
    id: u32,
}

#[derive(Default)]
struct Regions {
    next_id: u32,
    slots: Vec<Slot>,
}

struct VmState {
    fd: File,
    vcpu_mmap_size: usize,
    /// Kick targets by vCPU index.
    runs: Mutex<Vec<Option<Registration>>>,
    regions: Mutex<Regions>,
    /// The in-kernel GIC's device fd, until the first vCPU runs.
    gic: Mutex<Option<File>>,
    gic_ready: AtomicBool,
    /// CNTFRQ_EL0, read once (it is constant).
    counter_frequency: OnceLock<u64>,
    /// The vtimer offset `vmm` has installed, in nanoseconds (0 until the
    /// first pause). KVM exposes no readable offset, so the wrapper keeps
    /// the software copy that `set_vtimer_offset` translates into an
    /// absolute counter write.
    vtimer_offset: Mutex<u64>,
}

/// The process's VM. KVM allows many, but `kick` and the free functions
/// address "the" VM like Hypervisor.framework does, so keep one.
static PROCESS_VM: Mutex<Option<Arc<VmState>>> = Mutex::new(None);

fn process_vm(call: &'static str) -> Result<Arc<VmState>> {
    PROCESS_VM.lock().unwrap().clone().ok_or(Error { call, code: libc::ENODEV })
}

/// Guest memory permissions. KVM only distinguishes read-write from
/// read-only: `exec` is a no-op (the kernel allows execution from any
/// readable slot) and `read` cannot be dropped.
#[derive(Debug, Clone, Copy)]
pub struct Protection {
    pub read: bool,
    pub write: bool,
    pub exec: bool,
}

impl Protection {
    pub const RWX: Protection = Protection { read: true, write: true, exec: true };
    pub const RW: Protection = Protection { read: true, write: true, exec: false };
    pub const RO: Protection = Protection { read: true, write: false, exec: false };
}

/// Where the in-kernel GICv3 lives in guest physical memory.
#[derive(Debug, Clone, Copy)]
pub struct GicLayout {
    pub distributor_base: u64,
    pub distributor_size: u64,
    pub redistributor_base: u64,
    /// Size of the whole redistributor region (all vCPUs).
    pub redistributor_region_size: u64,
    /// Size of one vCPU's redistributor frames.
    pub redistributor_size: u64,
    pub spi_base: u32,
    pub spi_count: u32,
    pub virtual_timer_intid: u32,
}

pub struct Vm {
    state: Arc<VmState>,
}

impl Vm {
    /// Creates the VM with `ipa_bits` of guest physical address space (None: default).
    pub fn new(ipa_bits: Option<u32>) -> Result<Vm> {
        let kvm = open_kvm()?;
        let version = check("KVM_GET_API_VERSION", unsafe { libc::ioctl(kvm.as_raw_fd(), sys::KVM_GET_API_VERSION as libc::c_ulong) })?;
        if version != sys::KVM_API_VERSION {
            return Err(Error { call: "KVM_GET_API_VERSION", code: libc::EINVAL });
        }
        for capability in [
            sys::KVM_CAP_ARM_PSCI_0_2,
            sys::KVM_CAP_ONE_REG,
            sys::KVM_CAP_MP_STATE,
            sys::KVM_CAP_IMMEDIATE_EXIT,
            sys::KVM_CAP_DEVICE_CTRL,
            sys::KVM_CAP_ARM_NISV_TO_USER,
        ] {
            if extension(kvm.as_raw_fd(), capability) != 1 {
                return Err(Error { call: "KVM_CHECK_EXTENSION", code: libc::ENODEV });
            }
        }
        // Bits [7:0] of the VM type: the requested IPA size; 0 = kernel default.
        let vm_type = ipa_bits.map_or(0, |bits| bits as u64 & sys::KVM_VM_TYPE_ARM_IPA_SIZE_MASK) as libc::c_ulong;
        let fd = check("KVM_CREATE_VM", unsafe { libc::ioctl(kvm.as_raw_fd(), sys::KVM_CREATE_VM as libc::c_ulong, vm_type) })?;
        let fd = unsafe { File::from_raw_fd(fd as RawFd) };
        // Undecodable accesses to unmapped memory come back as
        // KVM_EXIT_ARM_NISV instead of a kernel "unsupported exit" log line,
        // so the vmm's GPU workaround keeps working.
        let mut enable =
            sys::kvm_enable_cap { cap: sys::KVM_CAP_ARM_NISV_TO_USER as u32, flags: 0, args: [0; 4], pad: [0; 64] };
        check("KVM_ENABLE_CAP(NISV_TO_USER)", unsafe {
            libc::ioctl(fd.as_raw_fd(), sys::KVM_ENABLE_CAP as libc::c_ulong, &mut enable as *mut _ as libc::c_ulong)
        })?;
        let vcpu_mmap_size =
            check("KVM_GET_VCPU_MMAP_SIZE", unsafe { libc::ioctl(kvm.as_raw_fd(), sys::KVM_GET_VCPU_MMAP_SIZE as libc::c_ulong) })? as usize;
        let state = Arc::new(VmState {
            fd,
            vcpu_mmap_size,
            runs: Mutex::new(Vec::new()),
            regions: Mutex::new(Regions::default()),
            gic: Mutex::new(None),
            gic_ready: AtomicBool::new(false),
            counter_frequency: OnceLock::new(),
            vtimer_offset: Mutex::new(0),
        });
        install_kick_signal();
        let mut process = PROCESS_VM.lock().unwrap();
        if process.is_some() {
            return Err(Error { call: "Vm::new", code: libc::EEXIST });
        }
        *process = Some(state.clone());
        drop(process);
        Ok(Vm { state })
    }

    pub fn max_ipa_bits() -> Result<u32> {
        let kvm = open_kvm()?;
        let bits = extension(kvm.as_raw_fd(), sys::KVM_CAP_ARM_VM_IPA_SIZE);
        if bits <= 0 {
            return Ok(40); // the kernel default when the cap is missing
        }
        Ok(bits as u32)
    }

    /// The guest physical address bits `new(None)` gives.
    pub fn default_ipa_bits() -> Result<u32> {
        // verify: the kernel's default with VM type 0 is 40 on arm64.
        Ok(40)
    }

    /// Maps host memory into the guest. `region` must outlive the mapping.
    pub fn map(&self, region: &GuestRegion, protection: Protection) -> Result<()> {
        self.state.set_region(region.guest_address(), region.as_ptr(), region.len(), protection.write)
    }

    pub fn unmap(&self, guest_address: u64, _len: usize) -> Result<()> {
        self.state.remove_region(guest_address)
    }

    /// KVM only distinguishes read-write from read-only (`exec` is a no-op).
    pub fn protect(&self, guest_address: u64, len: usize, protection: Protection) -> Result<()> {
        self.state.protect(guest_address, len, protection.write)
    }

    /// Creates the in-kernel GICv3. Must run before any vCPU exists: the
    /// redistributor region is sized for the vCPUs to come, and the device
    /// is initialized (KVM_DEV_ARM_VGIC_CTRL_INIT) by the first `Vcpu::run`.
    pub fn create_gic(&self, distributor_base: u64, redistributor_base: u64, vcpu_count: u32) -> Result<GicLayout> {
        let mut create = sys::kvm_create_device { type_: sys::KVM_DEV_TYPE_ARM_VGIC_V3, fd: 0, flags: 0 };
        check("KVM_CREATE_DEVICE", unsafe {
            libc::ioctl(self.state.fd.as_raw_fd(), sys::KVM_CREATE_DEVICE as libc::c_ulong, &mut create as *mut _ as libc::c_ulong)
        })?;
        let device = unsafe { File::from_raw_fd(create.fd as RawFd) };
        // Base addresses and the interrupt count go through pointer payloads.
        let mut spi_count = 1024u32;
        set_device_attr(&device, sys::KVM_DEV_ARM_VGIC_GRP_ADDR, sys::KVM_VGIC_V3_ADDR_TYPE_DIST, distributor_base, "KVM_SET_DEVICE_ATTR(GIC distributor)")?;
        set_device_attr(&device, sys::KVM_DEV_ARM_VGIC_GRP_ADDR, sys::KVM_VGIC_V3_ADDR_TYPE_REDIST, redistributor_base, "KVM_SET_DEVICE_ATTR(GIC redistributors)")?;
        set_device_attr(
            &device,
            sys::KVM_DEV_ARM_VGIC_GRP_NR_IRQS,
            0,
            &mut spi_count as *mut u32 as u64,
            "KVM_SET_DEVICE_ATTR(GIC IRQ count)",
        )?;
        *self.state.gic.lock().unwrap() = Some(device);
        Ok(GicLayout {
            distributor_base,
            distributor_size: sys::KVM_VGIC_V3_DIST_SIZE,
            redistributor_base,
            redistributor_region_size: sys::KVM_VGIC_V3_REDIST_SIZE * vcpu_count as u64,
            redistributor_size: sys::KVM_VGIC_V3_REDIST_SIZE,
            spi_base: 32,
            spi_count: 992,
            virtual_timer_intid: 27, // PPI: the EL1 virtual timer
        })
    }

    /// Alignment requirements for the GIC frames.
    pub fn gic_alignment() -> Result<(u64, u64)> {
        Ok((sys::KVM_VGIC_V3_DIST_SIZE, sys::KVM_VGIC_V3_REDIST_SIZE))
    }

    /// Raises or lowers a shared peripheral interrupt (device interrupt line).
    pub fn set_spi(&self, intid: u32, level: bool) -> Result<()> {
        self.state.set_spi(intid, level)
    }
}

fn set_device_attr(device: &File, group: u64, attr: u64, addr: u64, call: &'static str) -> Result<()> {
    let mut payload = sys::kvm_device_attr { flags: 0, group: group as u32, attr, addr };
    check(call, unsafe {
        libc::ioctl(device.as_raw_fd(), sys::KVM_SET_DEVICE_ATTR as libc::c_ulong, &mut payload as *mut _ as libc::c_ulong)
    })
    .map(|_| ())
}

impl VmState {
    /// Adds or replaces a memory slot. `write` false maps read-only.
    fn set_region(&self, guest_address: u64, host: *mut u8, len: usize, write: bool) -> Result<()> {
        if len > 0 {
            assert!(
                guest_address % 4096 == 0 && host as usize % 4096 == 0,
                "regions must be 4096-byte page aligned"
            );
        }
        let mut regions = self.regions.lock().unwrap();
        let id = match regions.slots.iter().position(|slot| slot.guest == guest_address) {
            Some(position) => {
                let slot = regions.slots[position];
                if len > 0 && slot.len != len {
                    return Err(Error { call: "map", code: libc::EINVAL });
                }
                if len == 0 {
                    regions.slots.remove(position);
                }
                slot.id
            }
            None => {
                let id = regions.next_id;
                regions.next_id += 1;
                regions.slots.push(Slot { guest: guest_address, len, host: host as usize, id });
                id
            }
        };
        drop(regions);
        self.write_region(id, guest_address, host, len, write)
    }

    /// Removes the slot at `guest_address` (a no-op if it is not there).
    fn remove_region(&self, guest_address: u64) -> Result<()> {
        let mut regions = self.regions.lock().unwrap();
        let Some(position) = regions.slots.iter().position(|slot| slot.guest == guest_address) else {
            return Ok(());
        };
        let slot = regions.slots.remove(position);
        drop(regions);
        self.write_region(slot.id, slot.guest, std::ptr::null_mut(), 0, false)
    }

    /// Toggles the write permission of the slot covering the range.
    fn protect(&self, guest_address: u64, len: usize, write: bool) -> Result<()> {
        let regions = self.regions.lock().unwrap();
        let Some(slot) = regions.slots.iter().copied().find(|slot| slot.guest == guest_address && slot.len == len) else {
            return Err(Error { call: "protect", code: libc::EINVAL });
        };
        self.write_region(slot.id, slot.guest, slot.host as *mut u8, slot.len, write)
    }

    fn write_region(&self, id: u32, guest_address: u64, host: *mut u8, len: usize, write: bool) -> Result<()> {
        let region = sys::kvm_userspace_memory_region {
            slot: id,
            flags: if write { 0 } else { sys::KVM_MEM_READONLY },
            guest_phys_addr: guest_address,
            memory_size: len as u64,
            userspace_addr: host as u64,
        };
        check("KVM_SET_USER_MEMORY_REGION", unsafe {
            libc::ioctl(self.fd.as_raw_fd(), sys::KVM_SET_USER_MEMORY_REGION as libc::c_ulong, &region as *const _ as libc::c_ulong)
        })
        .map(|_| ())
    }

    fn set_spi(&self, intid: u32, level: bool) -> Result<()> {
        if intid < 32 {
            return Ok(()); // SGIs/PPIs are the guest's own business
        }
        let line = sys::kvm_irq_level {
            irq: (sys::KVM_ARM_IRQ_TYPE_SPI << sys::KVM_ARM_IRQ_TYPE_SHIFT) | (intid - 32),
            level: level as u32,
        };
        check("KVM_IRQ_LINE", unsafe {
            libc::ioctl(self.fd.as_raw_fd(), sys::KVM_IRQ_LINE as libc::c_ulong, &line as *const _ as libc::c_ulong)
        })
        .map(|_| ())
    }
}

/// Raises or lowers a shared peripheral interrupt of the process's VM. Safe
/// to call from any thread once the GIC exists.
pub fn set_spi(intid: u32, level: bool) -> Result<()> {
    let state = process_vm("set_spi")?;
    state.set_spi(intid, level)
}

/// Maps `len` bytes of host memory at `host` into the process's VM at
/// `guest_address`, from any thread while the vCPUs run: device memory the
/// guest reaches directly, such as GPU buffers. A free function because the
/// process has one VM, so device threads need no `Vm`. Host address, guest
/// address and length must be multiples of the host page size (4 KiB).
///
/// # Safety
/// The memory must stay allocated, with at least `protection`, until `unmap`
/// removes the range (or the VM is destroyed): the guest reads and writes it.
pub unsafe fn map_host(host: *mut u8, guest_address: u64, len: usize, protection: Protection) -> Result<()> {
    let state = process_vm("map_host")?;
    state.set_region(guest_address, host, len, protection.write)
}

/// Removes a guest range of the process's VM mapped with `map_host`.
pub fn unmap(guest_address: u64, _len: usize) -> Result<()> {
    let state = process_vm("unmap")?;
    state.remove_region(guest_address)
}

impl Drop for Vm {
    fn drop(&mut self) {
        // Release the process slot, like Hypervisor.framework's hv_vm_destroy.
        *PROCESS_VM.lock().unwrap() = None;
    }
}

/// A vCPU id that other threads may use to kick the vCPU out of `run`.
#[derive(Debug, Clone, Copy)]
pub struct VcpuHandle(u32);

impl VcpuHandle {
    pub fn kick(self) -> Result<()> {
        kick_vcpu(self.0)
    }

    /// Makes every listed vCPU return from `run` (or skip its next run).
    pub fn kick_all(handles: &[VcpuHandle]) -> Result<()> {
        for handle in handles {
            handle.kick()?;
        }
        Ok(())
    }
}

fn kick_vcpu(index: u32) -> Result<()> {
    let state = process_vm("kick")?;
    let registration = state
        .runs
        .lock()
        .unwrap()
        .get(index as usize)
        .copied()
        .flatten()
        .ok_or(Error { call: "kick", code: libc::ESRCH })?;
    // Make even a not-yet-entered KVM_RUN return at once, then interrupt the
    // running one. The flag is cleared at the next run's entry.
    unsafe { (*registration.run.as_ptr()).immediate_exit = 1 };
    check("pthread_kill", unsafe { libc::pthread_kill(registration.thread, kick_signal()) }).map(|_| ())
}

/// A virtual CPU. Create it on its vCPU thread: it is neither `Send` nor
/// `Sync`, and its run page and PSCI state belong to that thread.
pub struct Vcpu {
    state: Arc<VmState>,
    index: u32,
    fd: File,
    run: NonNull<sys::kvm_run>,
    _thread_bound: PhantomData<*const ()>,
}

impl Vcpu {
    /// Creates vCPU `index` (0 = boot) on the calling thread. The index
    /// drives the kernel's default MPIDR and GIC affinity; Hypervisor.framework
    /// ignores it. The kernel creates arm64 vCPUs stopped: the boot vCPU is
    /// made runnable here, the others park inside `run` until the guest's
    /// PSCI CPU_ON.
    pub fn new(vm: &Vm, index: u32) -> Result<Vcpu> {
        let fd = check("KVM_CREATE_VCPU", unsafe {
            libc::ioctl(vm.state.fd.as_raw_fd(), sys::KVM_CREATE_VCPU as libc::c_ulong, index as libc::c_ulong)
        })?;
        let fd = unsafe { File::from_raw_fd(fd as RawFd) };
        let run = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                vm.state.vcpu_mmap_size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd.as_raw_fd(),
                0,
            )
        };
        if run == libc::MAP_FAILED {
            return Err(errno("mmap kvm_run"));
        }
        let run = NonNull::new(run.cast::<sys::kvm_run>()).unwrap();
        // The generic v8 target, with PSCI 0.2 in the kernel.
        let mut init = sys::kvm_vcpu_init { target: sys::KVM_ARM_TARGET_GENERIC_V8, features: [0; 7] };
        init.features[0] |= 1 << sys::KVM_ARM_VCPU_PSCI_0_2;
        check("KVM_ARM_VCPU_INIT", unsafe {
            libc::ioctl(fd.as_raw_fd(), sys::KVM_ARM_VCPU_INIT as libc::c_ulong, &init as *const _ as libc::c_ulong)
        })?;
        if index == 0 {
            let state = sys::kvm_mp_state { mp_state: sys::KVM_MP_STATE_RUNNABLE };
            check("KVM_SET_MP_STATE", unsafe {
                libc::ioctl(fd.as_raw_fd(), sys::KVM_SET_MP_STATE as libc::c_ulong, &state as *const _ as libc::c_ulong)
            })?;
        }
        let thread = unsafe { libc::pthread_self() };
        let mut runs = vm.state.runs.lock().unwrap();
        if runs.len() <= index as usize {
            runs.resize(index as usize + 1, None);
        }
        runs[index as usize] = Some(Registration { thread, run });
        drop(runs);
        Ok(Vcpu { state: vm.state.clone(), index, fd, run, _thread_bound: PhantomData })
    }

    pub fn handle(&self) -> VcpuHandle {
        VcpuHandle(self.index)
    }

    /// Runs the guest until it exits.
    pub fn run(&mut self) -> Result<Exit> {
        self.ensure_gic_init()?;
        let run = self.run.as_ptr();
        unsafe { (*run).immediate_exit = 0 };
        let result = unsafe { libc::ioctl(self.fd.as_raw_fd(), sys::KVM_RUN as libc::c_ulong, 0) };
        if result < 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                return Ok(Exit::Canceled); // a kick, or a stray signal
            }
            return Err(os_error("KVM_RUN", error));
        }
        let reason = unsafe { (*run).exit_reason };
        Ok(match reason {
            sys::KVM_EXIT_MMIO => {
                let access = unsafe { (*run).exit.mmio };
                Exit::Mmio(MmioAccess {
                    address: access.phys_addr,
                    size: access.len as u8,
                    write: access.is_write != 0,
                    // The kernel moves the data itself on re-entry, so no
                    // register number applies (31 = XZR, nothing to set).
                    register: 31,
                    sign_extend: false,
                    sixty_four: false,
                    data: u64::from_le_bytes(access.data),
                    advance_pc: false,
                })
            }
            sys::KVM_EXIT_ARM_NISV => Exit::DataAbortWithoutSyndrome { address: unsafe { (*run).exit.arm_nisv.fault_ipa } },
            sys::KVM_EXIT_SYSTEM_EVENT => {
                let event = unsafe { (*run).exit.system_event };
                Exit::SystemEvent { reset: event.type_ == sys::KVM_SYSTEM_EVENT_RESET }
            }
            // A kick with the immediate-exit flag set lands here; EINTR above
            // covers the same from a signal mid-ioctl.
            sys::KVM_EXIT_INTR => Exit::Canceled,
            // FAIL_ENTRY and INTERNAL_ERROR mean the vCPU state or the
            // kernel is broken; report them as the other backend would an
            // unrecognized reason.
            other => Exit::Unknown(other),
        })
    }

    /// Initializes the in-kernel GIC once, from the first vCPU that runs:
    /// by then all vCPUs (and so all redistributors) exist.
    fn ensure_gic_init(&self) -> Result<()> {
        if self.state.gic_ready.load(Ordering::Acquire) {
            return Ok(());
        }
        let device = self.state.gic.lock().unwrap();
        if self.state.gic_ready.load(Ordering::Relaxed) {
            return Ok(()); // another vCPU won the race while we took the lock
        }
        let Some(device) = device.as_ref() else { return Ok(()) }; // no GIC: the tiny probe
        set_device_attr(device, sys::KVM_DEV_ARM_VGIC_GRP_CTRL, sys::KVM_DEV_ARM_VGIC_CTRL_INIT, 0, "KVM_SET_DEVICE_ATTR(VGIC init)")?;
        self.state.gic_ready.store(true, Ordering::Release);
        Ok(())
    }

    /// X0..X30 (`index` 0–30); 31 reads XZR as zero.
    pub fn x(&self, index: u32) -> Result<u64> {
        if index >= 31 {
            return Ok(0);
        }
        self.reg(sys::core_reg(2 * index as u64))
    }

    pub fn set_x(&self, index: u32, value: u64) -> Result<()> {
        if index >= 31 {
            return Ok(());
        }
        self.set_reg(sys::core_reg(2 * index as u64), value)
    }

    pub fn pc(&self) -> Result<u64> {
        self.reg(sys::core_reg(sys::CORE_PC))
    }

    pub fn set_pc(&self, value: u64) -> Result<()> {
        self.set_reg(sys::core_reg(sys::CORE_PC), value)
    }

    pub fn set_cpsr(&self, value: u64) -> Result<()> {
        self.set_reg(sys::core_reg(sys::CORE_PSTATE), value)
    }

    /// Reads the register with the full KVM id (`core_reg`/`arm64_sysreg`).
    pub fn reg(&self, id: u64) -> Result<u64> {
        let mut value = 0u64;
        let mut one = sys::kvm_one_reg { id, addr: &mut value as *mut u64 as u64 };
        check("KVM_GET_ONE_REG", unsafe {
            libc::ioctl(self.fd.as_raw_fd(), sys::KVM_GET_ONE_REG as libc::c_ulong, &mut one as *mut _ as libc::c_ulong)
        })?;
        Ok(value)
    }

    pub fn set_reg(&self, id: u64, value: u64) -> Result<()> {
        let mut one = sys::kvm_one_reg { id, addr: &value as *const u64 as u64 };
        check("KVM_SET_ONE_REG", unsafe {
            libc::ioctl(self.fd.as_raw_fd(), sys::KVM_SET_ONE_REG as libc::c_ulong, &mut one as *mut _ as libc::c_ulong)
        })
        .map(|_| ())
    }

    /// Reads a system register by its 16-bit Hypervisor.framework encoding
    /// (the `hvf` wrapper's constants); the kernel ids that differ are
    /// translated (`sys::sysreg_id`). MPIDR is accepted before the first run
    /// and overrides the kernel's index-derived value.
    pub fn sys_reg(&self, reg: u16) -> Result<u64> {
        self.reg(sys::sysreg_id(reg))
    }

    pub fn set_sys_reg(&self, reg: u16, value: u64) -> Result<()> {
        self.set_reg(sys::sysreg_id(reg), value)
    }

    /// The offset in hvf's contract, CNTVCT = host counter - offset. KVM
    /// exposes no host counter and no readable offset, so this returns the
    /// software offset `set_vtimer_offset` has installed (0 until the first
    /// pause).
    pub fn vtimer_offset(&self) -> Result<u64> {
        Ok(*self.state.vtimer_offset.lock().unwrap())
    }

    /// Sets the offset: the guest's counter moves back by the change, as
    /// while it was paused. Translated to an absolute counter write.
    pub fn set_vtimer_offset(&self, offset: u64) -> Result<()> {
        let previous = {
            let mut slot = self.state.vtimer_offset.lock().unwrap();
            let previous = *slot;
            *slot = offset;
            previous
        };
        let delta_ns = offset.wrapping_sub(previous);
        if delta_ns == 0 {
            return Ok(());
        }
        let frequency = self.counter_frequency()?;
        let delta_ticks = ((delta_ns as u128) * frequency as u128 / 1_000_000_000) as u64;
        let now = self.reg(sys::KVM_REG_ARM_TIMER_CNT)?;
        // verify: writing KVM_REG_ARM_TIMER_CNT sets the counter now, the
        // way QEMU's kvm-adjvtime does.
        self.set_reg(sys::KVM_REG_ARM_TIMER_CNT, now.wrapping_sub(delta_ticks))
    }

    fn counter_frequency(&self) -> Result<u64> {
        if let Some(frequency) = self.state.counter_frequency.get() {
            return Ok(*frequency);
        }
        let frequency = self.reg(sys::KVM_REG_ARM_CNTFRQ_EL0)?;
        let _ = self.state.counter_frequency.set(frequency);
        Ok(frequency)
    }

    pub fn set_vtimer_mask(&self, masked: bool) -> Result<()> {
        let _ = masked;
        // The in-kernel timer hands its interrupt to the (also in-kernel)
        // GIC; there is nothing to mask in user space.
        Ok(())
    }

    pub fn set_pending_irq(&self, pending: bool) -> Result<()> {
        let _ = pending;
        // Same: the in-kernel GIC.
        Ok(())
    }

    /// Moves past the instruction that trapped (MMIO, system register access).
    pub fn advance_pc(&self) -> Result<()> {
        self.set_pc(self.pc()? + 4)
    }

    /// Hands the read value of an `Exit::Mmio` load back to the guest: KVM
    /// applies the bytes on re-entry and skips the instruction itself, so a
    /// load's data goes straight into the run page and a store needs nothing.
    pub fn complete_mmio(&self, access: &MmioAccess, value: u64) -> Result<()> {
        if access.write {
            return Ok(());
        }
        let run = self.run.as_ptr();
        unsafe { (*run).exit.mmio.data = value.to_le_bytes() };
        Ok(())
    }
}

impl Drop for Vcpu {
    fn drop(&mut self) {
        // Unregister the kick target before the run page goes away with the
        // vCPU fd.
        let mut runs = self.state.runs.lock().unwrap();
        if runs.len() > self.index as usize {
            runs[self.index as usize] = None;
        }
        drop(runs);
        unsafe { libc::munmap(self.run.as_ptr().cast(), self.state.vcpu_mmap_size) };
    }
}
