import AppKit
import AvoKit
import SwiftUI

// Control Panel tabs from spec §6. Changes apply immediately; the daemon
// decides whether they need a VM restart and the restart banner appears.
// The forms take their look from where they show: the Settings window's
// HazeFormStyle makes each Section a card in the haze.

private struct SettingsForm<Content: View>: View {
    @Environment(ControlPanelModel.self) private var model
    @ViewBuilder var content: (VMConfig) -> Content

    var body: some View {
        if let config = model.config {
            Form { content(config) }
        } else {
            // The cards' shapes until the settings arrive.
            HazeSkeleton(bars: [(0.3, 16), (1, 40), (1, 40), (0.36, 16), (1, 40)], spacing: 14)
                .padding(.horizontal, 34)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct IssueText: View {
    @Environment(ControlPanelModel.self) private var model
    let field: String

    var body: some View {
        if let issue = model.issue(for: field) {
            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.mona(12))
                .foregroundStyle(issue.severity == .error ? Haze.danger : Haze.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RestartNote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.mona(12))
            .foregroundStyle(Haze.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the Mac's screens make of the frame rate cap, under its control:
/// only when none shows it evenly (FrameRates.screenNote).
struct FrameRateNote: View {
    let cap: Int

    var body: some View {
        if let note = FrameRates.screenNote(cap: cap, screens: ScreenRefresh.attached) {
            Text(verbatim: note)
                .font(.mona(12))
                .foregroundStyle(Haze.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Performa

struct PerformancePane: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        SettingsForm { config in
            let host = model.host
            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        HazeSlider(value: Binding(get: { Double(config.memoryMiB) },
                                                  set: { value in model.update { $0.memoryMiB = Int(value / 512) * 512 } }),
                                   range: Double(VMConfig.memoryRangeMiB.lowerBound)...Double(max(host.maxGuestMemoryMiB, VMConfig.memoryRangeMiB.lowerBound + 512)),
                                   step: 512)
                            .frame(width: 220)
                            .accessibilityLabel(Text("Memory"))
                        Text("\(Double(config.memoryMiB) / 1024, format: .number.precision(.fractionLength(0...1))) GB")
                            .monospacedDigit()
                            .foregroundStyle(Haze.text)
                            .frame(width: 64, alignment: .trailing)
                    }
                } label: {
                    HelpTitle("Memory", help: "Applies after Android restarts. This Mac has \(host.performanceCores) performance cores and \(host.physicalMemoryBytes / 1_073_741_824) GB of memory.")
                }
                IssueText(field: "memoryMiB")
                LabeledContent {
                    HazeStepper(value: Binding(get: { config.cpuCount }, set: { value in model.update { $0.cpuCount = value } }),
                                range: 1...host.totalCores) {
                        Text("\(config.cpuCount) of \(host.totalCores)").foregroundStyle(Haze.text)
                    }
                    .accessibilityLabel(Text("CPU cores"))
                } label: {
                    HelpTitle("CPU cores", help: "Applies after Android restarts. Up to this Mac’s performance cores keeps macOS responsive.")
                }
                IssueText(field: "cpuCount")
            }
            PauseWhenIdleSection(config: config)
            // Each further Section (or view of Sections) is a card of its own.
        }
    }
}

// MARK: Storage

struct StoragePane: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var resizing = false
    @State private var confirmClearCache = false

    var body: some View {
        SettingsForm { config in
            Section {
                if model.storageLocation?.problem != nil {
                    LabeledContent("Android storage") {
                        Text("Not available").foregroundStyle(.secondary)
                    }
                } else if let disk = model.dataDisk, disk.created {
                    LabeledContent {
                        if let android = disk.android {
                            Text("\(android.settingsTotalGB) GB").monospacedDigit()
                        } else {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: disk.diskBytes, countStyle: .decimal))
                        }
                    } label: {
                        HelpTitle("Android storage") {
                            Text("The size Android’s Settings shows. Like a phone, Android rounds its storage up to a standard size.")
                            Text("Android set it when it created its storage, and it stays: Android’s storage can change size only when it is empty, so Change Size erases Android’s data.")
                        }
                    }
                    if let android = disk.android {
                        LabeledContent("Available") {
                            Text("\(Self.bytes(android.freeBytes)) of \(Self.bytes(android.dataBytes))").monospacedDigit()
                        }
                        if android.settingsTotalGB != config.dataDiskGiB {
                            RestartNote(text: "Android created this storage before the size was \(config.dataDiskGiB) GB. Change Size erases Android’s data and creates its storage again at the size you choose.")
                        }
                    } else {
                        RestartNote(text: "Start Android to see how much of it is free.")
                    }
                    LabeledContent("Size") {
                        Button("Change Size…") { resizing = true }
                            .disabled(model.isInstallingGoogleApps)
                    }
                } else {
                    LabeledContent {
                        HazePicker("Android storage", selection: Binding(get: { config.dataDiskGiB }, set: { value in model.update { $0.dataDiskGiB = value } })) {
                            ForEach(Self.choices(including: config.dataDiskGiB), id: \.self) { Text("\($0) GB").tag($0) }
                        }
                    } label: {
                        HelpTitle("Android storage", help: "Android creates its storage at this size when it first starts, and its Settings show this size. After that the size stays: changing it erases Android’s data. The disk only takes up the space Android fills.")
                    }
                }
                IssueText(field: "dataDiskGiB")
                // Where the data is, and choosing another place (StorageLocationViews.swift).
                StorageLocationRows()
            }
            // A Mac folder Android sees as /sdcard/Avo Shared (SharedFolderViews.swift).
            SharedFolderSection()
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if let cache = model.gpuCache {
                            Text(verbatim: Self.bytes(cache.bytes)).monospacedDigit()
                        }
                        Button("Clear GPU Cache…") { confirmClearCache = true }
                            .disabled(model.gpuCache.map { $0.bytes == 0 } ?? true)
                    }
                } label: {
                    HelpTitle("GPU shader cache", help: "Shaders that games compiled for this Mac’s GPU, kept so they start smoothly. After you clear it, the first launch of each game compiles its shaders again, so it stutters once.")
                }
            }
            .task { await model.refreshGPUCache() }
        }
        .sheet(isPresented: $resizing) { ResizeStorageSheet() }
        .confirmationDialog("Clear the GPU shader cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("Clear GPU Cache", role: .destructive) { model.clearGPUCache() }
        } message: {
            Text("The first launch of each game afterwards compiles its shaders again, so it stutters once.")
        }
    }

    /// The standard sizes, and a size an older Avo or avoctl set.
    static func choices(including current: Int) -> [Int] {
        (VMConfig.dataDiskChoices + [current]).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal) }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Settings › Storage › Change Size: Android's storage can change size only
