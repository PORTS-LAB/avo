# Keymap profiles

Community keymapping profiles (spec §5 and §5a), one file per Android package:
`<package>.json`. The Control Panel imports and exports the same format.

Controls: `tap`, `hold`, `dpad`, `aim` (mouse-look), `ads`, `swipe`,
`repeat_tap` and `macro`. Positions are normalized to the window (0–1), so a
profile works at any window size. Triggers are written as `key:W`,
`mouse:left`, `scroll:up` or `pad:a`.

FPS mode (`"fps"`) adds pointer lock, re-centering, separate ADS sensitivity
and a cursor toggle (default `key:Option`). To keep profiles fair, validation
rejects in FPS mode:

- `repeat_tap` and `macro` controls (no automatic rapid fire, no recoil macros);
- swipes that start or end in the aim area (no recoil compensation).

Avo does not hide itself from anti-cheat systems. Record whether a game works in
the community compatibility list before relying on a profile.

Clash of Clans needs no profile: clicks and drags already arrive as touches.
