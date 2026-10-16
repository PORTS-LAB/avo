import AppKit
import AvoKit
import AvoPackages
import Observation
import os
import ServiceManagement

/// State of the Control Panel, fed by the Runtime Daemon over XPC.
@MainActor
@Observable
final class ControlPanelModel {
    enum DaemonState: Equatable {
        case connecting
        case connected
        case needsApproval
        case unavailable(String)
    }

    /// A package the user opened, waiting for confirmation or installing.
    struct PendingInstall: Identifiable {
        let id = UUID()
        let url: URL
        var summary: PackageSummary?
        var inspectionError: String?
        var progress: InstallProgress?
        var finishedPackage: String?
    }

    private(set) var daemonState: DaemonState = .connecting
    private(set) var status = VMStatus.stopped
    private(set) var apps: [AppRecord] = []
    private(set) var icons: [String: NSImage] = [:]
    private(set) var snapshot: ConfigurationSnapshot?
    private(set) var configIssues: [ConfigIssue] = []
    var pendingInstall: PendingInstall?
    var lastError: String?

    private var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "ControlPanel")
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var config: VMConfig? { snapshot?.config }
    var host: HostInfo { snapshot?.host ?? HostInfo.current() }
    var profiles: [DeviceProfile] { snapshot?.profiles ?? [] }
    var pendingRestart: Bool { snapshot?.pendingRestart ?? false }

    // MARK: Connection

    func start() {
        registerDaemon()
        connect()
    }

    /// Registers the LaunchAgent that hosts the Runtime Daemon (spec: "LaunchAgent").
    private func registerDaemon() {
        // Development: run the daemon with launchctl instead (see host/README.md).
        if UserDefaults.standard.bool(forKey: "AvoSkipDaemonRegistration") { return }
        let service = SMAppService.agent(plistName: "\(AvoIdentifiers.daemonLabel).plist")
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            daemonState = .needsApproval
        default:
            do {
                try service.register()
            } catch {
                logger.error("LaunchAgent registration failed: \(error.localizedDescription, privacy: .public)")
                if service.status == .requiresApproval { daemonState = .needsApproval }
            }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func connect() {
        eventTask?.cancel()
        client?.invalidate()
        let client = DaemonClient(role: .controlPanel, version: "avo-control-panel \(Self.version)")
        self.client = client
        eventTask = Task { [weak self] in
            do {
                let hello = try await client.hello()
                self?.daemonState = .connected
                self?.status = hello.status
                await self?.refresh()
            } catch {
                if self?.daemonState != .needsApproval {
                    self?.daemonState = .unavailable(error.localizedDescription)
                }
                return
            }
            for await event in client.events {
                self?.handle(event)
            }
            // The daemon went away (update, crash): try again shortly.
            self?.daemonState = .connecting
            try? await Task.sleep(for: .seconds(2))
            self?.connect()
        }
    }

    func refresh() async {
        guard let client else { return }
        do {
            async let snapshot = client.configuration()
            async let apps = client.apps()
            self.snapshot = try await snapshot
            self.apps = try await apps
            for app in self.apps { await loadIcon(app.package) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handle(_ event: DaemonEvent) {
        switch event {
        case .vmStatus(let status):
            self.status = status
            if status.state == .running || status.state == .stopped {
                Task { await refreshConfiguration() }
            }
        case .appInstalled(let record):
            apps.removeAll { $0.package == record.package }
            apps.append(record)
            apps.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            Task { await loadIcon(record.package, force: true) }
        case .appRemoved(let package):
            apps.removeAll { $0.package == package }
            icons[package] = nil
        case .installProgress(let progress):
            guard var pending = pendingInstall else { return }
            pending.progress = progress
            if progress.phase == .finished { pending.finishedPackage = progress.package }
            pendingInstall = pending
        case .configurationChanged(let config):
            snapshot?.config = config
        default:
            break
        }
    }

    private func refreshConfiguration() async {
        if let snapshot = try? await client?.configuration() { self.snapshot = snapshot }
    }

    private func loadIcon(_ package: String, force: Bool = false) async {
        guard force || icons[package] == nil, let data = try? await client?.icon(for: package) else { return }
        icons[package] = NSImage(data: data)
    }

    // MARK: VM

    func startVM() { perform { try await $0.startVM() } }
    func stopVM() { perform { try await $0.stopVM() } }
    func restartVM() { perform { try await $0.restartVM() } }
    func takeSnapshot() { perform { try await $0.takeSnapshot() } }
    func resetAndroid() { perform { try await $0.resetAndroid() } }

    private func perform(_ action: @escaping @Sendable (DaemonClient) async throws -> Void) {
        guard let client else { return }
        Task {
            do {
                try await action(client)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Configuration

    /// Applies a change right away; the daemon reports whether it needs a restart.
    func update(_ change: (inout VMConfig) -> Void) {
        guard var config = snapshot?.config, let client else { return }
        change(&config)
        guard config != snapshot?.config else { return }
        let previous = snapshot?.config
        snapshot?.config = config
        Task {
            do {
                let result = try await client.updateConfiguration(config)
                configIssues = result.issues
                if result.issues.contains(where: { $0.severity == .error }), let previous {
                    snapshot?.config = previous
                }
                await refreshConfiguration()
            } catch {
                lastError = error.localizedDescription
                if let previous { snapshot?.config = previous }
            }
        }
    }

    func issue(for field: String) -> ConfigIssue? {
        configIssues.first { $0.field == field }
    }

    // MARK: Apps

    func open(_ app: AppRecord) {
        guard let shim = app.shortcuts.shimPath else {
            lastError = "\(app.displayName) has no shortcut yet. Use “Recreate Shortcuts” in Settings › System."
            return
        }
        NSWorkspace.shared.openApplication(at: URL(filePath: shim), configuration: NSWorkspace.OpenConfiguration())
    }

    func uninstall(_ app: AppRecord) { perform { try await $0.uninstall(app.package) } }
    func forceStop(_ app: AppRecord) { perform { try await $0.forceStop(app.package) } }
    func deleteData(_ app: AppRecord) { perform { try await $0.deleteAppData(app.package) } }
    func recreateShortcuts() { perform { try await $0.recreateShortcuts() } }

    func permissions(for app: AppRecord) async -> [AppPermission] {
        (try? await client?.permissions(for: app.package)) ?? []
    }

    func setPermission(_ permission: AppPermission, granted: Bool, for app: AppRecord) async {
        do {
            try await client?.setPermission(permission.name, granted: granted, for: app.package)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Installing (spec §3)

    static let packageExtensions: Set<String> = ["apk", "xapk", "apkm", "apks"]

    /// Shows the confirmation sheet for a package file (double-click, drop, File › Install).
    func prepareInstall(_ url: URL) {
        guard Self.packageExtensions.contains(url.pathExtension.lowercased()) else {
            lastError = "\(url.lastPathComponent) is not an Android package."
            return
        }
        var pending = PendingInstall(url: url)
        pendingInstall = pending
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try PackageArchive(url: url).summary
                pending.summary = summary
            } catch {
                pending.inspectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await MainActor.run { [pending] in
                if self.pendingInstall?.id == pending.id { self.pendingInstall = pending }
            }
        }
    }

    func confirmInstall() {
        guard let pending = pendingInstall, let client else { return }
        let request = InstallRequest(path: pending.url.path)
        pendingInstall?.progress = InstallProgress(id: request.id, phase: .inspecting)
        Task {
            do {
                try await client.install(request)
            } catch {
                pendingInstall?.progress = InstallProgress(id: request.id, phase: .failed, message: error.localizedDescription)
            }
        }
    }

    func dismissInstall() {
        pendingInstall = nil
    }
}
