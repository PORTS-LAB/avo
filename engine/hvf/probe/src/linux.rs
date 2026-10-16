//! Milestone 2: boot an arm64 Linux kernel Image to its console.
//!
//! Machine: RAM at 0x8000_0000, in-kernel GICv3 (Hypervisor.framework), a
//! PL011 UART at 0x0900_0000 (enough for earlycon), PSCI over HVC, one vCPU.

use crate::fdt::{Fdt, Value};
use hvf::{ExceptionClass, Exit, GuestRegion, Protection, Vcpu, Vm, decode_exception};
use std::io::Write;
use std::time::{Duration, Instant};

const RAM_BASE: u64 = 0x8000_0000;
const UART_BASE: u64 = 0x0900_0000;
const GIC_DIST: u64 = 0x0800_0000;
const GIC_REDIST: u64 = 0x080A_0000;
const UART_SPI: u32 = 1;

pub struct Options {
    pub kernel: std::path::PathBuf,
    /// Optional initramfs (any format the kernel can unpack, e.g. LZ4).
    pub initrd: Option<std::path::PathBuf>,
    pub cmdline: String,
    pub ram_mib: usize,
    pub timeout: Duration,
    /// Stop once the console printed this text.
    pub expect: Option<String>,
}

pub fn boot(options: Options) -> Result<(), String> {
    let image = std::fs::read(&options.kernel).map_err(|e| format!("{}: {e}", options.kernel.display()))?;
    if image.len() < 64 || &image[56..60] != b"ARM\x64" {
        return Err("not an arm64 kernel Image (decompress Image.gz first)".into());
    }
    let text_offset = u64::from_le_bytes(image[8..16].try_into().unwrap());
    let image_size = u64::from_le_bytes(image[16..24].try_into().unwrap());

    let vm = Vm::new(None).map_err(|e| e.to_string())?;
    let (dist_align, redist_align) = Vm::gic_alignment().map_err(|e| e.to_string())?;
    if GIC_DIST % dist_align != 0 || GIC_REDIST % redist_align != 0 {
        return Err(format!("GIC bases misaligned (need {dist_align:#x} / {redist_align:#x})"));
    }
    let gic = vm.create_gic(GIC_DIST, GIC_REDIST).map_err(|e| e.to_string())?;
    eprintln!("[probe] GICv3: dist {:#x}+{:#x}, redist {:#x}+{:#x}, SPIs {}..{}, vtimer intid {}",
              gic.distributor_base, gic.distributor_size, gic.redistributor_base, gic.redistributor_region_size,
              gic.spi_base, gic.spi_base + gic.spi_count, gic.virtual_timer_intid);

    let ram_size = options.ram_mib * 1024 * 1024;
    let ram = GuestRegion::new(RAM_BASE, ram_size).map_err(|e| e.to_string())?;
    let kernel_address = RAM_BASE + text_offset;
    if text_offset + image_size.max(image.len() as u64) > ram_size as u64 / 2 {
        return Err("not enough RAM for the kernel".into());
    }
    ram.write(kernel_address, &image);

    // The initramfs sits in the upper half of RAM, below the device tree.
    let initrd = match &options.initrd {
        Some(path) => {
            let data = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
            let start = RAM_BASE + ram_size as u64 / 2;
            if data.len() as u64 > ram_size as u64 / 2 - 4 * 1024 * 1024 {
                return Err("initrd too large".into());
            }
            ram.write(start, &data);
            eprintln!("[probe] initrd {:.1} MiB at {start:#x}", data.len() as f64 / 1048576.0);
            Some((start, start + data.len() as u64))
        }
        None => None,
    };

    let dtb = device_tree(&options.cmdline, ram_size as u64, &gic, initrd);
    let dtb_address = RAM_BASE + ram_size as u64 - 2 * 1024 * 1024;
    ram.write(dtb_address, &dtb);
    vm.map(&ram, Protection::RWX).map_err(|e| e.to_string())?;
    eprintln!("[probe] kernel {:.1} MiB at {kernel_address:#x}, dtb {} bytes at {dtb_address:#x}",
              image.len() as f64 / 1048576.0, dtb.len());

    let mut vcpu = Vcpu::new(&vm).map_err(|e| e.to_string())?;
    vcpu.set_sys_reg(hvf::HV_SYS_REG_MPIDR_EL1, 1 << 31).map_err(|e| e.to_string())?;
    vcpu.set_pc(kernel_address).map_err(|e| e.to_string())?;
    vcpu.set_x(0, dtb_address).map_err(|e| e.to_string())?;
    for register in 1..4 {
        vcpu.set_x(register, 0).map_err(|e| e.to_string())?;
    }
    vcpu.set_cpsr(0x3c5).map_err(|e| e.to_string())?; // EL1h, DAIF masked, MMU off

    let mut uart = Pl011::default();
    let started = Instant::now();
    let mut exits = 0u64;
    let mut vtimer_exits = 0u64;
    let mut stdout = std::io::stdout();
    loop {
        if started.elapsed() > options.timeout {
            eprintln!("\n[probe] stopped after {:?} ({exits} exits, {vtimer_exits} timer exits)", options.timeout);
            return Ok(());
        }
        let exit = vcpu.run().map_err(|e| e.to_string())?;
        exits += 1;
        match exit {
            Exit::Exception { syndrome, physical_address, .. } => match decode_exception(syndrome, physical_address) {
                ExceptionClass::Mmio(access) => {
                    if access.address >= UART_BASE && access.address < UART_BASE + 0x1000 {
                        let offset = access.address - UART_BASE;
                        if access.write {
                            let value = vcpu.x(access.register).map_err(|e| e.to_string())?;
                            if let Some(byte) = uart.write(offset, value) {
                                let _ = stdout.write_all(&[byte]);
                                if byte == b'\n' {
                                    let _ = stdout.flush();
                                }
                            }
                        } else {
                            vcpu.set_x(access.register, uart.read(offset)).map_err(|e| e.to_string())?;
                        }
                        if let Some(expect) = &options.expect {
                            if uart.output.contains(expect.as_str()) {
                                let _ = stdout.flush();
                                eprintln!("\n[probe] saw \"{expect}\" after {:.2?} ({exits} exits)", started.elapsed());
                                return Ok(());
                            }
                        }
                    } else if !access.write {
                        // Unbacked device memory reads as zero; writes are dropped.
                        vcpu.set_x(access.register, 0).map_err(|e| e.to_string())?;
                    }
                    vcpu.advance_pc().map_err(|e| e.to_string())?;
                }
                ExceptionClass::Hvc(_) => {
                    if let Some(stop) = psci(&vcpu)? {
                        let _ = stdout.flush();
                        eprintln!("\n[probe] guest requested {stop} after {:.2?}", started.elapsed());
                        return Ok(());
                    }
                }
                ExceptionClass::Smc(_) => {
                    vcpu.set_x(0, u64::MAX).map_err(|e| e.to_string())?; // NOT_SUPPORTED
                    vcpu.advance_pc().map_err(|e| e.to_string())?;
                }
                ExceptionClass::WaitForInterrupt { .. } => {
                    // Idle: the in-kernel GIC and timer wake the vCPU on the next run.
                    std::thread::sleep(Duration::from_micros(200));
                    vcpu.advance_pc().map_err(|e| e.to_string())?;
                }
                ExceptionClass::SystemRegister { read, register, .. } => {
                    if read {
                        vcpu.set_x(register, 0).map_err(|e| e.to_string())?;
                    }
                    vcpu.advance_pc().map_err(|e| e.to_string())?;
                }
                other => {
                    let _ = stdout.flush();
                    return Err(format!("unhandled {other:?} at pc {:#x} (after {exits} exits)", vcpu.pc().unwrap_or(0)));
                }
            },
            Exit::VtimerActivated => {
                // With the in-kernel GIC the timer interrupt is delivered by the
                // GIC; unmask so the next expiry is reported again.
                vtimer_exits += 1;
                vcpu.set_vtimer_mask(false).map_err(|e| e.to_string())?;
            }
            Exit::Canceled => {}
            Exit::Unknown(reason) => return Err(format!("unknown exit reason {reason}")),
        }
    }
}

