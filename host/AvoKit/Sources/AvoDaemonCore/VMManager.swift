import AvoADB
import AvoIO
import AvoKit
import AvoProtocol
import Foundation
import os

/// Owns the VM lifecycle and the three guest channels (Control, Input, ADB).
///
/// Boot: verify image → write BootConfig → start engine → connect Control
/// (retrying while Android boots) → Hello → connect Input → running. The VM
/// stays up in the background so opening apps feels instant (spec goal 4).
public actor VMManager {
    public struct Settings: Sendable {
        public var config: VMConfig
        public var profile: DeviceProfile?

        public init(config: VMConfig, profile: DeviceProfile?) {
            self.config = config
            self.profile = profile
        }
    }

    private let engine: any VMEngine
    private let paths: AvoPaths
    private let softwareVersion: String
    private let adbKey: ADBKey
    private let loadImage: @Sendable () throws -> AndroidImage
    private let bootTimeout: Duration
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "VM")

    public private(set) var status = VMStatus.stopped
    private var control: ControlSession?
    private var input: InputChannel?
    private var adb: ADBConnection?
    private var booting: Task<Void, any Error>?
    private var pumps: [Task<Void, Never>] = []

    /// Guest events from every Control session, across reboots.
    public nonisolated let guestEvents: AsyncStream<ControlSession.Payload>
    private let guestSink: AsyncStream<ControlSession.Payload>.Continuation
    public nonisolated let statusUpdates: AsyncStream<VMStatus>
    private let statusSink: AsyncStream<VMStatus>.Continuation

    public init(engine: any VMEngine, paths: AvoPaths, softwareVersion: String, adbKey: ADBKey,
                bootTimeout: Duration = .seconds(180),
                loadImage: @escaping @Sendable () throws -> AndroidImage) {
        self.engine = engine
        self.paths = paths
        self.softwareVersion = softwareVersion
        self.adbKey = adbKey
        self.bootTimeout = bootTimeout
        self.loadImage = loadImage
        (guestEvents, guestSink) = AsyncStream.makeStream(of: ControlSession.Payload.self, bufferingPolicy: .bufferingNewest(4096))
        (statusUpdates, statusSink) = AsyncStream.makeStream(of: VMStatus.self, bufferingPolicy: .bufferingNewest(16))
        let exits = engine.exits
        Task { [weak self] in
            for await error in exits { await self?.engineExited(error) }
        }
    }

    // MARK: Lifecycle

    /// Starts the VM if needed and waits until the Bridge Agent answers.
    public func ensureRunning(_ settings: @autoclosure @Sendable () -> Settings) async throws {
        if status.state == .running, let control, await control.isOpen { return }
        if let booting { return try await booting.value }
        let settings = settings()
        let task = Task { try await self.boot(settings) }
        booting = task
        defer { booting = nil }
        do {
            try await task.value
        } catch {
            await teardown()
            update(VMStatus(state: error as? AvoError == .imageMissing ? .notInstalled : .failed,
                            detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            throw error
        }
    }

    private func boot(_ settings: Settings) async throws {
        update(VMStatus(state: .starting, detail: "Starting Android"))
        let image = try loadImage()
        try paths.createDirectories()
        try ensureDataDisk(gib: settings.config.dataDiskGiB)

        let bootConfig = BootConfig(adbKeys: [try adbKey.androidPublicKey(comment: "avo-daemon")],
                                    profile: settings.profile, config: settings.config)
        let configDisk = paths.vm.appending(path: "avo_config.img")
        try bootConfig.write(to: configDisk)
        try await engine.start(EngineLaunch(config: settings.config, paths: paths, image: image, bootConfigDisk: configDisk))

        update(VMStatus(state: .starting, detail: "Waiting for Android to boot"))
        let session = try await connectControl()
        let hello = try await session.start()
        control = session
        pumps.append(Task { [weak self] in
            for await event in session.events { await self?.forward(event) }
            await self?.controlClosed(session)
        })

        let inputStream = try await engine.connect(port: AvoProtocol.Port.input)
        let channel = InputChannel(stream: inputStream)
        try await channel.start()
        input = channel

        update(VMStatus(state: .running, androidVersion: Self.androidVersion(sdk: Int(hello.androidSdk)),
                        protocolVersion: await session.negotiatedVersion, bootedAt: Date()))
        logger.notice("Android ready: \(hello.softwareVersion, privacy: .public)")
    }

    /// Retries until the Bridge Agent listens (it starts late in boot).
    private func connectControl() async throws -> ControlSession {
        let deadline = ContinuousClock.now + bootTimeout
        var lastError: (any Error)?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let stream = try await engine.connect(port: AvoProtocol.Port.control)
                return ControlSession(stream: stream, softwareVersion: softwareVersion)
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw AvoError.timedOut("Android boot (\(lastError.map { "\($0)" } ?? "no answer"))")
    }

    public func stop() async {
        guard status.state != .stopped else { return }
        update(VMStatus(state: .stopping))
        booting?.cancel()
        await teardown()
        await engine.stop()
        update(.stopped)
    }

    public func restart(_ settings: @autoclosure @Sendable () -> Settings) async throws {
        await stop()
        try await ensureRunning(settings())
    }

    /// Writes a quick-boot snapshot (spec: "Quick boot dari snapshot").
    public func takeSnapshot() async throws {
        guard status.state == .running else { throw AvoError.vmNotRunning }
        try paths.createDirectories()
        try await engine.snapshot(to: paths.snapshots.appending(path: "quickboot.snap"))
    }

    private func teardown() async {
        for pump in pumps { pump.cancel() }
        pumps.removeAll()
        await control?.close()
        await input?.close()
        await adb?.close()
        control = nil
        input = nil
        adb = nil
    }

    private func engineExited(_ error: (any Error)?) async {
        guard status.state != .stopped else { return }
        await teardown()
        if let error {
            update(VMStatus(state: .failed, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
        } else {
            update(.stopped)
        }
    }

    private func controlClosed(_ session: ControlSession) async {
        guard control === session, status.state == .running else { return }
        logger.error("Control channel closed while running")
        update(VMStatus(state: .failed, detail: "Android stopped responding"))
    }

    // MARK: Channels

    public func controlSession() throws -> ControlSession {
        guard let control, status.state == .running else { throw AvoError.vmNotRunning }
        return control
    }

    public func inputChannel() throws -> InputChannel {
        guard let input, status.state == .running else { throw AvoError.vmNotRunning }
        return input
    }

    /// The ADB channel, connected on first use.
    public func adbConnection() async throws -> ADBConnection {
        if let adb { return adb }
        guard status.state == .running else { throw AvoError.vmNotRunning }
        let stream = try await engine.connect(port: AvoProtocol.Port.adb)
        let connection = ADBConnection(transport: stream, key: adbKey, keyComment: "avo-daemon")
        _ = try await connection.connect(timeout: .seconds(20))
        adb = connection
        return connection
    }

    // MARK: Helpers

    private func forward(_ event: ControlSession.Payload) {
        guestSink.yield(event)
    }

    private func update(_ new: VMStatus) {
        var new = new
        if new.state == .running || new.state == .starting { new.openDisplays = status.openDisplays }
        status = new
        statusSink.yield(new)
    }

    public func setOpenDisplays(_ count: Int) {
        status.openDisplays = count
        statusSink.yield(status)
    }

    /// Creates or grows the sparse user data disk (never shrinks it).
    func ensureDataDisk(gib: Int) throws {
        let url = paths.dataDisk
        let size = UInt64(gib) << 30
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if try handle.seekToEnd() < size { try handle.truncate(atOffset: size) }
    }

    static func androidVersion(sdk: Int) -> String {
        let names = [34: "Android 14", 35: "Android 15", 36: "Android 16", 37: "Android 17"]
        return names[sdk].map { "\($0) (API \(sdk))" } ?? "API \(sdk)"
    }
}
