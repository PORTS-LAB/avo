# engine/hvf: Avo's VM engine

A Cargo workspace with everything that runs Android on the Mac. The design,
the devices and the daemon contract are described in
[docs/engine.md](../../docs/engine.md).

| Crate | What it is |
| --- | --- |
| `hvf-sys` | Hand-written bindings to `Hypervisor.framework` (arm64: VM, memory, vCPUs, the in-kernel GICv3 of macOS 15). |
| `hvf` | Safe wrapper: `Vm`, `GuestRegion` (16 KiB pages), thread-bound `Vcpu`, exit and ESR decoding (MMIO, HVC/SMC, WFI, system registers). |
| `vmm` (`avo-vmm`) | The engine Avo ships: boots an AOSP Cuttlefish arm64 image with virtio-pci block, console, rng, vsock, gpu (2D or gfxstream 3D), input, net, sound and fs devices, plus GNSS, sensors and a modem simulator. |
| `probe` (`avo-hvf-probe`) | Bring-up checks: a tiny hand-assembled guest, and a bare kernel boot to first-stage `init`. |

Binaries that create VMs need the `com.apple.security.hypervisor`
entitlement; `.cargo/config.toml` routes `cargo run` and `cargo test` through
`run-signed.sh`, which signs ad hoc before running. Avo's Xcode build compiles
avo-vmm and places it at `Avo.app/Contents/MacOS/avo-vmm`.

```sh
cargo test                                   # unit tests and a real guest run
AVO_VMM_MUTE=1 cargo test -p avo-vmm         # the same, without sound on the Mac's speakers
cargo build --release -p avo-vmm
target/release/avo-vmm cuttlefish <image dir> --instance <dir> --gpu gfxstream \
  --gfxstream-dir ~/Library/Android/sdk/emulator
```

`scripts/fetch-cuttlefish.sh` downloads a Cuttlefish image to try it by hand;
in normal use the Setup Assistant does this. Every option is documented at
the top of `vmm/src/main.rs`.

The crates are BSD-3-Clause (see each `Cargo.toml`).
