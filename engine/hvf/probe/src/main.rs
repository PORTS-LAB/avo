//! Milestone checks for the HVF backend (docs/engine.md).
//!
//!   cargo run -p avo-hvf-probe -- tiny                 # milestone 1: MMIO + PSCI from a tiny guest
//!   cargo run -p avo-hvf-probe -- linux <Image> [secs] # milestone 2: boot a kernel to its console

mod fdt;
mod linux;

use hv::{Exit, GuestRegion, Protection, Vcpu, Vm};
use std::process::ExitCode;

const RAM_BASE: u64 = 0x8000_0000;
const MMIO_PROBE: u64 = 0x0900_0000;
const PSCI_SYSTEM_OFF: u64 = 0x8400_0008;

/// Little-endian AArch64 machine code: store 0x1234 to MMIO_PROBE, then
/// PSCI SYSTEM_OFF through HVC.
const TINY_GUEST: [u32; 7] = [
    0xD282_4680, // movz x0, #0x1234
    0xD2A1_2001, // movz x1, #0x0900, lsl #16
    0xF900_0020, // str  x0, [x1]
    0xD280_0100, // movz x0, #0x0008
    0xF2B0_8000, // movk x0, #0x8400, lsl #16
    0xD400_0002, // hvc  #0
    0x1400_0000, // b    .
];

/// The guest's SYSTEM_OFF ends milestone 1: the MMIO write must have landed.
fn milestone(mmio_value: Option<u64>) -> Result<(), String> {
    if mmio_value == Some(0x1234) {
        println!("milestone 1 passed: guest code ran, MMIO trapped, PSCI SYSTEM_OFF handled");
        Ok(())
    } else {
        Err(format!("unexpected MMIO value {mmio_value:?}"))
    }
}

fn tiny() -> Result<(), String> {
    let vm = Vm::new(None).map_err(|e| e.to_string())?;
    let ram = GuestRegion::new(RAM_BASE, 16 * 1024 * 1024).map_err(|e| e.to_string())?;
    let code: Vec<u8> = TINY_GUEST.iter().flat_map(|word| word.to_le_bytes()).collect();
    ram.write(RAM_BASE, &code);
    vm.map(&ram, Protection::RWX).map_err(|e| e.to_string())?;

    let mut vcpu = Vcpu::new(&vm, 0).map_err(|e| e.to_string())?;
    vcpu.set_pc(RAM_BASE).map_err(|e| e.to_string())?;
    vcpu.set_cpsr(0x3c5).map_err(|e| e.to_string())?; // EL1h, interrupts masked

    let mut mmio_value = None;
    for _ in 0..16 {
        match vcpu.run().map_err(|e| e.to_string())? {
            Exit::Mmio(access) if access.write => {
                println!("mmio write: {:#x} <- {:#x} ({} bytes)", access.address, access.data, access.size);
                if access.address == MMIO_PROBE {
                    mmio_value = Some(access.data);
                }
                if access.advance_pc {
                    vcpu.advance_pc().map_err(|e| e.to_string())?;
                }
            }
            Exit::Hvc(_) => {
                let function = vcpu.x(0).map_err(|e| e.to_string())?;
                println!("hvc: PSCI function {function:#x}");
                if function == PSCI_SYSTEM_OFF {
                    return milestone(mmio_value);
                }
            }
            Exit::SystemEvent { .. } => {
                // The kernel's PSCI answered SYSTEM_OFF (KVM).
                return milestone(mmio_value);
            }
            other => return Err(format!("unexpected exit {other:?} at pc {:#x}", vcpu.pc().unwrap_or(0))),
        }
    }
    Err("guest did not finish".into())
}

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_else(|| "tiny".into());
    let args: Vec<String> = std::env::args().skip(2).collect();
    let result = match command.as_str() {
        "tiny" => tiny(),
        "linux" => match args.first() {
            Some(kernel) => linux::boot(linux::Options {
                kernel: kernel.into(),
                initrd: std::env::var_os("AVO_INITRD").map(Into::into),
                cmdline: std::env::var("AVO_CMDLINE").unwrap_or_else(|_| {
                    "console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 keep_bootcon loglevel=8 panic=-1".into()
                }),
                ram_mib: std::env::var("AVO_RAM_MIB").ok().and_then(|v| v.parse().ok()).unwrap_or(1024),
                timeout: std::time::Duration::from_secs(args.get(1).and_then(|s| s.parse().ok()).unwrap_or(30)),
                expect: std::env::var("AVO_EXPECT").ok(),
            }),
            None => Err("usage: linux <Image> [seconds]".into()),
        },
        other => Err(format!("unknown check {other}")),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("error: {message}");
            ExitCode::FAILURE
        }
    }
}
