# Linux port

Avo is macOS-only today: the engine (`avo-vmm`) is Rust on Apple's
Hypervisor.framework ([engine.md](engine.md)) and the host side is
Swift/AppKit ([architecture.md](architecture.md)). A Linux port brings the
same product to aarch64 Linux hosts: the same arm64 Cuttlefish guests on
KVM, then the daemon plumbing, then the UI. Status: planning; phase 1 has
started.

## Scope

- **aarch64 Linux first.** The guest does not change: arm64 AOSP
  Cuttlefish, booted by an aarch64 KVM backend instead of
  Hypervisor.framework. x86_64 Linux hosts are out of scope for now — the
  guest is arm64, and running it there would mean different Android builds
  or CPU emulation, a different project.
- **Engine first.** A KVM backend lands behind a new facade crate `hv` in
  the [engine/hvf workspace](../engine/hvf/README.md), which re-exports
  `hvf` on macOS and the new `kvm` crate on Linux, so `vmm` and `probe`
  build against one API. Then host plumbing: frame and audio shared memory,
  the GPU libraries, the daemon transport. Then UI: windows, notifications,
  packaging. Phases in that order; the table below says what moves when.

## Component mapping

| macOS | Linux | Phase |
| --- | --- | --- |
| Hypervisor.framework ([hvf-sys](../engine/hvf/hvf-sys), [hvf](../engine/hvf/hvf)) | KVM (aarch64); the `kvm` crate mirrors hvf's surface (`Vm`, `GuestRegion`, thread-bound `Vcpu`, exit decoding) behind `hv` | 1 |
| In-kernel GICv3 (macOS 15) | KVM's in-kernel VGIC v3 | 1 |
| mach_absolute_time + mach timebase | CLOCK_MONOTONIC nanoseconds via a small platform module | 1 |
| arc4random_buf | getrandom(2) | 1 |
| APFS clonefile | FICLONE ioctl, with a plain-copy fallback | 1 |
| CommonCrypto CC_SHA256 | the sha2 crate | 1 |
| pthread_set_qos_class_self_np (engine threads to user-initiated) | no-op, optionally nice/ioprio | 1 |
| hypervisor entitlement + codesign + run-signed.sh (engine/hvf/README.md) | /dev/kvm access via the kvm group, no signing | 1 |
| macOS 15+ on Apple silicon | any aarch64 host with arm64 KVM (in-kernel VGIC, PSCI 0.2+) — Ampere, Graviton, Snapdragon X, Raspberry Pi 5 class | 1 |
| IOSurface frame sharing (`vmm/src/frames.rs`) | POSIX shared memory with the same ring protocol; the reader maps it as plain memory, no Metal | 2 |
| gfxstream host dylibs from the Android Emulator (`lib64/*.dylib`, loaded by absolute path) | the emulator's Linux `.so` equivalents, loaded the same way, without the signing gate | 2 |
| MoltenVK | the system Vulkan loader | 2 |
| Metal shader-cache SPI (`virtio/gpu/cache.rs`, `MTLSetShaderCachePath`) | gfxstream's own caching; the Control Panel's cache view and Clear follow in phase 3 | 2 |
| Pause's vtimer offset (`hv_vcpu_set_vtimer_offset`; engine.md, "Pause") | KVM one-reg write of the guest vtimer count while the vCPUs are stopped | 2 |
| CoreAudio output and capture (`virtio/sound.rs`) | PipeWire/ALSA behind a small host-audio trait, a null backend first (audio dropped, timing kept) | 2/3 |
| XPC Mach service + LaunchAgent/SMAppService | Unix-domain sockets + systemd user units | 3 |
| AppKit Control Panel + AvoWindowHost app shims + CAMetalLayer windows | GTK4 or winit with Vulkan surfaces | 3 |
| UNUserNotificationCenter | org.freedesktop.Notifications | 3 |
| Sparkle updates | distro packages / AppImage | 3 |
| `.app` bundles + per-app shims in `~/Applications` | `.desktop` launcher entries + a shim binary in `~/.local/share` | 3 |

Notes:

- `hv` is chosen by the compile target (`cfg(target_os)`), not by a Cargo
  feature, so a build for one OS always has exactly one backend.
- The frame rings are already plain shared files on the writer side
  ([engine.md](engine.md), "Frames"); only the macOS reader changes.
- The host-audio trait exists to keep the device's own-clock playback logic
  platform-free ([engine.md](engine.md), "Sound"); only the enqueue path is
  a backend, and the null one answers every period on time with its
  simulated clock, as the MMAP stubs already do.
- Phase 3 is the largest chunk by far: the Swift/AppKit code does not port;
  GTK4 or winit is a rewrite, not an adaptation.