/// empty, so this erases Android's data, then sets the new size.
private struct ResizeStorageSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var size = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Android’s Storage Size")
                .font(.hubot(21, 750))
                .tracking(-0.3)
            LabeledContent {
                HazePicker("Size", selection: $size) {
                    ForEach(VMConfig.dataDiskChoices, id: \.self) { Text("\($0) GB").tag($0) }
                }
            } label: {
                Text("Size")
            }
            .labeledContentStyle(HazeLabeledContentStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Haze.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            message
                .font(.mona(13))
                .foregroundStyle(Haze.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .keyboardShortcut(.cancelAction)
                Button("Erase and Use \(size) GB", role: .destructive) {
                    model.eraseAndResizeStorage(to: size)
                    dismiss()
                }
                .buttonStyle(HazeButtonStyle(kind: .destructive, height: 34, fontSize: 13, horizontalPadding: 18))
            }
        }
        .padding(24)
        .frame(width: 460)
        .background { HazeSheetBackground() }
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        .environment(\.colorScheme, .dark)
        .onAppear {
            let current = model.config?.dataDiskGiB ?? 64
            size = VMConfig.dataDiskChoices.contains(current) ? current : 64
        }
    }

    private var message: Text {
        var text = Text("Android’s storage can change size only when it is empty. All Android apps, accounts and files are erased; Avo’s settings and the Android image are kept. Android creates its storage at the new size when it next starts.")
        if model.googleAppsInstalled {
            text = text + Text(verbatim: " ") + Text("Google apps are removed too: install them again under Google apps and register the new Android ID.")
        }
        return text
    }
}

