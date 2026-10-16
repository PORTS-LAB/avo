# macOS host

```
Avo/            Control Panel (SwiftUI) — Avo.app
AvoDaemon/      Runtime Daemon + menu bar item — Avo.app/Contents/Library/Helpers/AvoDaemon.app
AvoWindowHost/  Window Host framework, loaded by every App Shim
AvoShim/        App Shim template (a tiny loader)
avoctl/         Command-line control of the daemon — Avo.app/Contents/MacOS/avoctl
AvoKit/         Swift package with all platform-independent logic and its tests
Config/         Shared build settings (Base.xcconfig; optional Local.xcconfig)
project.yml     XcodeGen spec for Avo.xcodeproj
```

All Xcode targets link one dynamic framework, `AvoHostKit` (every module of
the AvoKit package), embedded once in `Avo.app/Contents/Frameworks`.

## Build and test

```sh
xcodegen generate                        # after changing project.yml
xcodebuild -project Avo.xcodeproj -scheme Avo build
cd AvoKit && swift test                  # core tests, no Xcode project needed
```

To sign with your team, create `Config/Local.xcconfig` (ignored by git):

```
AVO_TEAM_ID = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development   // or Developer ID Application for releases
```

A daemon signed with a team switches to team-based caller validation
automatically.

## Running during development

A normal launch of Avo.app registers the daemon as a LaunchAgent with
`SMAppService`, which adds a Login Item for that build. To try a build without
registering it, run the daemon with `launchctl` and tell the Control Panel to
skip registration:

```sh
APP=/path/to/DerivedData/Build/Products/Debug/Avo.app
cat > /tmp/dev.avo.daemon.dev.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.avo.daemon.dev</string>
  <key>Program</key><string>$APP/Contents/Library/Helpers/AvoDaemon.app/Contents/MacOS/AvoDaemon</string>
  <key>MachServices</key><dict><key>dev.avo.daemon</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF
launchctl bootstrap gui/$(id -u) /tmp/dev.avo.daemon.dev.plist
open "$APP" --args -AvoSkipDaemonRegistration YES
"$APP/Contents/MacOS/avoctl" status

# afterwards
launchctl bootout gui/$(id -u)/dev.avo.daemon.dev
```

Development builds are signed to run locally, so the daemon accepts callers
signed inside the same Avo.app (the Control Panel, `avoctl`) and App Shims it
created itself; anything else is rejected.

Things to know:

- The daemon reads package files only through descriptors passed by the
  caller, so installing from Downloads or Documents needs no extra permission.
- Building with Xcode registers the built Avo.app with LaunchServices, which
  makes it the handler for `.apk` files. Remove a stale build's registration
  with `lsregister -u <path to Avo.app>`.