## Already portable

- **`guest/` Android-side helpers** — clipboard, links, macstate,
  fingerprint, gpuprofile and gfxsync are dex jars and small C that run
  inside Android over ADB; none of them touches the Mac.
- **`proto/`** — one protobuf host↔guest protocol with test vectors; the
  same bytes on either OS.
- **`profiles/`** — device profiles and keymap templates are JSON; plain
  files with no platform bits.
- **The smoltcp user-mode network stack** — user-mode NAT over ordinary
  host sockets; guest TCP ends in engine sockets, unprivileged ICMP and
  reading `/etc/resolv.conf` are POSIX.
- **All virtio device models** — block, console, rng, vsock, gpu, input,
  net, sound, fs sit on the bus and ring abstractions and see the same MMIO
  exits whichever backend runs the vCPU; none of them calls HVF.
- **The FDT builder** — emits the guest device tree from the machine
  configuration; the same tree boots the same kernel over either backend.
- **The Cuttlefish boot flow** — composite GPT disk built from sparse
  images, A/B slots, ramdisk cpio, bootconfig; file and image work, no
  hypervisor in sight.
- **The control-socket protocol** — one text command per line over a Unix
  socket ([engine.md](engine.md)); already POSIX.
- **Hybrid virtio-vsock** — the Firecracker `CONNECT <port>` convention
  over one Unix socket was POSIX already; ADB over vsock carries over
  untouched.

## Phases

### Phase 1: engine — KVM behind `hv`

The `hv` facade, the `kvm` crate (aarch64 `/dev/kvm` bindings and a safe
wrapper shaped like hvf), the in-kernel VGIC v3 and the platform module
(time, randomness, FICLONE, sha2, a QoS stub); no signing machinery
targeting Linux, and `vmm`/`probe` compiling for both OSes from one source.
Cuttlefish does not boot yet; the probes do.

**Done when:** `cargo test` passes on Linux, and the probe harness boots an
arm64 Linux kernel to console output through KVM on an aarch64 host.

### Phase 2: plumbing — frames, sound, GPU

The device model runs on Linux end to end, still driven by hand:
`avo-vmm cuttlefish <image dir>` (`scripts/fetch-cuttlefish.sh` still
fetches the image). Frame rings in POSIX shared memory with a reader that
maps them as ordinary memory; gfxstream 3D through the emulator's Linux
libraries over the system Vulkan loader; the host-audio trait with the null
backend first; the pause vtimer adjustment; the GPU's BAR2 mapped as KVM
host memory.

**Done when:** Cuttlefish boots with software rendering and frames reach a
reader through shared memory.

### Phase 3: host — daemon and UI

The daemon over Unix-domain sockets carrying the XPC roles (`hello`,
per-role checks; caller validation is rethought for the absence of code
signatures — socket credentials and paths instead), run as a systemd user
unit where the LaunchAgent was. The Control Panel and the per-app window
shims rewritten on GTK4 or winit, presenting the frame rings; org.freedesktop.Notifications; `.desktop` entries; packaging as
distro packages or an AppImage.

**Done when:** the daemon and UI run apps end to end — an installed app
opens in its own window, input and sound reach it, and notifications arrive
on the Linux side.

## Open questions

- **Page size.** vmm builds guest memory in 16 KiB `GuestRegion`s and maps
  the GPU's BAR2 in whole 16 KiB pages ([engine/hvf/README.md](../engine/hvf/README.md),
  [engine.md](engine.md), "GPU"). Linux aarch64 hosts mostly run 4 KiB
  kernels (Raspberry Pi 5's stock kernel is 16 KiB), and KVM maps guest
  memory at the host page size. Decide whether 16 KiB stays the minimum
  granularity or becomes a runtime constant.
- **CNTFRQ variation.** arm64 SoCs set the counter frequency differently
  (19.2 MHz on many Qualcomm platforms, 54 MHz on Raspberry Pi, other rates
  elsewhere). Timer math — sound period pacing, the pause offset — must
  read the guest's counter frequency rather than hardcode 24 MHz.
- **Gfxstream .so availability.** Whether arm64 Linux builds of the Android
  Emulator with the gfxstream host libraries exist and which versions carry
  them; until then the port is software-rendered.
- **Frame transport under Wayland vs X11.** How a shim presents: a Vulkan
  surface through the compositor on Wayland, shm or damage on X11, or both
  — decided when the UI is built, phase 3.
- **Multiple VMs per process.** KVM admits several VMs in one process
  where Hypervisor.framework allows one; keep the one-process-per-model of
  the macOS daemon, or take advantage of it later (several instances in one
  engine process)?