// MARK: Grafis

/// Settings › Graphics: how Android renders, the Apps and Games profiles
/// (resolution and scaling), app windows' default size and the performance HUD.
struct GraphicsPane: View {
    @Environment(ControlPanelModel.self) private var model
    /// Which profile the editor shows; not a setting.
    @State private var profile: GraphicsProfile = .apps
    @State private var confirmResetAll = false

    var body: some View {
        SettingsForm { config in
            Section("Rendering") {
                LabeledContent {
                    HazePicker("Renderer", selection: Binding(get: { config.rendererMode }, set: { value in model.update { $0.rendererMode = value } })) {
                        Text("Automatic").tag(VMConfig.RendererMode.auto)
                        Text("GPU (Metal)").tag(VMConfig.RendererMode.gpu)
                        Text("Software").tag(VMConfig.RendererMode.software)
                    }
                } label: {
                    HelpTitle("Renderer") {
                        Text("Automatic uses this Mac’s GPU when the Android Emulator is installed, and software rendering otherwise.")
                        Text("Applies after Android restarts.")
                    }
                }
                RendererStatusRow()
                LabeledContent {
                    // 90 and 120 always, and a screen's own rate (75 Hz; FrameRates).
                    let rates = FrameRates.choices(for: ScreenRefresh.attached, keeping: config.fpsLimit)
                    HazeSegmented.inset(rates.map { ($0, Text(verbatim: "\($0)")) },
                                        selection: Binding(get: { config.fpsLimit },
                                                           set: { value in model.update { $0.fpsLimit = value } }))
                        .fixedSize()
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Frame rate cap"))
                } label: {
                    HelpTitle("Frame rate cap", help: "Android draws at most this many frames per second, in every app. A screen’s own rate between 60 and 120 appears too, so Android runs in step with it. A rate above the one Android started at applies after a restart. 30 saves power and heat.")
                }
                FrameRateNote(cap: config.fpsLimit)
                IssueText(field: "fpsLimit")
            }
            Section {
                LabeledContent {
                    HazeSegmented.inset([(GraphicsProfile.apps, Text("Apps")), (GraphicsProfile.games, Text("Games"))], selection: $profile)
                        .fixedSize()
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Profile"))
                } label: {
                    HelpTitle("Profile", help: "Games are apps with a key mapping, or apps you set to game settings in their Graphics Settings.")
                }
                GraphicsSettingsEditor(settings: Binding(get: { config.settings(for: profile) }, set: { value in
                    let profile = profile
                    model.update { config in
                        switch profile {
                        case .apps: config.appGraphics = value
                        case .games: config.gameGraphics = value
                        }
                    }
                }), fieldPrefix: profile == .apps ? "appGraphics" : "gameGraphics")
                .id(profile)
                if !config.graphicsOverrides.isEmpty {
                    LabeledContent("Apps with their own settings: \(config.graphicsOverrides.count)") {
                        Button("Reset All…") { confirmResetAll = true }
                    }
                }
            } header: {
                HelpTitle("Resolution and Scaling", help: "Open windows adjust right away. Some apps reload their screen for a moment. Filter and sharpness change instantly.")
            }
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        PointsField(title: "Width", value: Binding(get: { config.defaultWindowSize.width },
                                                                   set: { value in model.update { $0.defaultWindowSize.width = value } }))
                        Text(verbatim: "×")
                        PointsField(title: "Height", value: Binding(get: { config.defaultWindowSize.height },
                                                                    set: { value in model.update { $0.defaultWindowSize.height = value } }))
                        Text("points").foregroundStyle(.secondary)
                    }
                } label: {
                    HelpTitle("Default window size", help: "The size of an app’s first window, turned to the orientation under Resolution and Scaling; no restart needed. After that, each app’s window opens where and as big as you left it.")
                }
                IssueText(field: "defaultWindowSize")
            } header: {
                Text("App windows")
            }
            Section {
                LabeledContent("Show in app windows") {
                    HazePicker("Show in app windows", selection: Binding(get: { config.performanceHUD },
                                                                         set: { value in model.update { $0.performanceHUD = value } })) {
                        Text("Off").tag(PerformanceHUDLevel.off)
                        Text("FPS Only").tag(PerformanceHUDLevel.fps)
                        Text("Detailed").tag(PerformanceHUDLevel.detailed)
                    }
                }
            } header: {
                HelpTitle("Performance HUD", help: "Open windows show it right away. ⌥⌘P in an app window shows or hides it for that window. It isn't included in Avo's screenshots and screen recordings.")
            }
            Section {
                HStack(spacing: 4) {
                    Button("Use “Heavy game” preset") {
                        let host = model.host
                        model.update { $0.applyHeavyGamePreset(host: host) }
                    }
                    HelpButton("Use “Heavy game” preset", "GPU rendering at Android’s full 60 FPS, at least 8 GB of memory, and games at 720p 16:9 with MetalFX upscaling. For games like Genshin Impact, PUBG Mobile and Delta Force. The renderer and memory apply after Android restarts.")
                }
                IssueText(field: "memoryMiB")
            }
        }
        .confirmationDialog("Use the default graphics settings for all apps?", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset All") {
                for package in model.config?.graphicsOverrides.keys.sorted() ?? [] { model.setAppGraphics(nil, for: package) }
            }
        }
    }
}

