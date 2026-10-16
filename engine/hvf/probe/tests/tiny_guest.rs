//! Milestone 1 as a test: runs real guest code with Hypervisor.framework.
//! Needs Apple Silicon and the hypervisor entitlement (the cargo runner signs
//! the test binary, see .cargo/config.toml).

use hvf::{ExceptionClass, Exit, GuestRegion, Protection, Vcpu, Vm, decode_exception};

#[test]
fn tiny_guest_traps_mmio_and_psci() {
    let vm = Vm::new(None).expect("hv_vm_create (is the binary signed with the hypervisor entitlement?)");
    let ram = GuestRegion::new(0x8000_0000, 1 << 20).unwrap();
    let code: [u32; 7] = [0xD282_4680, 0xD2A1_2001, 0xF900_0020, 0xD280_0100, 0xF2B0_8000, 0xD400_0002, 0x1400_0000];
    ram.write(0x8000_0000, &code.iter().flat_map(|w| w.to_le_bytes()).collect::<Vec<_>>());
    vm.map(&ram, Protection::RWX).unwrap();
    let mut vcpu = Vcpu::new(&vm).unwrap();
    vcpu.set_pc(0x8000_0000).unwrap();
    vcpu.set_cpsr(0x3c5).unwrap();

    let Exit::Exception { syndrome, physical_address, .. } = vcpu.run().unwrap() else { panic!("expected MMIO") };
    let ExceptionClass::Mmio(access) = decode_exception(syndrome, physical_address) else { panic!("expected MMIO") };
    assert_eq!((access.address, access.size, access.write), (0x0900_0000, 8, true));
    assert_eq!(vcpu.x(access.register).unwrap(), 0x1234);
    vcpu.advance_pc().unwrap();

    let Exit::Exception { syndrome, physical_address, .. } = vcpu.run().unwrap() else { panic!("expected HVC") };
    assert_eq!(decode_exception(syndrome, physical_address), ExceptionClass::Hvc(0));
    assert_eq!(vcpu.x(0).unwrap(), 0x8400_0008); // PSCI SYSTEM_OFF
}
