import AppKit
import AvoKit
import os

/// Entry point called by the App Shim loader (AvoShim/main.swift) after it
/// loads this framework from Avo.app.
@_cdecl("AvoShimMain")
public func AvoShimMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    MainActor.assumeIsolated {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let package = info[AvoIdentifiers.shimPackageInfoKey] as? String else {
            NSLog("Avo: this shim has no \(AvoIdentifiers.shimPackageInfoKey); recreate shortcuts in Avo")
            exit(2)
        }
        let label = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? package
        let arguments = Array(CommandLine.arguments.dropFirst())
        let notificationKey = arguments.firstIndex(of: "--notification-key").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        let app = NSApplication.shared
        let delegate = ShimAppDelegate(package: package, label: label, notificationKey: notificationKey)
        ShimAppDelegate.retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
    return 0
}

/// One App Shim process = one Android app in the Dock (spec §4). Each window
/// of the app is an Android VirtualDisplay.
@MainActor
final class ShimAppDelegate: NSObject, NSApplicationDelegate {
    static var retained: ShimAppDelegate?

    let package: String
    let label: String
    private var pendingNotificationKey: String?
    private let frames = FrameRouter()
    private var client: DaemonClient?
    private(set) var config = VMConfig()
    private var windows: [AndroidWindowController] = []
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Shim")

    init(package: String, label: String, notificationKey: String?) {
        self.package = package
        self.label = label
        self.pendingNotificationKey = notificationKey
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let version = Bundle(for: ShimAppDelegate.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let client = DaemonClient(role: .shim(package: package), version: "avo-shim \(version)", frameReceiver: frames)
        self.client = client
        Task {
            do {
                _ = try await client.hello()
                if let snapshot = try? await client.configuration() { config = snapshot.config }
                openWindow(notificationKey: pendingNotificationKey)
                pendingNotificationKey = nil
                for await event in client.events { handle(event) }
                // The daemon restarted: our displays are gone.
                for window in windows { window.showProblem("Avo’s background service restarted.") }
            } catch {
                logger.error("cannot reach the daemon: \(error.localizedDescription, privacy: .public)")
                let window = openWindow(notificationKey: nil, connect: false)
                window.showProblem((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    @discardableResult
    func openWindow(notificationKey: String?, connect: Bool = true) -> AndroidWindowController {
        let controller = AndroidWindowController(app: self, frames: frames)
        windows.append(controller)
        controller.showWindow(nil)
        if connect, let client { controller.attach(client: client, notificationKey: notificationKey) }
        return controller
    }

    func windowClosed(_ controller: AndroidWindowController) {
        windows.removeAll { $0 === controller }
        if windows.isEmpty { NSApp.terminate(nil) }
    }

    private func handle(_ event: DaemonEvent) {
        switch event {
        case .displayReady(let id):
            window(for: id)?.displayReady()
        case .displayClosed(let id):
            // The Android task finished (e.g. the app called finish()).
            window(for: id)?.closeFromGuest()
        case let .displayTitle(id, title):
            window(for: id)?.window?.subtitle = title
        case let .orientationRequest(id, orientation):
            window(for: id)?.applyOrientation(orientation)
        case .vmStatus(let status) where status.state == .failed || status.state == .stopped:
            for window in windows { window.showProblem(status.detail ?? "Android stopped.") }
        case .configurationChanged(let config):
            self.config = config
        default:
            break
        }
    }

    private func window(for displayID: UInt32) -> AndroidWindowController? {
        windows.first { $0.displayID == displayID }
    }

    // MARK: App behaviour

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(notificationKey: nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        for window in windows { window.detach() }
    }

    /// Files dropped on the app's Dock icon are shared with it (spec: drag and drop).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let target = windows.first(where: { $0.window?.isKeyWindow == true }) ?? windows.first else { return }
        target.share(urls)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(label)", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(label)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(label)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let gameItem = NSMenuItem()
        let gameMenu = NSMenu(title: "Controls")
        let editor = gameMenu.addItem(withTitle: "Edit Key Mapping…", action: #selector(AndroidWindowController.toggleKeymapEditor),
                                      keyEquivalent: "k")
        editor.keyEquivalentModifierMask = [.command, .shift]
        gameMenu.addItem(withTitle: "Back", action: #selector(AndroidWindowController.sendBack), keyEquivalent: "[")
        gameItem.submenu = gameMenu
        main.addItem(gameItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Rotate", action: #selector(AndroidWindowController.rotateWindow), keyEquivalent: "r")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func newWindow() {
        openWindow(notificationKey: nil)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: label,
            .credits: NSAttributedString(string: "Android app \(package), running in Avo."),
        ])
    }
}
