# Keymap profiles

Community keymapping profiles (spec §5 and §5a), one file per Android package:
`<package>.json`. The Control Panel imports and exports the same format.

Controls: `tap` (held as long as its key; `hold` is the same), `anchor`
(held at its point while the mouse moves the finger, for emote wheels),
`dpad`, `aim` (the eye: mouse-look while the mouse is locked), `ads`,
`swipe`, `repeat_tap`, `macro`, and for MOBAs `moba_move` and `smart_cast`.
Positions are normalized to the window (0–1) and sizes (`size`, a radius)
to its height, so a profile works at any window size. Triggers are written
as `key:W`, `mouse:left`, `scroll:up` or `pad:a`. A left-click binding acts
only while the mouse is locked, so the game's own buttons stay clickable
(MOBA controls, which are made for the cursor, take it with the mouse free).
A click that no control takes is a touch at the cursor, in the same
multitouch gesture as the touches that keys hold: clicking a game button
while walking with the right button does not stop the hero.

Areas are `[x0, y0, x1, y1]`. The eye's finger touches down at `origin`
(the centre of its `area` when left out), swipes inside `area` as the mouse
moves and, at its edge, lifts and touches down at `origin` again: a taller
area lets a look up or down go further in one swipe. An anchor tap may have
an `area` too, which its finger never leaves (the whole screen when left
out). Both fields are optional, so older profiles load unchanged. In the
editor, drag an area to move it and its edges or corners (shown while it is
selected) to resize it; ⌥ + arrow keys move the selected object and ⌥⇧ +
arrow keys resize it.

MOBA controls aim from the hero, `"hero": [x, y]` at the top level of the
profile (where the camera keeps your character; the centre when left out),
towards the mouse cursor:

- `moba_move` (move by mouse): while its trigger is held (typically
  `mouse:right`), the joystick at `center` is pushed the way the cursor lies
  from the hero, all the way out to `radius` once the cursor is that far
  from the hero.
- `smart_cast`: its trigger puts a finger on the skill at `position` and
  drags it towards the cursor while held; letting go casts. The drag grows
  with the cursor's distance from the hero and reaches `radius` (default
  0.1) when the cursor is `reach` (default 0.35, the skill's range on screen)
  away. A cursor on the hero is a quick cast.

Both follow the visible cursor, so in FPS mode they rest while the mouse is
locked. Controls of a kind this version of Avo does not know are skipped
(the rest of the profile still loads) and dropped when the editor saves.

Game controllers: a button is a `pad:` trigger (`pad:a` is the bottom face
button on every controller, `pad:leftTrigger`, `pad:dpadUp`,
`pad:leftThumbstick` for pressing the stick down…), and a `dpad` or `aim`
control follows a stick with `"stick": "left"` or `"right"`. A `dpad` with
`"dpad_buttons": true` is also pushed by the controller's d-pad. An optional
top-level `"gamepad"` block sets how the sticks act and keeps the game's
controller presets:

```json
"gamepad": {
  "left_stick": {"deadzone": 0.15, "sensitivity": 1},
  "right_stick": {"deadzone": 0.1, "sensitivity": 1.5},
  "vibration": true,
  "presets": [
    {"name": "Shooter", "bindings": {"jump": {"buttons": ["a"]}, "move": {"stick": "left", "dpad": true}},
     "left_stick": {"deadzone": 0.15, "sensitivity": 1}, "right_stick": {"deadzone": 0.1, "sensitivity": 1.5}}
  ]
}
```

- **`deadzone`:** 0–0.6 of the stick's travel that does nothing.
- **`sensitivity`:** 0.25–4. Above 1, a joystick reaches its edge, and the
  eye turns faster, with less of a lean.
- **`vibration`:** a light pulse on controllers that can vibrate, when a
  button touches the screen.
- **`presets`:** each holds what the controller drives, by control id.

In the editor, the Controller button shows the connected controller. Drag a
button or stick onto the game to place a control there, or onto a control
to bind it. Older versions of Avo ignore these fields.

The editor's Templates menu inserts a starting layout for an FPS, MOBA,
racing game or platformer; its positions are guesses at a typical HUD, to
drag onto the game's own buttons. A template never changes the hero point.

FPS mode (`"fps"`) adds pointer lock, re-centering, separate ADS sensitivity
and the key that locks and frees the mouse (`cursor_toggle`, default
`key:F8`). Key mapping only acts in Game Mode (⌘G in the app's window). To keep profiles fair, validation
rejects in FPS mode:

- `repeat_tap` and `macro` controls (no automatic rapid fire, no recoil macros);
- swipes that start or end in the aim area (no recoil compensation).

Avo does not hide itself from apps that check for it. Record whether a game works
in the community compatibility list before relying on a profile.

Clash of Clans needs no profile: clicks and drags already arrive as touches.
