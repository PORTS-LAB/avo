import AvoADB
import AvoIO
import AvoKit
import AvoPackages
import AvoProtocol
import AvoShimKit
import Foundation
import IOSurface
import os
import UniformTypeIdentifiers

/// A client's XPC proxy, safe to keep in the actor (NSXPC proxies are thread-safe).
public struct ClientProxy: @unchecked Sendable {
    public let proxy: any AvoClientXPC

    public init(_ proxy: any AvoClientXPC) {
        self.proxy = proxy
    }

    func send(_ event: DaemonEvent) {
        proxy.handleEvent(AvoXPC.encode(event))
    }
}

/// IOSurface swapchains from the engine, passed through to App Shims.
public struct SurfaceList: @unchecked Sendable {
    public let surfaces: [IOSurface]

    public init(_ surfaces: [IOSurface]) {
        self.surfaces = surfaces
    }
}

/// The Runtime Daemon's state and behaviour, independent of XPC plumbing.
public actor DaemonCore {
    public struct Dependencies: Sendable {
        public var paths: AvoPaths
        public var engine: any VMEngine
        public var adbKey: ADBKey
        public var profiles: DeviceProfileCatalog
        public var host: HostInfo
        public var shortcuts: ShortcutManager
        public var notifications: any NotificationPresenter
        public var clipboard: any ClipboardBridge
        public var launcher: any AppLauncher
        public var softwareVersion: String
        public var bootTimeout: Duration
        public var loadImage: @Sendable () throws -> AndroidImage

        public init(paths: AvoPaths, engine: any VMEngine, adbKey: ADBKey, profiles: DeviceProfileCatalog, host: HostInfo,
                    shortcuts: ShortcutManager, notifications: any NotificationPresenter = NoNotifications(),
                    clipboard: any ClipboardBridge = NoClipboard(), launcher: any AppLauncher = NoLauncher(),
                    softwareVersion: String, bootTimeout: Duration = .seconds(180),
                    loadImage: @escaping @Sendable () throws -> AndroidImage) {
            self.paths = paths
            self.engine = engine
            self.adbKey = adbKey
            self.profiles = profiles
            self.host = host
            self.shortcuts = shortcuts
            self.notifications = notifications
            self.clipboard = clipboard
            self.launcher = launcher
            self.softwareVersion = softwareVersion
            self.bootTimeout = bootTimeout
            self.loadImage = loadImage
        }
    }

    public typealias ClientID = UUID

    struct Client {
        let role: ClientHello.Role
        let proxy: ClientProxy
    }

    struct Display {
        let id: UInt32
        let package: String
        let owner: ClientID
        var width: UInt32
        var height: UInt32
        var dpi: UInt32
        var ready = false
    }

    private let deps: Dependencies
    public nonisolated let vm: VMManager
    public nonisolated let registry: AppRegistry
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Daemon")

    private(set) var config: VMConfig
    /// Configuration the running VM booted with (for "restart needed").
    private var bootedConfig: VMConfig?
    private var clients: [ClientID: Client] = [:]
    private var displays: [UInt32: Display] = [:]
    private var nextDisplayID: UInt32 = 1
    private var lastClipboardFromGuest: String?
    private var started = false

    public init(_ deps: Dependencies) {
        self.deps = deps
        config = (try? VMConfig.load(from: deps.paths.config)) ?? VMConfig.recommended(for: deps.host)
        registry = AppRegistry(paths: deps.paths)
        vm = VMManager(engine: deps.engine, paths: deps.paths, softwareVersion: deps.softwareVersion,
                       adbKey: deps.adbKey, bootTimeout: deps.bootTimeout, loadImage: deps.loadImage)
    }

    /// Starts the event pumps. Call once after init.
    public func start() {
        guard !started else { return }
        started = true
        let vm = self.vm
        Task { [weak self] in
            for await event in vm.guestEvents { await self?.handleGuest(event) }
        }
        Task { [weak self] in
            for await status in vm.statusUpdates { await self?.vmStatusChanged(status) }
        }
        deps.notifications.start { [weak self] package, key in
            Task { await self?.openNotification(package: package, key: key) }
        }
        deps.clipboard.start { [weak self] text in
            Task { await self?.hostClipboardChanged(text) }
        }
    }

    private var settings: VMManager.Settings {
        VMManager.Settings(config: config, profile: deps.profiles.profile(id: config.deviceProfileID))
    }

    // MARK: Clients

    public func register(_ id: ClientID, role: ClientHello.Role, proxy: ClientProxy) async -> DaemonHello {
        clients[id] = Client(role: role, proxy: proxy)
        return DaemonHello(daemonVersion: deps.softwareVersion, status: await vm.status)
    }

    public func role(of id: ClientID) -> ClientHello.Role? { clients[id]?.role }

    public func disconnect(_ id: ClientID) async {
        clients[id] = nil
        // A shim that quits (or crashes) closes its windows' displays.
        for display in displays.values where display.owner == id {
            await closeDisplay(display.id, client: id)
        }
    }

    private func broadcast(_ event: DaemonEvent, to filter: (ClientHello.Role) -> Bool = { _ in true }) {
        for client in clients.values where filter(client.role) { client.proxy.send(event) }
    }

    private func isControlPanel(_ role: ClientHello.Role) -> Bool { role == .controlPanel }

    private func requireControlPanel(_ id: ClientID) throws {
        guard clients[id]?.role == .controlPanel else { throw AvoError.unauthorizedCaller }
    }

    // MARK: VM

    public func status() async -> VMStatus { await vm.status }

    public func startVM(client: ClientID) async throws {
        try requireControlPanel(client)
        try await ensureRunning()
    }

    public func stopVM(client: ClientID) async throws {
        try requireControlPanel(client)
        await vm.stop()
    }

    public func restartVM(client: ClientID) async throws {
        try requireControlPanel(client)
        await vm.stop()
        try await ensureRunning()
    }

    public func takeSnapshot(client: ClientID) async throws {
        try requireControlPanel(client)
        try await vm.takeSnapshot()
    }

    /// Sistem › Reset Android: wipes the data disk and snapshots, keeps the image.
    public func resetAndroid(client: ClientID) async throws {
        try requireControlPanel(client)
        await vm.stop()
        try? FileManager.default.removeItem(at: deps.paths.dataDisk)
        try? FileManager.default.removeItem(at: deps.paths.snapshots)
        for app in await registry.all() {
            deps.shortcuts.remove(app.shortcuts)
            await registry.remove(app.package)
            broadcast(.appRemoved(package: app.package))
        }
    }

    /// Start Android from the daemon's own menu bar item (same process, no XPC caller).
    public func startVMFromMenuBar() async throws {
        try await ensureRunning()
    }

    private func ensureRunning() async throws {
        let settings = self.settings
        try await vm.ensureRunning(settings)
        if bootedConfig == nil { bootedConfig = settings.config }
    }

    private func vmStatusChanged(_ status: VMStatus) async {
        broadcast(.vmStatus(status))
        switch status.state {
        case .running:
            await syncApps()
        case .stopped, .failed, .notInstalled:
            bootedConfig = nil
            for display in displays.values { clients[display.owner]?.proxy.send(.displayClosed(displayID: display.id)) }
            displays.removeAll()
        default:
            break
        }
    }

    /// After boot, the guest's package list is authoritative.
    private func syncApps() async {
        guard let control = try? await vm.controlSession(),
              let apps = try? await control.listApps(includeIcons: true) else { return }
        for info in apps where info.launchable {
            await appInstalled(info, replacing: false, announce: false)
        }
        for gone in await registry.retain(only: Set(apps.filter(\.launchable).map(\.package))) {
            deps.shortcuts.remove(gone.shortcuts)
        }
        let all = await registry.all()
        for app in all { broadcast(.appInstalled(app), to: isControlPanel) }
    }

    // MARK: Configuration

    public func configurationSnapshot() -> ConfigurationSnapshot {
        ConfigurationSnapshot(config: config, host: deps.host, profiles: deps.profiles.profiles,
                              pendingRestart: bootedConfig.map { config.effect(of: $0) == .restartRequired } ?? false)
    }

    public func updateConfiguration(_ new: VMConfig, client: ClientID) async throws -> ConfigUpdateResult {
        try requireControlPanel(client)
        var issues = new.validate(previous: config, host: deps.host)
        if deps.profiles.profile(id: new.deviceProfileID) == nil {
            issues.append(ConfigIssue(field: "deviceProfileID", severity: .error, message: "Unknown device profile."))
        }
        let effect = new.effect(of: config)
        guard !issues.contains(where: { $0.severity == .error }) else {
            return ConfigUpdateResult(effect: effect, issues: issues)
        }
        let old = config
        config = new
        try new.save(to: deps.paths.config)

        if new.fpsLimit != old.fpsLimit, let control = try? await vm.controlSession() {
            var request = Avo_V1_SetRefreshRate()
            request.fps = UInt32(new.fpsLimit)
            _ = try? await control.request(.setRefreshRate(request))
        }
        if new.createDesktopAlias != old.createDesktopAlias || new.addToDock != old.addToDock {
            for app in await registry.all() {
                var updated = app
                updated.shortcuts = deps.shortcuts.apply(app, info: nil, config: new)
                await registry.update(updated)
            }
        }
        broadcast(.configurationChanged(new), to: isControlPanel)
        return ConfigUpdateResult(effect: effect, issues: issues)
    }

    // MARK: Apps

    public func apps() async -> [AppRecord] { await registry.all() }

    public func icon(for package: String) async -> Data? { await registry.icon(for: package) }

    public func install(_ request: InstallRequest, file: OwnedDescriptor, client: ClientID) async throws {
        try requireControlPanel(client)
        let proxy = clients[client]?.proxy
        let vm = self.vm
        let settings = self.settings
        do {
            let package = try await InstallPipeline().run(
                request, file: file,
                ensureRunning: { [weak self] in
                    try await vm.ensureRunning(settings)
                    await self?.markBooted(settings.config)
                },
                adb: { try await vm.adbConnection() },
                report: { proxy?.send(.installProgress($0)) })
            proxy?.send(.installProgress(InstallProgress(id: request.id, phase: .creatingShortcuts, package: package)))
            proxy?.send(.installProgress(InstallProgress(id: request.id, phase: .finished, fraction: 1, package: package)))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            proxy?.send(.installProgress(InstallProgress(id: request.id, phase: .failed, message: message)))
            throw error
        }
    }

    private func markBooted(_ config: VMConfig) {
        if bootedConfig == nil { bootedConfig = config }
    }

    public func uninstall(_ package: String, client: ClientID) async throws {
        try requireControlPanel(client)
        var request = Avo_V1_Uninstall()
        request.package = package
        try await vm.controlSession().request(.uninstall(request))
    }

    public func forceStop(_ package: String, client: ClientID) async throws {
        try requireControlPanel(client)
        var request = Avo_V1_ForceStop()
        request.package = package
        try await vm.controlSession().request(.forceStop(request))
    }

    public func deleteAppData(_ package: String, client: ClientID) async throws {
        try requireControlPanel(client)
        var request = Avo_V1_DeleteAppData()
        request.package = package
        try await vm.controlSession().request(.deleteAppData(request))
    }

    public func permissions(for package: String, client: ClientID) async throws -> [AppPermission] {
        try requireControlPanel(client)
        return try await vm.controlSession().permissions(for: package).map {
            AppPermission(name: $0.name, label: $0.label, granted: $0.granted, runtime: $0.runtime)
        }
    }

    public func setPermission(_ permission: String, granted: Bool, for package: String, client: ClientID) async throws {
        try requireControlPanel(client)
        var request = Avo_V1_SetPermission()
        request.package = package
        request.permission = permission
        request.granted = granted
        try await vm.controlSession().request(.setPermission(request))
    }

    public func recreateShortcuts(for package: String?, client: ClientID) async throws {
        try requireControlPanel(client)
        for app in await registry.all() where package == nil || app.package == package {
            var updated = app
            updated.shortcuts = deps.shortcuts.apply(app, info: nil, config: config)
            await registry.update(updated)
        }
    }

    /// Code directory hashes of every shim the daemon created (XPC caller check).
    public func shimHashes() async -> [String: String] {
        var result: [String: String] = [:]
        for app in await registry.all() {
            if let hash = app.shortcuts.shimCDHash { result[app.package] = hash }
        }
        return result
    }

    // MARK: Displays

    public func openDisplay(_ request: OpenDisplayRequest, client: ClientID) async throws -> UInt32 {
        guard case .shim(let package)? = clients[client]?.role, package == request.package else {
            throw AvoError.unauthorizedCaller
        }
        try await ensureRunning()
        let id = nextDisplayID
        nextDisplayID &+= 1
        displays[id] = Display(id: id, package: package, owner: client, width: request.width, height: request.height, dpi: request.dpi)

        var launch = Avo_V1_Launch()
        launch.package = package
        launch.displayID = id
        launch.width = request.width
        launch.height = request.height
        launch.dpi = request.dpi
        launch.refreshRate = UInt32(config.fpsLimit)
        launch.notificationKey = request.notificationKey ?? ""
        launch.dataUri = request.dataURI ?? ""
        launch.mimeType = request.mimeType ?? ""
        do {
            try await vm.controlSession().request(.launch(launch))
        } catch {
            displays[id] = nil
            throw error
        }
        await vm.setOpenDisplays(displays.count)
        return id
    }

    private func ownedDisplay(_ id: UInt32, by client: ClientID) -> Display? {
        guard let display = displays[id], display.owner == client else { return nil }
        return display
    }

    public func resizeDisplay(_ id: UInt32, width: UInt32, height: UInt32, dpi: UInt32, client: ClientID) async {
        guard var display = ownedDisplay(id, by: client) else { return }
        display.width = width
        display.height = height
        display.dpi = dpi
        displays[id] = display
        var request = Avo_V1_Resize()
        request.displayID = id
        request.width = width
        request.height = height
        request.dpi = dpi
        _ = try? await vm.controlSession().request(.resize(request))
    }

    public func closeDisplay(_ id: UInt32, client: ClientID) async {
        guard ownedDisplay(id, by: client) != nil else { return }
        displays[id] = nil
        var request = Avo_V1_Close()
        request.displayID = id
        _ = try? await vm.controlSession().request(.close(request))
        await vm.setOpenDisplays(displays.count)
    }

    public func setDisplayVisible(_ id: UInt32, visible: Bool, client: ClientID) async {
        guard ownedDisplay(id, by: client) != nil else { return }
        var request = Avo_V1_SetDisplayVisibility()
        request.displayID = id
        request.visible = visible
        _ = try? await vm.controlSession().request(.setDisplayVisibility(request))
    }

    public func sendInput(_ record: Data, client: ClientID) async {
        let owned = Set(displays.values.filter { $0.owner == client }.map(\.id))
        guard !owned.isEmpty else { return }
        do {
            try await vm.inputChannel().forward(record, allowedDisplays: owned)
        } catch {
            logger.debug("dropped input: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drag and drop from Finder: copy into /sdcard/Download and share with the app.
    public func shareFiles(_ files: [(OwnedDescriptor, String)], displayID: UInt32, client: ClientID) async throws {
        guard ownedDisplay(displayID, by: client) != nil else { throw AvoError.unauthorizedCaller }
        let adb = try await vm.adbConnection()
        var request = Avo_V1_ShareFiles()
        request.displayID = displayID
        for (file, name) in files {
            let safeName = name.replacingOccurrences(of: "/", with: "-")
            let remote = "/sdcard/Download/" + safeName
            try await adb.push(Self.stream(file), to: remote, mode: 0o660)
            request.paths.append(remote)
            let ext = (safeName as NSString).pathExtension
            request.mimeTypes.append(UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
        }
        try await vm.controlSession().request(.shareFiles(request))
    }

    /// Streams an open file with backpressure.
    static func stream(_ file: OwnedDescriptor) -> ChunkPipe {
        ChunkPipe { send in
            var offset: off_t = 0
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let n = buffer.withUnsafeMutableBytes { pread(file.value, $0.baseAddress, $0.count, offset) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AvoError.internalError(String(cString: strerror(errno)))
                }
                if n == 0 { return }
                try send(Data(buffer[0..<n]))
                offset += off_t(n)
            }
        }
    }

    // MARK: Engine frames

    public func engineSetSurfaces(_ id: UInt32, surfaces: SurfaceList) {
        guard let display = displays[id], let owner = clients[display.owner] else { return }
        owner.proxy.proxy.setSurfaces(id, surfaces: surfaces.surfaces)
    }

    public func enginePresent(_ id: UInt32, surfaceIndex: Int, sequence: UInt64) {
        guard let display = displays[id], let owner = clients[display.owner] else { return }
        owner.proxy.proxy.present(id, surfaceIndex: surfaceIndex, sequence: sequence)
    }

    // MARK: Guest events

    func handleGuest(_ event: ControlSession.Payload) async {
        switch event {
        case .appInstalled(let installed):
            await appInstalled(installed.app, replacing: installed.replacing, announce: true)
        case .appRemoved(let removed):
            guard !removed.replacing, let record = await registry.remove(removed.package) else { return }
            deps.shortcuts.remove(record.shortcuts)
            broadcast(.appRemoved(package: removed.package), to: isControlPanel)
        case .displayReady(let ready):
            guard var display = displays[ready.displayID] else { return }
            display.ready = true
            displays[ready.displayID] = display
            clients[display.owner]?.proxy.send(.displayReady(displayID: ready.displayID))
        case .taskClosed(let closed):
            guard let display = displays.removeValue(forKey: closed.displayID) else { return }
            clients[display.owner]?.proxy.send(.displayClosed(displayID: closed.displayID))
            await vm.setOpenDisplays(displays.count)
        case .displayContentChanged(let changed):
            guard let display = displays[changed.displayID] else { return }
            clients[display.owner]?.proxy.send(.displayTitle(displayID: changed.displayID, title: changed.title))
        case .orientationRequest(let request):
            guard let display = displays[request.displayID] else { return }
            clients[display.owner]?.proxy.send(.orientationRequest(displayID: request.displayID,
                                                                    orientation: Self.orientation(request.orientation)))
        case .notification(let notification):
            let app = await registry.record(notification.package)
            deps.notifications.post(notification, appName: app?.displayName ?? notification.package,
                                    icon: await registry.icon(for: notification.package))
        case .notificationRemoved(let removed):
            deps.notifications.remove(key: removed.key)
        case .clipboardChanged(let changed):
            lastClipboardFromGuest = changed.text
            deps.clipboard.set(changed.text)
        default:
            break
        }
    }

    private func appInstalled(_ info: Avo_V1_AppInfo, replacing: Bool, announce: Bool) async {
        guard info.launchable else { return }
        let (record, iconChanged, labelChanged) = await registry.apply(info)
        var updated = record
        let shimMissing = record.shortcuts.shimPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
        if iconChanged || labelChanged || shimMissing {
            let shortcuts = deps.shortcuts
            let config = self.config
            updated.shortcuts = await Task.detached { shortcuts.apply(record, info: info, config: config) }.value
            await registry.update(updated)
        }
        if announce { broadcast(.appInstalled(updated), to: isControlPanel) }
    }

    private func openNotification(package: String, key: String) async {
        guard let shim = await registry.record(package)?.shortcuts.shimPath else { return }
        try? await deps.launcher.open(shim: URL(filePath: shim), arguments: ["--notification-key", key])
    }

    private func hostClipboardChanged(_ text: String) async {
        guard text != lastClipboardFromGuest, let control = try? await vm.controlSession() else { return }
        var request = Avo_V1_SetClipboard()
        request.text = text
        _ = try? await control.request(.setClipboard(request))
    }

    static func orientation(_ value: Avo_V1_Orientation) -> DisplayOrientation {
        switch value {
        case .portrait: .portrait
        case .landscape: .landscape
        case .reversePortrait: .reversePortrait
        case .reverseLandscape: .reverseLandscape
        default: .unspecified
        }
    }
}
