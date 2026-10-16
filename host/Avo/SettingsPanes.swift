import AvoKit
import SwiftUI

// Control Panel tabs from spec §6. Changes apply immediately; the daemon
// decides whether they need a VM restart and the restart banner appears.

private struct SettingsForm<Content: View>: View {
    @Environment(ControlPanelModel.self) private var model
    @ViewBuilder var content: (VMConfig) -> Content

    var body: some View {
        if let config = model.config {
            Form { content(config) }
                .formStyle(.grouped)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct IssueText: View {
    @Environment(ControlPanelModel.self) private var model
    let field: String

    var body: some View {
        if let issue = model.issue(for: field) {
            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(issue.severity == .error ? .red : .orange)
        }
    }
}

private struct RestartNote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: Performa

struct PerformancePane: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        SettingsForm { config in
            let host = model.host
            Section {
                LabeledContent("Memory") {
                    HStack {
                        Slider(value: Binding(get: { Double(config.memoryMiB) },
                                              set: { value in model.update { $0.memoryMiB = Int(value / 512) * 512 } }),
                               in: Double(VMConfig.memoryRangeMiB.lowerBound)...Double(max(host.maxGuestMemoryMiB, VMConfig.memoryRangeMiB.lowerBound + 512)),
                               step: 512)
                        Text("\(Double(config.memoryMiB) / 1024, specifier: "%.1f") GB")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                IssueText(field: "memoryMiB")
                LabeledContent("CPU cores") {
                    Stepper(value: Binding(get: { config.cpuCount }, set: { value in model.update { $0.cpuCount = value } }),
                            in: 1...host.totalCores) {
                        Text("\(config.cpuCount) of \(host.totalCores)").monospacedDigit()
                    }
                }
                IssueText(field: "cpuCount")
                Toggle("Return unused memory to macOS when idle",
                       isOn: Binding(get: { config.balloonWhenIdle }, set: { value in model.update { $0.balloonWhenIdle = value } }))
            } footer: {
                RestartNote(text: "Applies after Android restarts. This Mac has \(host.performanceCores) performance cores and \(host.physicalMemoryBytes / 1_073_741_824) GB of memory.")
            }
        }
    }
}

// MARK: Storage

struct StoragePane: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var minimumDisk: Int?

    var body: some View {
        SettingsForm { config in
            Section {
                LabeledContent("Data disk") {
                    Stepper(value: Binding(get: { config.dataDiskGiB }, set: { value in model.update { $0.dataDiskGiB = value } }),
                            in: (minimumDisk ?? config.dataDiskGiB)...1024, step: 8) {
                        Text("\(config.dataDiskGiB) GB").monospacedDigit()
                    }
                }
                IssueText(field: "dataDiskGiB")
                LabeledContent("Image location") {
                    Text(config.imageLocation ?? "~/Library/Application Support/Avo")
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
            } footer: {
                RestartNote(text: "The data disk can be enlarged but never shrunk. Enlarging it takes effect after Android restarts.")
            }
            .onAppear { minimumDisk = minimumDisk ?? config.dataDiskGiB }
        }
    }
}

// MARK: Grafis

struct GraphicsPane: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        SettingsForm { config in
            Section {
                Picker("Renderer", selection: Binding(get: { config.renderer }, set: { value in model.update { $0.renderer = value } })) {
                    Text("Vulkan").tag(VMConfig.Renderer.vulkan)
                    Text("OpenGL ES").tag(VMConfig.Renderer.gles)
                }
                RestartNote(text: "Changing the renderer restarts Android.")
                Picker("Frame rate limit", selection: Binding(get: { config.fpsLimit }, set: { value in model.update { $0.fpsLimit = value } })) {
                    ForEach(VMConfig.fpsChoices, id: \.self) { Text("\($0) FPS").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Default density", selection: Binding(get: { config.defaultDPI ?? 0 },
                                                             set: { value in model.update { $0.defaultDPI = value == 0 ? nil : value } })) {
                    Text("Automatic (match Retina)").tag(0)
                    ForEach([240, 280, 320, 360, 400, 480], id: \.self) { Text("\($0) dpi").tag($0) }
                }
                IssueText(field: "fpsLimit")
            }
            Section {
                Button("Use “Heavy game” preset") {
                    let host = model.host
                    model.update { $0.applyHeavyGamePreset(host: host) }
                }
                IssueText(field: "memoryMiB")
            } footer: {
                RestartNote(text: "Vulkan, 120 FPS and at least 8 GB of memory, for games like Genshin Impact, PUBG Mobile and Delta Force.")
            }
        }
    }
}

// MARK: Display

struct DisplayPane: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        SettingsForm { config in
            Section {
                LabeledContent("Default window size") {
                    HStack(spacing: 6) {
                        TextField("Width", value: Binding(get: { config.defaultWindowSize.width },
                                                          set: { value in model.update { $0.defaultWindowSize.width = value } }),
                                  format: .number)
                            .frame(width: 70)
                        Text("×")
                        TextField("Height", value: Binding(get: { config.defaultWindowSize.height },
                                                           set: { value in model.update { $0.defaultWindowSize.height = value } }),
                                  format: .number)
                            .frame(width: 70)
                        Text("points").foregroundStyle(.secondary)
                    }
                }
                IssueText(field: "defaultWindowSize")
                Picker("Orientation", selection: Binding(get: { config.defaultOrientation },
                                                        set: { value in model.update { $0.defaultOrientation = value } })) {
                    Text("Portrait").tag(VMConfig.Orientation.portrait)
                    Text("Landscape").tag(VMConfig.Orientation.landscape)
                }
                .pickerStyle(.segmented)
                Toggle("Render at Retina resolution",
                       isOn: Binding(get: { config.retinaScaling }, set: { value in model.update { $0.retinaScaling = value } }))
            } footer: {
                RestartNote(text: "Applies to windows you open next; no restart needed. Apps can still request their own orientation.")
            }
        }
    }
}

