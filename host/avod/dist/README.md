# host/avod/dist/ — the LaunchAgent's systemd successor

Phase 3 (Linux port): what the Mac carries in
`host/Avo/LaunchAgents/dev.avo.daemon.plist` — Label `dev.avo.daemon`,
`BundleProgram` the AvoDaemon binary, `MachServices` `dev.avo.daemon`,
`RunAtLoad` true, `KeepAlive { SuccessfulExit: false }`,
`LimitLoadToSessionType` Aqua, `ProcessType` Interactive — rebuilt for Linux
as a systemd user unit plus a per-user install script.

## Layout

| file | what it is |
|---|---|
| `avod.service` | systemd user unit; the LaunchAgent translated key by key (mapping commented inline) |
| `install.sh` | builds `host/avod` and installs binary + unit into `$HOME`, no sudo/root/flags |
| `README.md` | this file |

## plist → unit mapping

| Mac (dev.avo.daemon.plist) | Linux (avod.service) |
|---|---|
| `Label dev.avo.daemon` | the unit's plain name `avod.service` — launchd's dotted Label becomes `systemctl --user`'s filename |
| `RunAtLoad true` | `[Install] WantedBy=default.target` — user-unit enable puts the agent under the user manager's session bootstrap target |
| `LimitLoadToSessionType Aqua` | `After=graphical-session.target` — starts when the desktop session is up; on a headless login the target is never reached, which is exactly what the Mac gets (no Aqua session → no agent) |
| `KeepAlive { SuccessfulExit: false }` | `Restart=on-failure` — restart only on nonzero exit, a clean exit stays down; `RestartSec=10` pins launchd's ~10 s retry pacing |
| `MachServices dev.avo.daemon` | the daemon's own Unix socket `daemon.sock` under the runtime dir — the unit does nothing for it (the daemon binds on startup; the roles slice serves it); documented here so the plist row has a home |
| `ProcessType Interactive` | comment only — launchd's scheduling hint has no systemd analog; default scheduling is fine |

The `BundleProgram` binary lands at `~/.local/bin/avod` and the unit's
`ExecStart=%h/.local/bin/avod` carries **no flags**: the daemon body's
defaults are the agreed ones below, so the unit says nothing it doesn't have
to. stderr reaches journald without any declaration — launchd got the same
for free.

## Agreed defaults (implemented by the daemon body; the unit carries no flags)

| | value |
|---|---|
| instance | `$XDG_DATA_HOME/avo/default` (the `--instance` default) |
| runtime | `$XDG_RUNTIME_DIR/avod` (the `--runtime` default) |
| control socket | `daemon.sock` under the runtime dir — the successor of the Mac's `MachServices dev.avo.daemon` XPC endpoint; the roles slice serves it |

## What install.sh does

1. locates the repo root relative to itself (`dist/` → `avod/` → `host/` → root)
2. `cargo build --release --manifest-path <root>/host/avod/Cargo.toml`
3. `mkdir -p ~/.local/bin ~/.config/systemd/user`
4. installs the built binary — with a caveat: at this base `host/avod/Cargo.toml` has no `[[bin]]` section and there is no `src/main.rs`, so the crate builds as a **library only** and `target/release/avod` does not exist yet. Cargo auto-derives a binary named `avod` as soon as the daemon-body slice adds `src/main.rs`. The script handles both: if `target/release/avod` exists it is copied to `~/.local/bin/`; if not, it prints a clear line saying the binary appears with the daemon-body slice and installs the unit anyway
5. copies `avod.service` into `~/.config/systemd/user/`
6. `systemctl --user daemon-reload`
7. prints the one remaining manual step

## What is NOT here yet

- **`.desktop`** — the GUI control panel binary does not exist on Linux yet, so there is nothing for an entry to point at
- **AppImage** — no bundle format yet, plain per-user files only
- **the roles socket's verb set** — `daemon.sock` is served by the roles slice; its verbs are that slice's work, not this package's

## Enable step

```
systemctl --user enable --now avod.service
```

That is the only step install.sh does not perform: enable-under-now is a
decision to let the user make (and to make once), everything
install-script-shaped is already done by then.
