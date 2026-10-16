# hvf: Avo's Hypervisor.framework backend

Standalone Rust crates for the engine work in [docs/engine.md](../../docs/engine.md),
shaped to move into crosvm's `hypervisor` crate:

- `hvf-sys`: hand-written bindings to `Hypervisor.framework` (arm64: VM,
  memory, vCPUs, in-kernel GICv3 from macOS 15).
- `hvf`: safe wrapper — `Vm`, `GuestRegion` (16 KiB pages), thread-bound
  `Vcpu`, exit and ESR decoding (MMIO, HVC/SMC, WFI, system registers).
- `probe` (`avo-hvf-probe`): milestone checks.

Binaries that create VMs need the `com.apple.security.hypervisor`
entitlement; `.cargo/config.toml` routes `cargo run` and `cargo test` through
`run-signed.sh`, which signs ad hoc before running.

```sh
cargo test                                         # includes a real guest run (milestone 1)
cargo run --release -p avo-hvf-probe -- tiny       # milestone 1
gunzip -c <kernel-ranchu> > Image                  # e.g. from the Android SDK system image
AVO_INITRD=<ramdisk.img> cargo run --release -p avo-hvf-probe -- linux Image 20   # milestone 2
```

## Results (macOS 27, Apple Silicon)

- **Milestone 1** — a hand-assembled AArch64 guest runs; its MMIO store and
  PSCI `SYSTEM_OFF` (HVC) are trapped and decoded.
- **Milestone 2** — the Android 16 GKI kernel (`6.12.81-android16`, 16 KiB
  pages, from the Android SDK's API 37 arm64 image) boots to its console in
  under 300 ms on one vCPU: PSCI 1.0 over HVC, HVF's in-kernel GICv3
  (redistributor found, 988 SPIs), the 24 MHz virtual arch timer, the LZ4
  initramfs unpacked, and Android's first-stage `init` starts and loads its
  virtio modules. It then stops (exit 127) because the probe has no virtio
  devices yet — the next step is crosvm's virtio-mmio devices on this backend.
