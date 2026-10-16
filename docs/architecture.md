# Architecture notes

How the [specification](spec.md) is implemented, and the decisions the spec
left open. Protocol details are in [protocol.md](protocol.md), the VM engine in
[engine.md](engine.md).

## Processes on the Mac

| Process | Bundle | Role |
| --- | --- | --- |
| `Avo` | `Avo.app` (`dev.avo.Avo`) | Control Panel. Registers the daemon with `SMAppService`, handles `.apk/.xapk/.apkm/.apks` opens and drops. |
| `AvoDaemon` | `Avo.app/Contents/Library/Helpers/AvoDaemon.app` (`dev.avo.daemon`) | Runtime Daemon (LaunchAgent, Mach service `dev.avo.daemon`). Also hosts the menu bar item and posts notifications. |
| `crosvm` | `Avo.app/Contents/MacOS/crosvm` | Engine VM, a child of the daemon (see engine.md). |
| `<App>` | `~/Applications/Android Apps/<Label>.app` | App Shim, one per Android app; loads `AvoWindowHost.framework` from Avo.app. |
| `avoctl` | `Avo.app/Contents/MacOS/avoctl` | Command line for scripts and CI. |

The daemon is an accessory app rather than a bare executable for two reasons:
notifications must be posted by a bundle with an identity (the user sees
"Avo"), and clicks on them are delivered to the posting process, which must be
running — the daemon always is. The spec lists the Menu Bar Item as its own
component; it lives in the same process because its state is the daemon's
state and it should stay visible while Android runs in the background.

All Swift code shared between targets is one dynamic framework,
`AvoHostKit.framework` (every module of the `AvoKit` package). Linking the
package products separately produced two copies of the same classes in one
process, which breaks NSXPC class checks.

## XPC and caller validation

The daemon vends one Mach service. Each connection declares a role in
`hello` (`controlPanel`, `shim(package)`, `engine`) and every later call is
checked against it: shims may only open, drive and close displays for their
own package; only the Control Panel (and `avoctl`) may change settings or
install. Identity checks (spec: "validasi code signature pemanggil"):

- **Release builds** (signed with a Developer ID team): the listener's code
  signing requirement admits Avo's team plus the code directory hash of every
  shim the daemon created. A shim's connection is then pinned to its own hash.
- **Development builds** (ad hoc): the caller must be signed and live inside
  the Avo.app bundle the daemon runs from; shims are still pinned by hash.

App Shims are re-signed ad hoc after their Info.plist and icon are written
(editing a signed bundle breaks its signature). Their hashes are kept in the
app registry. A shim that is not in the registry is rejected — verified with a
hand-made shim against the running daemon.

## Files chosen by the user

The daemon is a separate process, so it does not inherit the access macOS
gives the Control Panel (or a shim) to a file the user double-clicked, dropped
or picked from Downloads/Documents; reading the path itself triggers a privacy
prompt for the daemon. Clients therefore open the file and pass the
descriptor over XPC (`install(_:file:)`, `shareFiles(_:files:names:)`); the
daemon reads the package through that descriptor.

## Installing a package (spec §3)

1. The Control Panel inspects the file locally (`PackageArchive`) and shows
   name, version, size, notable permissions and blocking problems: native code
   without `arm64-v8a` (Apple Silicon cannot run 32-bit ARM or x86) or a
   `minSdkVersion` above the image's.
2. On confirmation it sends the open file to the daemon, which re-inspects it,
   starts Android if needed, and streams the selected APKs through
   `pm install-create / install-write / install-commit` over ADB. ABI splits for
   other ABIs are skipped. Streams use `ChunkPipe`, a bounded queue between the
   ZIP inflater and the ADB writer, so a multi-gigabyte XAPK never sits in
   memory.
3. XAPK OBB files go to `/sdcard/Android/obb/<package>/` with ADB sync.
4. Android's `PACKAGE_ADDED` reaches the daemon as `AppInstalled`; that event
   (not the installer) creates the shim, so apps installed from inside Android
   get shims too.

Formats are detected from content, not the extension: `AndroidManifest.xml` at
the root (APK), `manifest.json` (XAPK), `info.json` (APKM), or APKs (APKS; for
bundletool sets only `splits/` is used). Labels and icons are resolved from
`resources.arsc`, including sparse and compact (Android 14+) tables; icons in
split bundles are looked up across density splits.

## App Shims and icons (spec §4)

- `ShimBuilder` copies the template bundle, writes `CFBundleIdentifier`
  (`dev.avo.shim.<package>`, `_` → `-`), the label, version and
  `AvoAndroidPackage`, swaps the bundle into place atomically
  (`renamex_np(RENAME_SWAP)`), signs it ad hoc and registers it with
  LaunchServices. Same label for two apps: the second becomes
  `Label (package).app`. A label change renames the bundle.
- Icons: the Bridge Agent renders adaptive icon layers at 432 px (108 dp);
  `MacIconRenderer` maps the 72 dp safe zone onto Apple's 824 pt
  continuous-corner squircle on a 1024 canvas with the standard shadow, and
  writes every `.icns` size with ImageIO. Opaque square legacy icons are
  masked to the squircle; others sit on a white plate.
