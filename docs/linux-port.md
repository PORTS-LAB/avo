# Linux port

Avo is macOS-only today: the engine (`avo-vmm`) is Rust on Apple's
Hypervisor.framework ([engine.md](engine.md)) and the host side is
Swift/AppKit ([architecture.md](architecture.md)). A Linux port brings the
same product to aarch64 Linux hosts: the same arm64 Cuttlefish guests on
KVM, then the daemon plumbing, then the UI. Status: the engine code for
phase 1 and the host-side part of phase 2 is in (the `linux-port` branch —
both targets compile, host tests green); runtime bring-up waits for real
aarch64 KVM hardware (the `// verify:` marks say what to check there).

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
| mach_absolute_time + mach timebase | done — CLOCK_MONOTONIC nanoseconds (`pause::host_ticks`); the vtimer and tap math read it | 1 |
| arc4random_buf | done — getrandom(2), the urandom file behind it | 1 |
| APFS clonefile | done — FICLONE ioctl, with a plain-copy fallback | 1 |
| CommonCrypto CC_SHA256 | done — the sha2 crate | 1 |
| pthread_set_qos_class_self_np (engine threads to user-initiated) | done — no-op off the Mac (nice/ioprio if wanted later) | 1 |
| hypervisor entitlement + codesign + run-signed.sh (engine/hvf/README.md) | /dev/kvm access via the kvm group, no signing | 1 |
| macOS 15+ on Apple silicon | any aarch64 host with arm64 KVM (in-kernel VGIC, PSCI 0.2+) — Ampere, Graviton, Snapdragon X, Raspberry Pi 5 class | 1 |
| IOSurface frame sharing (`vmm/src/frames.rs`) | no engine change needed — the ring is a plain mmap'd shared file already (verified); the reader side follows in phase 3 | 2 |
| gfxstream host dylibs from the Android Emulator (`lib64/*.dylib`, loaded by absolute path) | done — the loader takes `.so` the same way (`// verify:` against a real Linux emulator package) | 2 |
| MoltenVK | done — off the Mac the loader picks the host ICD itself | 2 |
| Metal shader-cache SPI (`virtio/gpu/cache.rs`, `MTLSetShaderCachePath`) | done — the Metal/CF machinery is macOS-only; prepare() no-ops and the cache root follows XDG off the Mac; the Control Panel's cache view follows in phase 3 | 2 |
| Pause's vtimer offset (`hv_vcpu_set_vtimer_offset`; engine.md, "Pause") | done — the kvm backend turns nanosecond deltas into counter ticks (via CNTFRQ) and wait_for_interrupt reads the kernel's counter (`// verify:` on hardware) | 2 |
| CoreAudio output and capture (`virtio/sound.rs`) | done — the host's default PCM through libasound, dlopen'd (the GPU libraries' way): the clock writes each accepted period, the tap stamps the playhead's remaining distance as its host time; null-quiet where the library, device, or AVO_VMM_MUTE is absent. `AVO_TEST_ALSA=1 cargo test -p avo-vmm alsa` ran green on x86_64 against a live PipeWire server (playback, underrun recovery, freeze/thaw, capture); mic-time on real hardware — `// verify:` | 2/3 |
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
- The device's own-clock playback logic is platform-free: the split sits at
  the queue, not the clock. Linux's null backend drops the audio as it is
  made and answers the tap with what the clock consumed; the trait-ization
  comes with PipeWire/ALSA.
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
libraries over the system Vulkan loader; audio through the host's default
PCM via dlopen'd libasound (usually the PipeWire server's ALSA emulation),
the null backend where there is none; the pause vtimer adjustment; the
GPU's BAR2 mapped as KVM host memory.

**Done when:** Cuttlefish boots with software rendering and frames reach a
reader through shared memory.

### Phase 3: host — daemon and UI

The daemon over Unix-domain sockets carrying the XPC roles (`hello`,
per-role checks; caller validation is rethought for the absence of code
signatures — socket credentials and paths instead), run as a systemd user
unit where the LaunchAgent was. The Control Panel and the per-app window
shims rewritten on GTK4 or winit, presenting the frame rings; org.freedesktop.Notifications; `.desktop` entries; packaging as
distro packages or an AppImage.

Begun: `host/avod` carries the daemon's engine-facing foundation, one
module per commit, the Mac's sources the truth for each (`host/AvoKit`,
`host/AvoDaemon`), no framework the crate cannot spell — the whole
battery runs on any Linux box without hardware or display:

