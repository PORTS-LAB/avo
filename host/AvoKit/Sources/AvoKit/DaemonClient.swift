import Foundation
import IOSurface
import os

/// Async client for the Runtime Daemon, used by the Control Panel and App Shims.
///
/// Events pushed by the daemon are delivered on `events`; frames go to the
/// optional `FrameReceiver` (App Shims only).
public final class DaemonClient: @unchecked Sendable {
    public protocol FrameReceiver: AnyObject, Sendable {
        func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface])
        func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64)
    }

    public let events: AsyncStream<DaemonEvent>
    private let continuation: AsyncStream<DaemonEvent>.Continuation
    private let connection: NSXPCConnection
    private let receiver: Receiver
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "DaemonClient")

    public init(role: ClientHello.Role, version: String, frameReceiver: (any FrameReceiver)? = nil,
                machService: String = AvoIdentifiers.daemonMachService) {
        (events, continuation) = AsyncStream.makeStream(of: DaemonEvent.self, bufferingPolicy: .bufferingNewest(256))
        receiver = Receiver(events: continuation, frames: frameReceiver)
        connection = NSXPCConnection(machServiceName: machService, options: [])
        connection.remoteObjectInterface = AvoXPC.daemonInterface()
        connection.exportedInterface = AvoXPC.clientInterface()
        connection.exportedObject = receiver
        let continuation = self.continuation
        connection.invalidationHandler = { continuation.finish() }
        connection.interruptionHandler = { [logger] in logger.notice("daemon connection interrupted") }
        connection.resume()
        self.role = role
        self.version = version
    }

    private let role: ClientHello.Role
    private let version: String

    deinit {
        connection.invalidate()
    }

    public func invalidate() {
        connection.invalidate()
    }

    // MARK: Calls

    public func hello() async throws -> DaemonHello {
        let request = AvoXPC.encode(ClientHello(role: role, version: version))
        let data: Data = try await call { proxy, done in
            proxy.hello(request) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(DaemonHello.self, from: data)
    }

    public func status() async throws -> VMStatus {
        let data: Data = try await call { proxy, done in proxy.status { done(.success($0)) } }
        return try AvoXPC.decode(VMStatus.self, from: data)
    }

    public func startVM() async throws { try await voidCall { $0.startVM(reply: $1) } }
    public func stopVM() async throws { try await voidCall { $0.stopVM(reply: $1) } }
    public func restartVM() async throws { try await voidCall { $0.restartVM(reply: $1) } }
    public func takeSnapshot() async throws { try await voidCall { $0.takeSnapshot(reply: $1) } }
    public func resetAndroid() async throws { try await voidCall { $0.resetAndroid(reply: $1) } }

    public func configuration() async throws -> ConfigurationSnapshot {
        let data: Data = try await call { proxy, done in proxy.configuration { done(.success($0)) } }
        return try AvoXPC.decode(ConfigurationSnapshot.self, from: data)
    }

    public func updateConfiguration(_ config: VMConfig) async throws -> ConfigUpdateResult {
        let payload = AvoXPC.encode(config)
        let data: Data = try await call { proxy, done in
            proxy.updateConfiguration(payload) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(ConfigUpdateResult.self, from: data)
    }

    public func apps() async throws -> [AppRecord] {
        let data: Data = try await call { proxy, done in proxy.apps { done(.success($0)) } }
        return try AvoXPC.decode([AppRecord].self, from: data)
    }

    public func icon(for package: String) async throws -> Data? {
        try await call { proxy, done in proxy.icon(forPackage: package) { done(.success($0)) } }
    }

    /// Installs the package at `request.path`. This process opens the file and
    /// hands the descriptor to the daemon, so files the user chose in
    /// Downloads or Documents work without extra permissions.
    public func install(_ request: InstallRequest) async throws {
        let payload = AvoXPC.encode(request)
        let file = try FileHandle(forReadingFrom: URL(filePath: request.path))
        defer { try? file.close() }
        try await voidCall { $0.install(payload, file: file, reply: $1) }
    }

    public func uninstall(_ package: String) async throws { try await voidCall { $0.uninstall(package: package, reply: $1) } }
    public func forceStop(_ package: String) async throws { try await voidCall { $0.forceStop(package: package, reply: $1) } }
    public func deleteAppData(_ package: String) async throws { try await voidCall { $0.deleteAppData(package: package, reply: $1) } }

    public func permissions(for package: String) async throws -> [AppPermission] {
        let data: Data = try await call { proxy, done in
            proxy.permissions(package: package) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode([AppPermission].self, from: data)
    }

    public func setPermission(_ permission: String, granted: Bool, for package: String) async throws {
        try await voidCall { $0.setPermission(package: package, permission: permission, granted: granted, reply: $1) }
    }

    public func recreateShortcuts(for package: String? = nil) async throws {
        try await voidCall { $0.recreateShortcuts(package: package, reply: $1) }
    }

    public func openDisplay(_ request: OpenDisplayRequest) async throws -> UInt32 {
        let payload = AvoXPC.encode(request)
        let data: Data = try await call { proxy, done in
            proxy.openDisplay(payload) { data, error in done(Self.result(data, error)) }
        }
        return try AvoXPC.decode(OpenDisplayReply.self, from: data).displayID
    }

    public func shareFiles(_ urls: [URL], with displayID: UInt32) async throws {
        let files = try urls.map { try FileHandle(forReadingFrom: $0) }
        defer { for file in files { try? file.close() } }
        let names = urls.map(\.lastPathComponent)
        try await voidCall { $0.shareFiles(displayID, files: files, names: names, reply: $1) }
    }

    // Fire-and-forget calls used on the input and window paths.

    public func resizeDisplay(_ displayID: UInt32, width: UInt32, height: UInt32, dpi: UInt32) {
        proxy()?.resizeDisplay(displayID, width: width, height: height, dpi: dpi)
    }

    public func closeDisplay(_ displayID: UInt32) {
        proxy()?.closeDisplay(displayID)
    }

    public func setDisplayVisible(_ displayID: UInt32, visible: Bool) {
        proxy()?.setDisplayVisible(displayID, visible: visible)
    }

    /// Sends one Input channel record (already encoded with `InputWire`).
    public func sendInput(_ record: Data) {
        proxy()?.sendInput(record)
    }

    // MARK: Plumbing

    private func proxy() -> AvoDaemonXPC? {
        connection.remoteObjectProxyWithErrorHandler { [logger] error in
            logger.error("daemon call failed: \(error.localizedDescription, privacy: .public)")
        } as? AvoDaemonXPC
    }

    private static func result(_ data: Data?, _ error: NSError?) -> Result<Data, AvoError> {
        if let error { return .failure(AvoXPC.avoError(error)) }
        guard let data else { return .failure(.internalError("empty reply from daemon")) }
        return .success(data)
    }

    private func call<T: Sendable>(_ body: (AvoDaemonXPC, @escaping @Sendable (Result<T, AvoError>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(AvoError.daemonUnreachable(error.localizedDescription)))
            }
            guard let daemon = proxy as? AvoDaemonXPC else {
                once.resume(with: .failure(AvoError.internalError("unexpected proxy type")))
                return
            }
            body(daemon) { result in once.resume(with: result.mapError { $0 as any Error }) }
        }
    }

    private func voidCall(_ body: (AvoDaemonXPC, @escaping @Sendable (NSError?) -> Void) -> Void) async throws {
        let _: Bool = try await call { proxy, done in
            body(proxy) { error in done(error.map { .failure(AvoXPC.avoError($0)) } ?? .success(true)) }
        }
    }

    /// Exported object receiving daemon callbacks.
    private final class Receiver: NSObject, AvoClientXPC, Sendable {
        let events: AsyncStream<DaemonEvent>.Continuation
        let frames: (any FrameReceiver)?

        init(events: AsyncStream<DaemonEvent>.Continuation, frames: (any FrameReceiver)?) {
            self.events = events
            self.frames = frames
        }

        func handleEvent(_ event: Data) {
            if let decoded = try? AvoXPC.decode(DaemonEvent.self, from: event) {
                events.yield(decoded)
            }
        }

        func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {
            frames?.setSurfaces(displayID, surfaces: surfaces)
        }

        func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {
            frames?.present(displayID, surfaceIndex: surfaceIndex, sequence: sequence)
        }
    }
}

/// Resumes a continuation at most once (XPC may call both the reply and the
/// error handler when a connection dies mid-call).
final class ResumeOnce<T: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        state = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(with result: Result<T, any Error>) {
        let continuation = state.withLock { value -> CheckedContinuation<T, any Error>? in
            defer { value = nil }
            return value
        }
        continuation?.resume(with: result)
    }
}
