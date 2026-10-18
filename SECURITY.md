# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's
[security advisories](https://github.com/nizwar/avo/security/advisories/new)
rather than in a public issue. Include the Avo version and build
(Settings › About), your macOS version, and steps to reproduce.

You can expect an acknowledgement within a week. Fixes are released as soon
as practical, and reporters are credited unless they prefer otherwise.

## Scope

Avo is a set of macOS apps (the Control Panel, the Runtime Daemon, per-app
windows and `avoctl`) and a virtual machine engine, `avo-vmm`. Areas of
particular interest:

- Isolation between Android and the Mac: guest-to-host escapes through
  avo-vmm's virtio devices, the GPU path, or the shared folder.
- The daemon's XPC interface and its caller validation
  ([docs/architecture.md](docs/architecture.md), "XPC and caller
  validation").
- ADB access: adbd is reachable only by the daemon over vsock and, with ADB
  support turned on, on 127.0.0.1.
- Data handling in diagnostics archives (Help › Report a Problem).

Preview builds are signed ad hoc and are not notarized; this is a known
limitation of the preview, not a vulnerability.
