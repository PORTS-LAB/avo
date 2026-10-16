# Contributing

Thanks for helping. Avo is early (see the status table in README.md); the
engine port (docs/engine.md) and the Android image are where help matters most.

- **Host (Swift).** `make test` must pass. Keep platform-independent logic in
  `host/AvoKit` with tests; AppKit and SwiftUI code goes in the Xcode targets.
  Swift 6 language mode with strict concurrency.
- **Protocol.** Change `proto/avo/v1/*.proto`, run `scripts/gen-proto.sh`, bump
  `PROTOCOL_VERSION_CURRENT` only for incompatible changes, and update
  docs/protocol.md. Input record layout changes need
  `AVO_UPDATE_GOLDEN=1 swift test` and the Java check in
  `guest/bridge-agent/build.sh`.
- **Device profiles.** Add `profiles/devices/<id>.json` with values from a
  stock `build.prop`; `DeviceProfileTests` validates every file.
- **Keymap profiles.** Add `profiles/keymaps/<package>.json`. Profiles with FPS
  mode may not contain repeated taps, macros, or swipes through the aim area;
  `KeymapProfileTests` checks them.
- **Logo.** Edit `branding/tools/generate.py`, not the generated files.

Commits: one topic per commit, imperative subject line.
