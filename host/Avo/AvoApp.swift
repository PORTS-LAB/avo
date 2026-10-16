import AppKit
import AvoKit
import SwiftUI

@main
struct AvoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Avo", id: "control-panel") {
            ContentView()
                .environment(appDelegate.model)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Install Android App…") { appDelegate.chooseAndInstall() }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Opens package files from Finder (double-click, Dock icon drop, Open With).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ControlPanelModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // One confirmation sheet at a time; extra files wait for the next drop.
        if let url = urls.first(where: { ControlPanelModel.packageExtensions.contains($0.pathExtension.lowercased()) }) {
            model.prepareInstall(url)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The VM keeps running in the background; the menu bar item stays.
        true
    }

    func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["apk", "xapk", "apkm", "apks"].compactMap { .init(filenameExtension: $0) }
        panel.prompt = String(localized: "Install")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.prepareInstall(url)
    }
}
