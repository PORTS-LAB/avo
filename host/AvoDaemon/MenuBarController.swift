import AppKit
import AvoDaemonCore
import AvoKit

/// Menu Bar Item (spec: NSStatusItem with VM status, start/stop and a
/// shortcut to the Control Panel), plus quick access to installed apps.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let core: DaemonCore
    private let avoApp: URL
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var status = VMStatus.stopped
    private var apps: [AppRecord] = []

    init(core: DaemonCore, avoApp: URL) {
        self.core = core
        self.avoApp = avoApp
        super.init()
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Avo"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        let updates = core.vm.statusUpdates
        Task { [weak self] in
            for await status in updates { self?.update(status) }
        }
    }

    private func update(_ status: VMStatus) {
        self.status = status
        // Dim the icon while Android is not running.
        item.button?.appearsDisabled = status.state != .running
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: Self.title(for: status), action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if status.state == .running {
            menu.addItem(withTitle: "Stop Android", action: #selector(stopVM), keyEquivalent: "").target = self
        } else {
            let start = menu.addItem(withTitle: "Start Android", action: #selector(startVM), keyEquivalent: "")
            start.target = self
            start.isEnabled = ![.starting, .stopping].contains(status.state)
        }
        menu.addItem(.separator())

        if !apps.isEmpty {
            let appsItem = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for app in apps.prefix(30) where app.shortcuts.shimPath != nil {
                let entry = submenu.addItem(withTitle: app.displayName, action: #selector(openApp(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = app.shortcuts.shimPath
                if let shim = app.shortcuts.shimPath {
                    let icon = NSWorkspace.shared.icon(forFile: shim)
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
            }
            appsItem.submenu = submenu
            menu.addItem(appsItem)
        }
        menu.addItem(withTitle: "Open Control Panel…", action: #selector(openControlPanel), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Avo", action: #selector(quit), keyEquivalent: "q").target = self

        Task { [weak self] in
            guard let self else { return }
            self.apps = await core.apps()
        }
    }

    private static func title(for status: VMStatus) -> String {
        switch status.state {
        case .running: "Android is running" + (status.openDisplays > 0 ? " · \(status.openDisplays) open" : "")
        case .starting: "Android is starting…"
        case .stopping: "Android is stopping…"
        case .stopped: "Android is stopped"
        case .notInstalled: "Android image not installed"
        case .failed: "Android stopped: \(status.detail ?? "error")"
        case .suspending, .suspended: "Android is suspended"
        }
    }

    @objc private func startVM() {
        Task { try? await core.startVMFromMenuBar() }
    }

    @objc private func stopVM() {
        Task { await core.vm.stop() }
    }

    @objc private func openApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openControlPanel() {
        NSWorkspace.shared.openApplication(at: avoApp, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() {
        Task {
            await core.vm.stop()
            exit(0)
        }
    }
}
