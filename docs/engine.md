# Engine VM: crosvm with a Hypervisor.framework backend

The spec chose crosvm (BSD-3-Clause) with a new backend for Apple's
Hypervisor.framework (HVF), reusing crosvm's virtio devices and gfxstream
(rutabaga). Upstream crosvm runs on KVM, WHPX, Gunyah and others; macOS support
stops at a minimal `base/src/sys/macos` (kqueue events, timers, sockets). This
document is the contract the macOS host already implements, and the plan for
the port — the largest piece of Phase 1.

## Contract with the Runtime Daemon

The daemon (`CrosvmEngine` in AvoDaemonCore) spawns
`Avo.app/Contents/MacOS/crosvm` and expects the following. The argument list is
built by `CrosvmEngine.arguments(for:)` and covered by `EngineContractTests`.

```
crosvm run --name avo
  --cpus num-cores=<cpuCount>
  --mem size=<memoryMiB>
  --balloon-page-reporting | --no-balloon          # Performa: return memory when idle
  --block path=<image>/system.img,ro=true,id=system
  --block path=<image>/vendor.img,ro=true,id=vendor
  --block path=<image>/overlay_{stock,rooted}.img,ro=true,id=avo_overlay   # root checkbox
  --block path=<data disk>,id=userdata
  --block path=<runtime>/avo_config.img,ro=true,id=avo_config              # BootConfig
  --gpu backend=gfxstream,gles=true,vulkan=<bool>,context-types=gfxstream-gles:gfxstream-vulkan:gfxstream-composer
  --vsock cid=3,uds-path=<runtime>/vsock.sock       # new: hybrid vsock (below)
  --virtio-snd backend=coreaudio,...                # new backend
  --socket <runtime>/crosvm.sock                    # control socket
  --serial type=file,path=<logs>/android-console.log,hardware=virtio-console,console=true
  --initrd <image>/initrd.img
  [--restore <snapshot>]                            # quick boot
  --params "androidboot.hardware=avo androidboot.avo.config=/dev/block/by-name/avo_config"
  <image>/kernel
```

**Readiness.** The engine is up when `vsock.sock` accepts connections; the
daemon then retries the Control port until the Bridge Agent answers.

**Hybrid vsock.** macOS has no `AF_VSOCK`, so the engine implements virtio-vsock
in user space and exposes guest ports through one Unix socket, with
Firecracker's convention: the host connects, writes `CONNECT <port>\n`, reads
`OK <host-port>\n`, and the stream is raw from there (`VsockBridge` in AvoIO).
The runtime directory is mode 0700; only the daemon connects (spec: no TCP
ports, ADB never on the network).

**Control socket.** `crosvm powerbtn` (clean Android shutdown),
`crosvm stop`, `crosvm snapshot take --compress <path>`; `--restore` for quick
boot. Balloon statistics drive "return memory when idle".

**Frames.** The guest's Bridge Agent creates one gfxstream display per host
display id (`rcCreateDisplayById`), sizes it (`rcSetDisplayPose`) and posts
each VirtualDisplay buffer with `rcSetDisplayColorBuffer`. On the host, the
engine keeps a swapchain of three BGRA `IOSurface`s per display, copies (GPU
blit) the posted color buffer into the next one, and tells the daemon over XPC
(role `engine` on the `dev.avo.daemon` Mach service):

- `engineSetSurfaces(displayID, [IOSurface])` when a display is created or resized;
- `enginePresent(displayID, surfaceIndex, sequence)` for every frame.

The daemon forwards both to the App Shim that owns the display, which draws the
IOSurface with Metal. Frames are never encoded.

**Entitlements.** `com.apple.security.hypervisor`, hardened runtime,
Developer ID signature, notarized with the app.

## Porting crosvm to macOS

| Area | Work |
| --- | --- |
| `hypervisor/src/hvf` | New backend implementing `Hypervisor`, `Vm`, `VmAArch64`, `Vcpu`, `VcpuAArch64` on Hypervisor.framework through a thin `-sys` crate. |
| Memory | `hv_vm_map` with 16 KiB granules (the host page size); guest memory from `mach_vm_allocate`; dirty tracking for snapshots via write protection. |
| vCPUs | HVF binds a vCPU to the thread that created it: one thread per vCPU running `hv_vcpu_run`. Exits: data aborts decoded from ESR (ISV, SAS, SRT, WnR) into MMIO; `HVC`/`SMC` for PSCI (CPU_ON, SYSTEM_OFF, SYSTEM_RESET); `WFI` parks the thread until an interrupt is pending; `VTIMER_ACTIVATED` raises the timer PPI. |
| Interrupts | macOS 15's in-kernel GICv3 (`hv_gic_create`, `hv_gic_set_spi`) — the reason Avo requires macOS 15. Device tree generation in `aarch64/` describes it. |
| `base`, `cros_async` | Extend the existing kqueue-based `sys/macos` to what devices need (event, wait contexts, shared memory). |
| Devices | virtio-mmio transport; blk, console, input, balloon reused; vsock reimplemented in user space with the hybrid Unix socket (crosvm's Windows backend already does this over named pipes); virtio-snd CoreAudio backend. |
| Graphics | gfxstream host on macOS: Vulkan through MoltenVK, GLES through gfxstream's GLES-on-Vulkan path; color buffers backed by IOSurface (`VK_EXT_metal_objects`) for zero-copy blits; per-display callback driving the XPC calls above. |
| Main loop | `src/crosvm/sys/macos`: VM setup, vCPU threads, device worker threads, control socket. |

### Milestones

Code for the first two lives in [`engine/hvf`](../engine/hvf/README.md).

1. **HVF crate** — *done*: create a VM, map memory, run a tiny AArch64 guest
   that writes to MMIO and calls PSCI `SYSTEM_OFF`; `cargo test` runs it, signed
   with the hypervisor entitlement by a cargo runner.
2. **Linux to init** — *done for the kernel*: the Android 16 GKI kernel boots
   on one vCPU with a generated device tree, HVF's in-kernel GICv3, the virtual
   arch timer, PSCI over HVC and a minimal PL011 (earlycon), unpacks the
   Android ramdisk and starts first-stage `init`, which loads its virtio
   modules and then stops for lack of virtio devices. Remaining: SMP
   (PSCI `CPU_ON`, one thread per vCPU), WFI sleeping until the timer deadline
   instead of polling, and the console on virtio.
3. **Android first stage**: virtio-blk partitions, `androidboot` parameters,
   Cuttlefish-style fstab.
4. **Headless Android**: vsock bridge; the daemon connects, Bridge Agent
   answers Hello, ADB installs work — the Phase 1 gate ("APK di-install dari
   Finder dan aplikasinya bisa dipakai") minus display.
5. **Displays**: gfxstream on Metal, IOSurface swapchains, frames in App Shim windows.

### Risks (from the spec)

- gfxstream on Metal too slow for heavy games: measure from milestone 5 with
  Genshin Impact, PUBG Mobile and Delta Force; keep Venus (virtio-gpu Vulkan)
  through MoltenVK as the fallback path.
- macOS updates changing HVF behaviour: run the HVF crate tests on macOS betas
  in CI (self-hosted Apple Silicon runners).