/// PSCI 1.0 for one vCPU. Returns Some(name) when the guest powers off or resets.
fn psci(vcpu: &Vcpu) -> Result<Option<&'static str>, String> {
    let function = vcpu.x(0).map_err(|e| e.to_string())? as u32;
    let result: i64 = match function {
        0x8400_0000 => 0x0001_0000,                     // PSCI_VERSION: 1.0
        0x8400_0008 => return Ok(Some("SYSTEM_OFF")),
        0x8400_0009 => return Ok(Some("SYSTEM_RESET")),
        0x8400_0006 => 2,                               // MIGRATE_INFO_TYPE: not required
        0x8400_000A => {
            let queried = vcpu.x(1).map_err(|e| e.to_string())? as u32;
            match queried {
                0x8400_0000 | 0x8400_0008 | 0x8400_0009 | 0x8400_0006 | 0x8400_000A => 0,
                _ => -1,
            }
        }
        0xC400_0003 | 0x8400_0003 => -4,               // CPU_ON: only one vCPU here (ALREADY_ON)
        _ => -1,                                        // NOT_SUPPORTED (SMCCC: unknown call)
    };
    vcpu.set_x(0, result as u64).map_err(|e| e.to_string())?;
    Ok(None)
}

/// Just enough PL011 for earlycon and the AMBA probe.
#[derive(Default)]
struct Pl011 {
    output: String,
    line: Vec<u8>,
}