// MARK: Sistem

struct SystemPane: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var confirmRoot = false
    @State private var confirmReset = false

    var body: some View {
        SettingsForm { config in
            Section("Root") {
                Toggle("Root access (KernelSU)", isOn: Binding(get: { config.rooted }, set: { value in
                    if value { confirmRoot = true } else { model.update { $0.rooted = false } }
                }))
                RestartNote(text: "Swaps the system overlay at the next boot. Your apps and data are not touched.")
            }
            Section("Device profile") {
                Picker("Identify as", selection: Binding(get: { config.deviceProfileID },
                                                         set: { value in model.update { $0.deviceProfileID = value } })) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
                Label("A profile changes the device name and model apps read. It does not pass hardware attestation, so banking and DRM apps may still refuse to run.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Google services") {
                Picker("Mode", selection: Binding(get: { config.gms }, set: { value in model.update { $0.gms = value } })) {
                    Text("None (F-Droid, Aurora Store)").tag(VMConfig.GMSMode.none)
                    Text("microG").tag(VMConfig.GMSMode.microG)
                    Text("Bring your own GApps").tag(VMConfig.GMSMode.bringYourOwn)
                }
                RestartNote(text: "Avo never ships Google apps. With “Bring your own”, a setup wizard installs a GApps package you download yourself.")
            }
            Section("Shortcuts") {
                Toggle("Create an alias on the Desktop for new apps",
                       isOn: Binding(get: { config.createDesktopAlias }, set: { value in model.update { $0.createDesktopAlias = value } }))
                Toggle("Add new apps to the Dock",
                       isOn: Binding(get: { config.addToDock }, set: { value in model.update { $0.addToDock = value } }))
                Button("Recreate Shortcuts") { model.recreateShortcuts() }
            }
            Section("Maintenance") {
                Button("Save Quick-Boot Snapshot") { model.takeSnapshot() }
                    .disabled(model.status.state != .running)
                Button("Reset Android…", role: .destructive) { confirmReset = true }
            }
        }
        .confirmationDialog("Turn on root access?", isPresented: $confirmRoot, titleVisibility: .visible) {
            Button("Turn On Root") { model.update { $0.rooted = true } }
        } message: {
            Text("Apps that check device integrity (banking, payments, some games) will refuse to run while Android is rooted.")
        }
        .confirmationDialog("Reset Android?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase All Apps and Data", role: .destructive) { model.resetAndroid() }
        } message: {
            Text("All Android apps, accounts and files are erased. Avo’s settings and the Android image are kept.")
        }
    }
}