/// A number field without its own label, so it fits a form row.
private struct PointsField: View {
    let title: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        TextField(title, value: $value, format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .hazeField()
            .frame(width: 68)
            .help(title)
    }
}

// MARK: Sistem

struct SystemPane: View {
    @Environment(ControlPanelModel.self) private var model
    /// The sections to show: the Settings window spreads them over its panes.
    var sections: SystemSections = .all
    @State private var confirmADB = false
    @State private var confirmReset = false

    var body: some View {
        SettingsForm { config in
            AndroidVersionSection()
                .shown(sections.contains(.androidVersion))
            Section("Device profile") {
                LabeledContent {
                    HazePicker("Identify as", selection: Binding(get: { config.deviceProfileID },
                                                                 set: { value in model.update { $0.deviceProfileID = value } })) {
                        // Avo's honest identity first, then the phones it can impersonate.
                        let phones = model.profiles.filter { !$0.isAvoIdentity }
                        ForEach(model.profiles.filter(\.isAvoIdentity)) { Text($0.name).tag($0.id) }
                        if !phones.isEmpty {
                            Section("Impersonate a phone") {
                                ForEach(phones) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                } label: {
                    HelpTitle("Identify as") {
                        Text("Avo tells apps what it is: a device made by Avo, model AVO-Droid, running on a Mac. Games can recognize it and treat it like a PC.")
                        Text("A phone profile is impersonation: apps read that phone’s name and model instead. It does not pass hardware attestation, so banking and DRM apps may still refuse to run. Apps that check for Avo still find it.")
                    }
                }
                // The selected profile's hardware, and the checkbox that turns
                // it on. Hidden for the honest identity, which has none.
                if let profile = model.profiles.first(where: { $0.id == config.deviceProfileID }), profile.hasHardware {
                    Toggle(isOn: Binding(get: { config.emulateHardware },
                                         set: { value in model.update { $0.emulateHardware = value } })) {
                        HelpTitle("Emulate this phone’s hardware") {
                            Text("For development: apps read this phone’s SoC, CPU, GPU and screen, so a build’s per-device code paths (a chipset or brand check) run as they would on the real phone.")
                            Text("Names and IDs change; abilities (ABI, API level, GPU features) stay this Mac’s. It does not pass hardware attestation, and Avo still identifies itself. Applies after Android restarts.")
                        }
                    }
                    if config.emulateHardware, let hardware = profile.hardware {
                        DeviceSpecCard(hardware: hardware, display: profile.display)
                    }
                }
            }
            .shown(sections.contains(.identity))
            Section {
                // Read-only: the mode follows what Android has. Installing
                // Google apps sets it, Reset Android sets it back; Android
                // never reads it, so choosing one by hand would change nothing.
                LabeledContent("Mode") {
                    switch config.gms {
                    case .none: Text("None (F-Droid, Aurora Store)")
                    case .microG: Text("microG (not available yet)")
                    case .bringYourOwn: Text("Bring your own GApps")
                    }
                }
            } header: {
                HelpTitle("Google services") {
                    Text("Avo never ships Google apps. To use Google Play, install a MindTheGapps package you download yourself under Google apps below.")
                    if model.googleAppsInstalled {
                        Text("Google apps are installed. Reset Android removes them.")
                    }
                }
            }
            .shown(sections.contains(.googleApps))
            GoogleAppsSection(confirmReset: $confirmReset)
                .shown(sections.contains(.googleApps))
            Section("Location") {
                Toggle(isOn: Binding(get: { config.shareLocation }, set: { value in model.update { $0.shareLocation = value } })) {
                    HelpTitle("Share this Mac’s location with Android",
                              help: "Apps that ask for GPS get where this Mac is (as macOS knows it, usually from Wi-Fi). macOS asks for permission the first time.")
                }
                // An app window's Location panel (AvoWindowHost/LocationPanel.swift).
                RestartNote(text: "To put Android somewhere else, or move it along a route, choose Controls › Location… in an app window (⌥⌘L).")
            }
            .shown(sections.contains(.location))
            MacNotificationsSection()
                .shown(sections.contains(.notifications))
            Section("Developer") {
                // What ADB support exposes is said again before it turns on.
                Toggle(isOn: Binding(get: { config.adbEnabled }, set: { value in
                    if value { confirmADB = true } else { model.update { $0.adbEnabled = false } }
                })) {
                    HelpTitle("ADB support") {
                        Text("Lets adb, Android Studio or scrcpy on this Mac control Android. Only this Mac can connect, but any app on it can then install apps and read Android’s data, so turn it off when you don’t need it.")
                        if let adb = model.snapshot?.adb, adb.problem == nil, adb.port == VMConfig.defaultADBPort {
                            Text("adb also finds Android by itself, as emulator-5554, while it runs.")
                        }
                    }
                }
                if config.adbEnabled {
                    LabeledContent("Port") {
                        PointsField(title: "Port", value: Binding(get: { config.adbPort }, set: { value in model.update { $0.adbPort = value } }))
                    }
                    IssueText(field: "adbPort")
                    ADBStatusRow()
                }
            }
            .shown(sections.contains(.developer))
            Section("Shortcuts") {
                // Both apply to every app at once, and to apps installed later.
                Toggle(isOn: Binding(get: { config.createDesktopAlias }, set: { value in model.update { $0.createDesktopAlias = value } })) {
                    HelpTitle("Aliases on the Desktop", help: "Each Android app gets an alias on the Desktop. Turning this off removes Avo’s aliases; turning it on adds one for every app, and for apps you install later.")
                }
                Toggle(isOn: Binding(get: { config.addToDock }, set: { value in model.update { $0.addToDock = value } })) {
                    HelpTitle("Apps in the Dock", help: "Each Android app gets a tile in the Dock. Turning this off removes Avo’s tiles; turning it on adds one for every app, and for apps you install later.")
                }
                LabeledContent {
                    Button("Recreate Shortcuts") { model.recreateShortcuts() }
                } label: {
                    HelpTitle("App shortcuts", help: "Makes every app’s Mac app, icon, alias and Dock tile again, for example after moving Avo.")
                }
            }
            .shown(sections.contains(.shortcuts))
            Section("Maintenance") {
                Button("Reset Android…", role: .destructive) { confirmReset = true }
                    .disabled(model.isInstallingGoogleApps)
                if model.isInstallingGoogleApps {
                    RestartNote(text: "Available again when Avo finishes changing Google apps.")
                }
            }
            .shown(sections.contains(.maintenance))
        }
        .confirmationDialog("Turn on ADB support?", isPresented: $confirmADB, titleVisibility: .visible) {
            Button("Turn On ADB Support") { model.update { $0.adbEnabled = true } }
        } message: {
            Text("Lets adb, Android Studio or scrcpy on this Mac control Android. Only this Mac can connect, but any app on it can then install apps and read Android’s data, so turn it off when you don’t need it.")
        }
        .confirmationDialog("Reset Android?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase All Apps and Data", role: .destructive) { model.resetAndroid() }
        } message: {
            resetMessage
        }
    }

    /// What Reset Android takes away: Google apps live on the data disk too,
    /// with an Android ID of their own; verified boot stays as it is.
    private var resetMessage: Text {
        var text = Text("All Android apps, accounts and files are erased. Avo’s settings and the Android image are kept.")
        if model.googleAppsInstalled {
            text = text + Text(verbatim: " ")
                + Text("Google apps are removed too: install them again under Google apps and register the new Android ID.")
        }
        if model.verityKnownOff {
            text = text + Text(verbatim: " ") + Text("Verified boot stays off.")
        }
        if model.fingerprints?.fingers.contains(where: \.enrolled) ?? false {
            text = text + Text(verbatim: " ") + Text("Android forgets its fingerprints; your fingers stay in Settings › Fingerprints, to add again.")
        }
        return text
    }
}

/// SystemPane's sections, for the Settings window's panes.
struct SystemSections: OptionSet {
    let rawValue: Int

    static let androidVersion = SystemSections(rawValue: 1 << 0)
    static let identity = SystemSections(rawValue: 1 << 2)
    static let googleApps = SystemSections(rawValue: 1 << 3)
    static let location = SystemSections(rawValue: 1 << 4)
    static let notifications = SystemSections(rawValue: 1 << 5)
    static let developer = SystemSections(rawValue: 1 << 6)
    static let shortcuts = SystemSections(rawValue: 1 << 7)
    static let maintenance = SystemSections(rawValue: 1 << 8)
    static let all = SystemSections(rawValue: (1 << 9) - 1)
}

extension View {
    /// This section, or nothing.
    @ViewBuilder func shown(_ visible: Bool) -> some View {
        if visible { self }
    }
}

/// How to reach Android once ADB support is on (or why it cannot listen);
/// that adb also finds it as emulator-5554 is in ADB support's help.
private struct ADBStatusRow: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        if let adb = model.snapshot?.adb {
            if let problem = adb.problem {
                Label(problem, systemImage: "xmark.octagon.fill")
                    .font(.mona(12))
                    .foregroundStyle(Haze.danger)
            } else {
                LabeledContent("Connect with") {
                    HStack(spacing: 6) {
                        Text(verbatim: adb.connectCommand)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Haze.text)
                            .textSelection(.enabled)
                        CopyButton(text: adb.connectCommand)
                    }
                }
            }
        }
    }
}

/// Copies `text`, showing a checkmark for a moment.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? Haze.running : Haze.textSecondary)
        }
        .buttonStyle(HazeLinkButtonStyle())
        .help(copied ? Text("Copied") : Text("Copy"))
    }
}