- **Wire** — the `vsock.sock` transport client (the Firecracker hybrid
  convention, matching the engine's device byte for byte), the control
  channel's varint framing (8 MiB ceiling) and the full `avo.v1`
  envelope set, hand-transcribed from
  [proto/avo/v1/control.proto](../proto/avo/v1/control.proto) with
  prost's wire derives; pinned-byte tests hold the wire still against
  the Swift and Java peers.
- **Session** (`session.rs`) — the Hello gate and version negotiation
  (the Swift's `consoleActor` shape), request ids from 1 with slots
  planted before the write, reply pairing, Pong auto-reply, and —
  since `8a5a760` — the keepalive: the Swift's `startKeepalive`
  (Ping every 5s, window 5s, dead at three misses, no goodbye on that
  death) as a third thread the tests drive at fast clocks.
- **Frames** (`frames.rs`) — the engine's shared-memory ring reader,
  three whole buffers, discovery over the engine's control-socket text
  events.
- **Input** (`input.rs`) — the guest's fixed-layout input records on
  vsock 6001, re-encoded byte-for-byte against
  [proto/testdata/input-v1.bin](../proto/testdata/input-v1.bin).
- **Audio** (`audio.rs`) — the engine's sound rings in tap.rs's exact
  shape, playback read and capture filled.
- **adb relay** (`adb.rs`, from `ff007ff`) — the Mac's
  `LoopbackListener`/`SocketSplice` semantics: one loopback TCP port the
  user's own adb connects to, spliced to the guest's 5555 over vsock,
  refusals non-fatal to the accept loop. The ADB *client* stack
  (CNXN/AUTH RSA, `pm install-*`) the install pipeline needs later is
  deliberately not here — it wants a signing dependency.
- **Engine control** (`engine.rs`, from `7d170b4`) — the daemon's client
  for the engine's own runtime socket: one-line commands (`display`,
  `touch`, `key`, `sound`, `pause`…), `ok`/`error` replies, `subscribe`
  turning a connection into the event stream, and the event vocabulary
  (frames, sound, gpu, paused/microphone) parsed; the stream's end
  surfaces once as `Closed`, the way the Mac's ends at the byte.
- **Notifications** (`notifications.rs`, from `74504fd`) — the desktop's
  `org.freedesktop.Notifications` through a dlopen'd libdbus (no libc
  dep, no subprocess; the iterator functions only, since libdbus's
  append_args is variadic), mapping MacIntegrations.swift's
  `UserNotificationPresenter` line by line: ongoing never shown, the
  key through a key→id map onto `replaces_id` and `CloseNotification`,
  silent as the spec's `suppress-sound` hint, expire 0 for the
  triggerless Mac shape; the icon and the click back-channel are named
  gaps. Marshaling is proven by round-tripping through libdbus's own
  bytes — no bus in any test.

The battery has grown with each slice (87 tests when the roles door
finished its wiring). Landed since the numbers above: the **body**
(`body.rs`, the `avod` binary) binding the engine socket, the transport's
session, the adb relay and the notifications desk into one loop with the
Mac's exit codes; the **roles socket** (`roles.rs`, `daemon.sock`) — the
hello dance the Mac's XPC carried, `RoleInvite`→`RoleGrant`, with the
mount gate standing where the Mac used code signing (a 0700 directory of
the daemon's own user); and **packaging** (`dist/`, the systemd user unit
the LaunchAgent maps onto). The engine's own one-line grammar rides the
door now: a granted control panel asks `pause` (or touch, key, tap,
swipe, display, location, snapshot, gamepad — proto.rs's `Verb`, tag 64)
and the loop answers the engine's own wording in the asker's id. Still
to come for the daemon itself: the door's remaining verb classes — the
guest-bound ones (Launch, ListApps, the app set) routed over the
session's request lanes; the daemon's own ADB client stack (`pm
install-*` and friends — the signing dependency the adb slice
deliberately left out); and the window shims.

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
  elsewhere). Addressed in code: the host's rate is read once per run
  (`mrs cntfrq_el0`, cached on `Running`), the kvm backend converts offset
  deltas with it and wait_for_interrupt sleeps against it, and the Mac keeps
  24 MHz. The pause probe anchors itself in the counter's own domain on each
  (mach time under hvf, the host's own counter under KVM) — the test has not
  yet run on KVM hardware.
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
