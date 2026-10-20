/// Why `Vcpu::run` returned.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exit {
    /// Another thread kicked the vCPU.
    Canceled,
    /// The virtual timer fired; it stays masked until the guest handles it.
    VtimerActivated,
    /// A trapped load or store to guest physical memory with no mapping:
    /// the caller emulates it against the device model. On writes `data`
    /// carries the stored value (the kernel read it from the guest register);
    /// on loads `complete_mmio` hands the read value back. `advance_pc` is
    /// false: the kernel emulates and skips the instruction on re-entry.
    Mmio(MmioAccess),
    /// Data abort without syndrome information (e.g. load/store pair):
    /// cannot be emulated; the caller decides whether to skip or fail.
    DataAbortWithoutSyndrome { address: u64 },
    /// HVC #imm (PSCI calls). The PC already points past the instruction.
    Hvc(u16),
    /// SMC #imm (also used for PSCI by some guests). The PC must be advanced.
    Smc(u16),
    /// WFI or WFE: idle until an interrupt is pending.
    WaitForInterrupt { wfe: bool },
    /// MSR/MRS to a trapped system register.
    SystemRegister { read: bool, op0: u8, op1: u8, crn: u8, crm: u8, op2: u8, register: u32 },
    /// The kernel's PSCI reported power off or reset.
    SystemEvent { reset: bool },
    Other { class: u8, syndrome: u64 },
    Unknown(u32),
}

/// A trapped load or store to a guest physical address with no memory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MmioAccess {
    pub address: u64,
    /// Access size in bytes (1, 2, 4 or 8).
    pub size: u8,
    pub write: bool,
    /// Register being loaded or stored (31 = XZR). KVM does not report it:
    /// the kernel moves the data itself.
    pub register: u32,
    /// Sign-extend a load (LDRSB/LDRSH/LDRSW).
    pub sign_extend: bool,
    /// The register is 64-bit (otherwise 32-bit).
    pub sixty_four: bool,
    /// The stored value (writes).
    pub data: u64,
    /// Whether the caller must advance the PC past the trapped instruction.
    pub advance_pc: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExceptionClass {
    /// Data abort with a valid syndrome: emulate the access, then skip the instruction.
    Mmio(MmioAccess),
    /// Data abort without syndrome information (e.g. load/store pair): cannot emulate.
    DataAbortWithoutSyndrome { address: u64 },
    /// HVC #imm (PSCI calls). The PC already points past the instruction.
    Hvc(u16),
    /// SMC #imm (also used for PSCI by some guests). The PC must be advanced.
    Smc(u16),
    /// WFI or WFE: idle until an interrupt is pending.
    WaitForInterrupt { wfe: bool },
    /// MSR/MRS to a trapped system register.
    SystemRegister { read: bool, op0: u8, op1: u8, crn: u8, crm: u8, op2: u8, register: u32 },
    Other { class: u8, syndrome: u64 },
}

/// Decodes an ESR_EL2 value reported in an exception exit.
pub fn decode_exception(syndrome: u64, physical_address: u64) -> ExceptionClass {
    let class = ((syndrome >> 26) & 0x3f) as u8;
    let iss = syndrome & 0x1ff_ffff;
    match class {
        0x24 => {
            // Data abort from a lower exception level.
            if iss & (1 << 24) == 0 {
                return ExceptionClass::DataAbortWithoutSyndrome { address: physical_address };
            }
            ExceptionClass::Mmio(MmioAccess {
                address: physical_address,
                size: 1 << ((iss >> 22) & 0x3),
                sign_extend: iss & (1 << 21) != 0,
                register: ((iss >> 16) & 0x1f) as u32,
                sixty_four: iss & (1 << 15) != 0,
                write: iss & (1 << 6) != 0,
                data: 0,
                advance_pc: false,
            })
        }
        0x16 => ExceptionClass::Hvc((iss & 0xffff) as u16),
        0x17 => ExceptionClass::Smc((iss & 0xffff) as u16),
        0x01 => ExceptionClass::WaitForInterrupt { wfe: iss & 1 == 1 },
        0x18 => ExceptionClass::SystemRegister {
            read: iss & 1 == 1,
            op0: ((iss >> 20) & 0x3) as u8,
            op2: ((iss >> 17) & 0x7) as u8,
            op1: ((iss >> 14) & 0x7) as u8,
            crn: ((iss >> 10) & 0xf) as u8,
            register: ((iss >> 5) & 0x1f) as u32,
            crm: ((iss >> 1) & 0xf) as u8,
        },
        _ => ExceptionClass::Other { class, syndrome },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_64_bit_store() {
        // EC=0x24, IL=1, ISV=1, SAS=3 (8 bytes), SRT=2, SF=1, WnR=1.
        let esr = (0x24u64 << 26) | (1 << 25) | (1 << 24) | (3 << 22) | (2 << 16) | (1 << 15) | (1 << 6);
        assert_eq!(
            decode_exception(esr, 0x0900_0000),
            ExceptionClass::Mmio(MmioAccess {
                address: 0x0900_0000,
                size: 8,
                write: true,
                register: 2,
                sign_extend: false,
                sixty_four: true,
                data: 0,
                advance_pc: false,
            })
        );
    }

    #[test]
    fn decodes_hvc_and_wfi() {
        assert_eq!(decode_exception((0x16 << 26) | 7, 0), ExceptionClass::Hvc(7));
        assert_eq!(decode_exception(0x01 << 26, 0), ExceptionClass::WaitForInterrupt { wfe: false });
        assert_eq!(decode_exception((0x01 << 26) | 1, 0), ExceptionClass::WaitForInterrupt { wfe: true });
    }

    #[test]
    fn data_abort_without_syndrome_is_reported() {
        assert_eq!(
            decode_exception(0x24 << 26, 0x1000),
            ExceptionClass::DataAbortWithoutSyndrome { address: 0x1000 }
        );
    }
}
