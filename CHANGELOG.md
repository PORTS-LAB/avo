# Changelog

All notable changes to Avo are listed here. Versions follow
[Semantic Versioning](https://semver.org); preview builds carry a build
number (`CFBundleVersion`) that only goes up.

## 0.1.0 Preview 1 (build 35)

The first public preview, for testers. It is signed ad hoc and not
notarized, so macOS asks you to confirm the first launch (System Settings ›
Privacy & Security › Open Anyway).

### Highlights

- **Android apps as Mac apps.** Every Android app opens in its own window
  with its own Dock icon, Launchpad and Spotlight entries and ⌘Tab. Full
  screen hides the menu bar and title bar until the pointer reaches the top of
  the screen.
- **Android 17 in its own VM.** Avo boots an unmodified AOSP Cuttlefish image
  on Hypervisor.framework with avo-vmm, Avo's own engine. The Setup Assistant
  downloads the image; Settings › System switches Android versions and keeps
  the previous one to go back to.
- **Older Android versions** (15, 14 and 13) are listed under Older Versions;
  they may not start on Apple silicon.
- **Each Android version keeps its own data.** Changing versions never erases
  anything: you choose the data the new version uses (the data it had
  before, Android data in another folder, or new data in an empty folder),
  and an upgrade can also take the current data along.
- **GPU rendering.** Android draws on the Mac's GPU through gfxstream and
  MoltenVK (from the Android Emulator), with native ASTC textures, a
  persistent shader cache, frame-rate caps of 30, 60, 90 and 120 fps or the
  display's own rate, render scale, sharpening, and per-app graphics settings.
  Without the Android Emulator, Android renders in software.
- **Games.** Key mapping on a game's touch controls with templates for
  shooters, MOBAs and racing games, shooter mode with mouse-look, game
  controllers with a visual editor, and shareable profiles.
- **Mac integration.** Notifications in Notification Center, a shared
  clipboard, links in the Mac's browser, drag and drop, screen translation
  (⌘⇧T), screenshots and recordings with sound, Keep on Top and Picture in
  Picture, and Android following the Mac's appearance, time zone, clock,
  language and battery.
- **Devices for apps.** Location from the Mac or a place or route you pick, the
  Mac's microphone, mock fingerprints, a shared folder between the Mac and
  Android, device profiles, and Android's data on an external drive if you
  like.
- **Control Panel.** App library, Settings in one window, System Status (CPU,
  memory and GPU per app), install from `.apk`, `.xapk`, `.apkm` and `.apks`
  files, optional Google Play (MindTheGapps), ADB support for `adb` and
  Android Studio, and Help › Report a Problem.
- **Menu bar and power.** A compact menu bar panel; Android pauses itself when
  idle (Settings › Performance) and resumes the moment anything uses it.

### Fixes since the internal builds

- Sound: playback runs on the device's own clock in 20 ms periods, so games no
  longer sound robotic or delayed, and it no longer stays silent after the
  Mac's audio queue runs dry (opening a second app, switching apps, or the
  first sound of a game).
- Sound: apps in different windows keep playing at the same time (Android's
  multi audio focus), and an app's window becoming key on the Mac moves
  Android's focus to it, so games that mute when unfocused play again.
- Sound: games that ask for 8-channel output (Call of Duty: Mobile, Delta
  Force's voice chat) get stereo instead of failing.
- Android's own factory reset and reboot work and bring Android back up;
  factory reset protection never locks Android after a reset.
- The first boot of a new Android image no longer reports a false GPU failure.
- A display re-plug no longer crashes SurfaceFlinger.
- Android's Thread radio service no longer restarts every few seconds (the
  VM has no Thread radio).
- Closing an app's last window ends the app (like a force stop), and its
  window no longer opens again by itself (Google Play, Settings).
- The Google apps install shows one realistic progress bar across its steps.
- Menus and pop-up buttons in Settings, and the menu bar panel's position.

### Notes for testers of internal builds

- Avo.app's bundle identifier is now `com.avodroid.emulator` (it was `dev.avo.Avo`).
  Its preferences move over at the first launch; macOS may ask again for
  permissions the Control Panel had.

### Known issues

- Preview builds do not update themselves; install a newer DMG over this one.
- Some games rate the VM as a low-end device. Delta Force, for example, draws
  flat terrain at its MAX preset; a lower preset looks right.
- Camera and Bluetooth are not supported.
- Apps that need hardware attestation (most banking apps, some DRM and
  anti-cheat systems) generally do not run.

### Requirements

- A Mac with Apple silicon, macOS 15 or newer.
- For GPU rendering: Google's Android Emulator (from Android Studio or the SDK
  command-line tools).