impl Pl011 {
    fn write(&mut self, offset: u64, value: u64) -> Option<u8> {
        if offset != 0 {
            return None; // control registers: accepted and ignored
        }
        let byte = value as u8;
        self.line.push(byte);
        if byte == b'\n' {
            self.output.push_str(&String::from_utf8_lossy(&self.line));
            self.line.clear();
            if self.output.len() > 1 << 20 {
                self.output.drain(..self.output.len() / 2);
            }
        }
        Some(byte)
    }

    fn read(&self, offset: u64) -> u64 {
        match offset {
            0x018 => 0x90,                        // UARTFR: TX empty, RX empty, not busy
            0xFE0 => 0x11, 0xFE4 => 0x10, 0xFE8 => 0x34, 0xFEC => 0x00, // PeriphID: PL011 r1p5
            0xFF0 => 0x0D, 0xFF4 => 0xF0, 0xFF8 => 0x05, 0xFFC => 0xB1, // PrimeCell ID
            _ => 0,
        }
    }
}

fn device_tree(cmdline: &str, ram_size: u64, gic: &hvf::GicLayout, initrd: Option<(u64, u64)>) -> Vec<u8> {
    const GIC_PHANDLE: u32 = 1;
    const CLOCK_PHANDLE: u32 = 2;
    let split = |v: u64| [(v >> 32) as u32, v as u32];
    let mut fdt = Fdt::new();
    fdt.begin("");
    fdt.prop("compatible", Value::Str("linux,dummy-virt"));
    fdt.prop("#address-cells", Value::U32(2));
    fdt.prop("#size-cells", Value::U32(2));
    fdt.prop("interrupt-parent", Value::U32(GIC_PHANDLE));

    fdt.begin("chosen");
    fdt.prop("bootargs", Value::Str(cmdline));
    fdt.prop("stdout-path", Value::Str("/pl011@9000000"));
    if let Some((start, end)) = initrd {
        fdt.prop("linux,initrd-start", Value::Cells(&split(start)));
        fdt.prop("linux,initrd-end", Value::Cells(&split(end)));
    }
    fdt.end();

    fdt.begin("memory@80000000");
    fdt.prop("device_type", Value::Str("memory"));
    fdt.prop("reg", Value::Cells(&[split(RAM_BASE), split(ram_size)].concat()));
    fdt.end();

    fdt.begin("cpus");
    fdt.prop("#address-cells", Value::U32(1));
    fdt.prop("#size-cells", Value::U32(0));
    fdt.begin("cpu@0");
    fdt.prop("device_type", Value::Str("cpu"));
    fdt.prop("compatible", Value::Str("arm,arm-v8"));
    fdt.prop("reg", Value::U32(0));
    fdt.prop("enable-method", Value::Str("psci"));
    fdt.end();
    fdt.end();

    fdt.begin("psci");
    fdt.prop("compatible", Value::Strs(&["arm,psci-1.0", "arm,psci-0.2"]));
    fdt.prop("method", Value::Str("hvc"));
    fdt.end();

    fdt.begin("intc@8000000");
    fdt.prop("compatible", Value::Str("arm,gic-v3"));
    fdt.prop("#interrupt-cells", Value::U32(3));
    fdt.prop("interrupt-controller", Value::Empty);
    fdt.prop("#redistributor-regions", Value::U32(1));
    fdt.prop("reg", Value::Cells(&[
        split(gic.distributor_base), split(gic.distributor_size),
        split(gic.redistributor_base), split(gic.redistributor_region_size),
    ].concat()));
    fdt.prop("phandle", Value::U32(GIC_PHANDLE));
    fdt.end();

    // PPIs: secure phys 13, non-secure phys 14, virtual 11, hypervisor 10 (INTID - 16).
    fdt.begin("timer");
    fdt.prop("compatible", Value::Str("arm,armv8-timer"));
    fdt.prop("interrupts", Value::Cells(&[1, 13, 0xf08, 1, 14, 0xf08, 1, 11, 0xf08, 1, 10, 0xf08]));
    fdt.prop("always-on", Value::Empty);
    fdt.end();

    fdt.begin("apb-pclk");
    fdt.prop("compatible", Value::Str("fixed-clock"));
    fdt.prop("#clock-cells", Value::U32(0));
    fdt.prop("clock-frequency", Value::U32(24_000_000));
    fdt.prop("clock-output-names", Value::Str("clk24mhz"));
    fdt.prop("phandle", Value::U32(CLOCK_PHANDLE));
    fdt.end();

    fdt.begin("pl011@9000000");
    fdt.prop("compatible", Value::Strs(&["arm,pl011", "arm,primecell"]));
    fdt.prop("reg", Value::Cells(&[split(UART_BASE), split(0x1000)].concat()));
    fdt.prop("interrupts", Value::Cells(&[0, UART_SPI, 4]));
    fdt.prop("clocks", Value::Cells(&[CLOCK_PHANDLE, CLOCK_PHANDLE]));
    fdt.prop("clock-names", Value::Strs(&["uartclk", "apb_pclk"]));
    fdt.end();

    fdt.end();
    fdt.finish()
}
