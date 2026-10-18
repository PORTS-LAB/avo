import AppKit
import AvoKit
import SwiftUI

// Settings › Storage › Shared Folder: a folder on the Mac that Android sees
// as “Avo Shared” in its storage (/sdcard/Avo Shared), both ways. Choosing
// one asks the daemon to look at it first (it reads it, so macOS asks in
// Avo's name about a protected folder or a drive); it takes effect when
// Android next starts (SharedFolder.swift, SharedFolderBridge.swift).

/// The Shared Folder card of Settings › Storage.
struct SharedFolderSection: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var choosing = false

    var body: some View {
        let config = model.config
        let status = model.sharedFolder
        Section {
            Toggle(isOn: Binding(get: { config?.shareFolder ?? false }, set: { on in
                if on, (config?.sharedFolderPath ?? "").isEmpty {
                    choose()
                } else {
                    model.update { $0.shareFolder = on }
                }
            })) {
                HelpTitle("Share a folder with Android") {
                    Text("Android sees the folder as “Avo Shared” in its storage, where its file pickers, file managers and apps find it. What Android saves there is on your Mac at once, and what you put there on the Mac appears in Android within a few seconds.")
                    Text("Photos, videos and music you add on the Mac also show up in Android’s gallery and music apps. Android uses the folder from its next start.")
                }
            }
            .disabled(choosing)
            if let path = config?.sharedFolderPath, !path.isEmpty {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: status?.volume.map { $0.isInternal ? "folder" : "externaldrive" } ?? "folder")
                                .foregroundStyle(.secondary)
                            Text(verbatim: StoragePane.abbreviated(path))
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                                .help(Text(verbatim: path))
                        }
                        HStack(spacing: 6) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                                .disabled(status?.problem != nil)
                            Button("Choose Folder…") { choose() }
                                .disabled(choosing)
                        }
                    }
                } label: {
                    Text("Folder")
                }
                if let volume = status?.volume, !volume.isInternal {
                    LabeledContent("Drive") {
                        Text("\(volume.name), \(volume.formatName), \(StoragePane.bytes(volume.freeBytes)) free")
                            .foregroundStyle(.secondary)
                    }
                }
                if config?.shareFolder == true, let status {
                    SharedFolderStateRow(status: status, choose: choose)
                }
            } else {
                LabeledContent {
                    Button("Choose Folder…") { choose() }
                        .disabled(choosing)
                } label: {
                    Text("Folder")
                }
            }
        } header: {
            Text("Shared Folder")
        }
        // Allowed in System Settings, or the drive connected meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshSharedFolder() }
        }
    }

    /// The folder panel, macOS's question, then the daemon's look; a folder
    /// that will do is saved and sharing turns on.
    private func choose() {
        guard !choosing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Share")
        panel.message = String(localized: "Choose a folder to share with Android. Android sees it as “Avo Shared” in its storage.")
        if let path = model.config?.sharedFolderPath, !path.isEmpty {
            panel.directoryURL = URL(filePath: path).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url, SharedFolderFlow.explain(url) else { return }
        choosing = true
        Task {
            defer { choosing = false }
            do {
                let found = try await model.inspectSharedFolder(url.path)
                if let problem = found.problem {
                    model.lastError = problem.message
                    return
                }
                model.update {
                    $0.sharedFolderPath = found.path ?? url.path
                    $0.shareFolder = true
                }
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}

/// What Android does with the folder, or why it cannot.
private struct SharedFolderStateRow: View {
    @Environment(ControlPanelModel.self) private var model
    let status: SharedFolderStatus
    let choose: () -> Void

    var body: some View {
        if let problem = status.problem {
            HazeNote(symbol: "folder.badge.questionmark", tint: Haze.warning, text: Text(verbatim: problem.message)) {
                HStack(spacing: 8) {
                    if case .notPermitted = problem {
                        Button("Open System Settings") { StorageLocationFlow.openFilesAndFolders() }
                    }
                    Button("Choose Another…") { choose() }
                }
            }
        } else {
            switch status.mount {
            case .mounted?:
                HazeNote(symbol: "checkmark.circle.fill", tint: Haze.positive,
                         text: Text("Android has this folder as “Avo Shared” in its storage (\(SharedFolder.androidPath))."))
            case .waiting?:
                HazeNote(symbol: "lock.fill", tint: Haze.textTertiary,
                         text: Text("Android shares the folder once its screen lock is entered."))
            case .failed?:
                HazeNote(symbol: "exclamationmark.triangle.fill", tint: Haze.warning,
                         text: Text("Android couldn’t open the shared folder. Restart Android to try again.")) {
                    Button("Restart Android") { model.restartVM() }
                }
            case .unavailable?:
                HazeNote(symbol: "arrow.clockwise.circle.fill", tint: Haze.textTertiary,
                         text: Text("Android shares the folder from its next start.")) {
                    Button("Restart Android") { model.restartVM() }
                }
            case nil:
                HazeNote(symbol: "folder.fill", tint: Haze.textTertiary,
                         text: Text("Android shares the folder when it starts."))
            }
            if status.readOnly, let volume = status.volume {
                HazeNote(symbol: "lock.doc", tint: Haze.warning,
                         text: Text("“\(volume.name)” is read-only: Android can open the files but not change them."))
            }
        }
    }
}

@MainActor
enum SharedFolderFlow {
    /// The daemon reads the folder, and for a drive, Documents, Desktop or
    /// Downloads macOS asks first whether Avo may: said before it asks (once
    /// for drives), so the answer is Allow.
    static func explain(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let alert = NSAlert()
        if let folder = ["Documents", "Desktop", "Downloads"].first(where: { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }) {
            let name = FileManager.default.displayName(atPath: "\(home)/\(folder)")
            alert.messageText = String(localized: "Allow Avo to use your \(name) folder")
            alert.informativeText = String(localized: "Android reads and writes the shared folder’s files while it runs. macOS may ask next whether “Avo” may access files in your \(name) folder: choose Allow.")
        } else {
            let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
            let values = try? url.resourceValues(forKeys: keys)
            let removable = values?.volumeIsInternal == false || values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
            guard removable, !UserDefaults.standard.bool(forKey: StorageLocationFlow.explainedKey) else { return true }
            UserDefaults.standard.set(true, forKey: StorageLocationFlow.explainedKey)
            let name = values?.volumeName ?? url.lastPathComponent
            alert.messageText = String(localized: "Allow Avo to use “\(name)”")
            alert.informativeText = String(localized: "Android reads and writes the shared folder’s files on this drive while it runs. macOS asks next whether “Avo” may access files on a removable volume: choose Allow.")
        }
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