- Desktop alias (on by default) and Dock tile (off by default) follow the
  Control Panel options and are removed on uninstall. Aliases never replace a
  real file.

## Windows (spec §2, "Native")

Each shim window asks the daemon for a display sized to the window's content
in pixels; density is 160 dpi per point (320 on Retina), so 1 dp equals 1 pt
and Android apps look the same size as Mac UI. Resizes are debounced to the
end of a live resize. Minimising or fully covering a window tells the guest to
detach the display's surface (the app keeps running, but stops rendering).
Window frames are remembered per app. When the Android task finishes, the
window closes; when the last window closes, the shim quits.

Frames: the engine renders each display into a small swapchain of IOSurfaces,
hands them to the daemon once (`engineSetSurfaces`) and then only announces
which surface to show (`enginePresent`). The daemon forwards both to the shim
that owns the display; the shim wraps the IOSurfaces as Metal textures and
draws them aspect-fit into a `CAMetalLayer`. No frame is copied or encoded on
the CPU.

Input from a window, in order of precedence:

1. The keymap engine, when the app has a profile and the input is bound.
2. Defaults: a click is a touch; trackpad scrolling becomes a one-finger drag
   (momentum events are dropped so Android flings natively); a mouse wheel
   sends `AXIS_SCROLL`; pinch becomes two fingers around the cursor; Esc and a
   two-finger swipe left are Back; Cmd+C/V/X/A/Z map to Android's Ctrl
   shortcuts; editing keys (Return, Delete, arrows, …) are key events and
   everything printable goes through the macOS input method and arrives as
   committed text, so every keyboard layout and IME types correctly.

The guest focuses each display separately (`config_perDisplayFocusEnabled`),
so typing goes to the app in the window you are typing in.

## Keymapping (spec §5, §5a)

`KeymapEngine` is a pure state machine: input and timestamps in, complete
multitouch events out (every event carries all active pointers, as
`MotionEvent` requires). Controls: tap, hold, D-pad (keys or left stick),
mouse aim, ADS, swipe, repeated tap and macros. FPS mode: the first click
captures the pointer (`CGAssociateMouseAndMouseCursorPosition`) and raw,
unaccelerated deltas come from `GCMouse`; the camera touch re-centres at the
edge of its area and carries the rest of the movement over, so the camera
turns without limit; ADS switches to its own sensitivity; Option toggles a
cursor layer for inventories and maps; up to 16 simultaneous touches. Profile
validation enforces the spec's hard limits: in FPS mode, repeated taps and
macros are rejected and swipes may not touch the aim area (no automatic rapid
fire or recoil compensation).

Profiles are JSON with positions normalized to the window, stored per package
in `~/Library/Application Support/Avo/keymaps/`, with community starters in
`profiles/keymaps/`.

## Settings (spec §6)

`VMConfig` holds every Control Panel setting with validation (RAM 2–16 GB
within what the Mac can spare, cores, grow-only data disk, FPS 30/60/90/120,
DPI, window size) and the spec's restart table: Performance, renderer,
storage resize, root, device profile and GMS need a restart; the FPS cap
applies immediately (new displays get it as their requested refresh rate, open
ones are throttled in the guest's frame sink); display options apply to new
windows. The Control Panel applies changes as you make them and shows a
"Restart Android" banner when needed.

## Boot configuration and images

Before each boot the daemon writes a small read-only disk, `avo_config`
(`BootConfig`, JSON padded to 4 KiB): the daemon's ADB public key (adbd stays
authenticated even though only the daemon can reach it), the device profile's
properties, root and GMS choices, locale, time zone and default density.
`avo_init` applies it early in boot (guest/device/avo).

Android images are downloaded at first setup, versioned separately, and live
in `~/Library/Application Support/Avo/images/<version>/` with a
`manifest.json` (SHA-256 and size per file) and an Ed25519 signature checked
against the key in the daemon's Info.plist (`AvoImagePublicKey`) before every
boot. `scripts/make-image-manifest.py` produces both.

## Data on the Mac

```
~/Library/Application Support/Avo/   config.json, apps.json, icons/, keymaps/, adbkey, images/, vm/
~/Applications/Android Apps/          App Shims
~/Library/Logs/Avo/                   crosvm.log, android-console.log
$TMPDIR/dev.avo/                      vsock.sock, crosvm.sock (mode 0700)
```

## Testing

`swift test` in `host/AvoKit` runs 126 tests, including daemon integration
tests against a fake engine, a fake Bridge Agent speaking the real Control
protocol, a fake input sink and a fake adbd that verifies real RSA signatures:
boot → app sync → shims → displays → input routing → XAPK install with OBB →
uninstall → notifications → configuration rules → crash handling → version
mismatch. The Bridge Agent build runs a JVM test that decodes Input records
written by the Swift encoder (`proto/testdata/input-v1.bin`).
