import AvoADB
import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// macOS's side of the notification permission, as the test decides it.
final class PermissionNotifications: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var current: MacNotificationPermission
    private var onChange: (@Sendable (MacNotificationPermission) -> Void)?
    private var requests = 0

    init(_ state: MacNotificationPermission.State) {
        current = MacNotificationPermission(state: state)
    }

    var requestCount: Int { lock.withLock { requests } }

    func start(onOpen: @escaping @Sendable (String, String) -> Void) {}
    func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?) {}
    func remove(key: String) {}

    func permission() async -> MacNotificationPermission { lock.withLock { current } }

    /// macOS shows its alert and waits for the user.
    func requestPermission() async -> MacNotificationPermission {
        lock.withLock {
            requests += 1
            if current.state == .notDetermined { current.asking = true }
            return current
        }
    }

    func observePermission(_ onChange: @escaping @Sendable (MacNotificationPermission) -> Void) {
        lock.withLock { self.onChange = onChange }
    }

    /// The user answers macOS's alert.
    func answer(_ state: MacNotificationPermission.State) {
        let (now, onChange) = lock.withLock { () -> (MacNotificationPermission, (@Sendable (MacNotificationPermission) -> Void)?) in
            current = MacNotificationPermission(state: state)
            return (current, self.onChange)
        }
        onChange?(now)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct NotificationPermissionTests {
    /// A daemon that never boots Android: the permission does not need it.
    private static func daemon(_ notifications: PermissionNotifications) throws -> (core: DaemonCore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-notifications-\(UUID().uuidString.prefix(8))")
        let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        let core = DaemonCore(.init(paths: paths, engine: FakeEngine(agent: FakeBridgeAgent(apps: [])), adbKey: try ADBKey.generate(),
                                    profiles: DeviceProfileCatalog(profiles: []), host: HostInfo.current(),
                                    shortcuts: ShortcutManager(builder: nil, paths: paths), notifications: notifications,
                                    softwareVersion: "avo-host test", loadImage: { throw AvoError.vmNotRunning }))
        return (core, root)
    }

    private static func connect(_ core: DaemonCore, as role: ClientHello.Role) async -> (UUID, RecordingClient) {
        let id = UUID()
        let client = RecordingClient()
        _ = await core.register(id, role: role, proxy: ClientProxy(client))
        return (id, client)
    }

    @Test func aControlPanelLearnsThePermissionWhenItConnects() async throws {
        let (core, root) = try Self.daemon(PermissionNotifications(.denied))
        defer { try? FileManager.default.removeItem(at: root) }
        await core.start()
        let (_, panel) = await Self.connect(core, as: .controlPanel)
        let event = await panel.wait { if case .macNotifications = $0 { true } else { false } }
        #expect(event == .macNotifications(MacNotificationPermission(state: .denied)))
        #expect(await panel.wait { if case .notifications([]) = $0 { true } else { false } } != nil)
    }

    /// Request Permission: the daemon asks macOS, replies while its alert
    /// waits, and passes the user's answer on to every Control Panel.
    @Test func requestPermissionAsksMacOSAndTheAnswerFollows() async throws {
        let notifications = PermissionNotifications(.notDetermined)
        let (core, root) = try Self.daemon(notifications)
        defer { try? FileManager.default.removeItem(at: root) }
        await core.start()
        let (id, panel) = await Self.connect(core, as: .controlPanel)

        let reply = try await core.requestNotificationPermission(client: id)
        #expect(reply == MacNotificationPermission(state: .notDetermined, asking: true))
        #expect(notifications.requestCount == 1)
        #expect(try await core.notificationPermission(client: id).asking)

        notifications.answer(.allowed)
        #expect(await panel.wait { $0 == .macNotifications(.allowed) } != nil)
        #expect(try await core.notificationPermission(client: id) == .allowed)
    }

    @Test func onlyTheControlPanelAsks() async throws {
        let notifications = PermissionNotifications(.notDetermined)
        let (core, root) = try Self.daemon(notifications)
        defer { try? FileManager.default.removeItem(at: root) }
        await core.start()
        let (shim, _) = await Self.connect(core, as: .shim(package: "org.fdroid.fdroid"))
        await #expect(throws: AvoError.unauthorizedCaller) { try await core.requestNotificationPermission(client: shim) }
        await #expect(throws: AvoError.unauthorizedCaller) { try await core.notificationPermission(client: shim) }
        #expect(notifications.requestCount == 0)
    }
}
