import AvoKit
import Foundation
import IOSurface
import os
import Security

/// Who may talk to the daemon (spec: "App Shim berkomunikasi dengan daemon
/// lewat XPC dengan validasi code signature pemanggil").
public enum CallerPolicy: Sendable {
    /// Release builds: Avo's own processes carry this Developer ID team; App
    /// Shims are ad hoc signed and pinned by code directory hash.
    case teamID(String)
    /// Development builds (signed to run locally): Avo's processes must live
    /// inside this app bundle; shims are still pinned by hash.
    case development(appBundle: URL)

    func requirement(shimHashes: [String]) -> String? {
        guard case .teamID(let team) = self else { return nil }
        var clauses = ["(anchor apple generic and certificate leaf[subject.OU] = \"\(team)\")"]
        clauses += shimHashes.map { "cdhash H\"\($0)\"" }
        return clauses.joined(separator: " or ")
    }

    /// Checks the process behind `pid` for `role`. `shimHash` is the pinned
    /// hash for the shim's package.
    func validate(pid: pid_t, role: ClientHello.Role, shimHash: String?) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        switch role {
        case .shim:
            guard let shimHash, let hash = Self.cdhash(code) else { return false }
            return hash == shimHash
        case .controlPanel, .engine:
            switch self {
            case .teamID(let team):
                var requirement: SecRequirement?
                let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
                guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                      let requirement else { return false }
                return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
            case .development(let bundle):
                var staticCode: SecStaticCode?
                guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
                var url: CFURL?
                guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let path = (url as URL?)?.standardizedFileURL.path else {
                    return false
                }
                return path.hasPrefix(bundle.standardizedFileURL.path + "/") || path == bundle.standardizedFileURL.path
            }
        }
    }

    static func cdhash(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}

/// The daemon's NSXPCListener delegate: one `ClientConnection` per peer.
public final class DaemonService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public let core: DaemonCore
    let policy: CallerPolicy
    private let listener: NSXPCListener
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "XPC")

    public init(core: DaemonCore, policy: CallerPolicy, listener: NSXPCListener) {
        self.core = core
        self.policy = policy
        self.listener = listener
        super.init()
        listener.delegate = self
    }

    public func resume() {
        Task { await refreshRequirement() }
        listener.resume()
    }

    /// Re-pins the listener to Avo's team plus every known shim.
    public func refreshRequirement() async {
        let hashes = Array(await core.shimHashes().values)
        if let requirement = policy.requirement(shimHashes: hashes) {
            listener.setConnectionCodeSigningRequirement(requirement)
        }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let client = ClientConnection(connection: connection, service: self)
        connection.exportedInterface = AvoXPC.daemonInterface()
        connection.exportedObject = client
        connection.remoteObjectInterface = AvoXPC.clientInterface()
        let core = self.core
        let id = client.id
        connection.invalidationHandler = { Task { await core.disconnect(id) } }
        connection.resume()
        return true
    }

    func authorize(_ connection: NSXPCConnection, role: ClientHello.Role) async -> Bool {
        let hash: String?
        if case .shim(let package) = role {
            hash = await core.shimHashes()[package]
        } else {
            hash = nil
        }
        let allowed = policy.validate(pid: connection.processIdentifier, role: role, shimHash: hash)
        if allowed, case .teamID = policy, let hash {
            // Bind the rest of this connection to the shim that said hello.
            connection.setCodeSigningRequirement("cdhash H\"\(hash)\"")
        }
        if !allowed { logger.error("rejected \(String(describing: role), privacy: .public) from pid \(connection.processIdentifier)") }
        return allowed
    }
}

/// The object a single XPC peer talks to; every call is checked against the
/// role the peer declared in `hello`.
final class ClientConnection: NSObject, AvoDaemonXPC, @unchecked Sendable {
    let id = UUID()
    private weak var connection: NSXPCConnection?
    private let service: DaemonService
    private var core: DaemonCore { service.core }

    init(connection: NSXPCConnection, service: DaemonService) {
        self.connection = connection
        self.service = service
    }

    private func run(_ reply: @escaping @Sendable (NSError?) -> Void, _ body: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await body()
                reply(nil)
            } catch {
                reply(AvoXPC.nsError(error))
            }
        }
    }

    private func run(_ reply: @escaping @Sendable (Data?, NSError?) -> Void, _ body: @escaping @Sendable () async throws -> Data) {
        Task {
            do {
                reply(try await body(), nil)
            } catch {
                reply(nil, AvoXPC.nsError(error))
            }
        }
    }

    // MARK: Session

    func hello(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            let hello = try AvoXPC.decode(ClientHello.self, from: request)
            guard let connection, await service.authorize(connection, role: hello.role) else { throw AvoError.unauthorizedCaller }
            guard let proxy = connection.remoteObjectProxy as? AvoClientXPC else { throw AvoError.internalError("no client proxy") }
            return AvoXPC.encode(await core.register(id, role: hello.role, proxy: ClientProxy(proxy)))
        }
    }

    // MARK: VM

    func status(reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(AvoXPC.encode(await core.status())) }
    }

    func startVM(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.startVM(client: id) } }
    func stopVM(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.stopVM(client: id) } }
    func restartVM(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.restartVM(client: id) } }
    func takeSnapshot(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.takeSnapshot(client: id) } }
    func resetAndroid(reply: @escaping @Sendable (NSError?) -> Void) { run(reply) { [self] in try await core.resetAndroid(client: id) } }

    // MARK: Configuration

    func configuration(reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(AvoXPC.encode(await core.configurationSnapshot())) }
    }

    func updateConfiguration(_ config: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            let new = try AvoXPC.decode(VMConfig.self, from: config)
            return AvoXPC.encode(try await core.updateConfiguration(new, client: id))
        }
    }

    // MARK: Apps

    func apps(reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(AvoXPC.encode(await core.apps())) }
    }

    func icon(forPackage package: String, reply: @escaping @Sendable (Data?) -> Void) {
        Task { reply(await core.icon(for: package)) }
    }

    func install(_ request: Data, file: FileHandle, reply: @escaping @Sendable (NSError?) -> Void) {
        // Own a duplicate: the FileHandle closes its descriptor when released.
        let descriptor = OwnedDescriptor(dup(file.fileDescriptor))
        run(reply) { [self] in
            try await core.install(try AvoXPC.decode(InstallRequest.self, from: request), file: descriptor, client: id)
            await service.refreshRequirement()
        }
    }

    func uninstall(package: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.uninstall(package, client: id) }
    }

    func forceStop(package: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.forceStop(package, client: id) }
    }

    func deleteAppData(package: String, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.deleteAppData(package, client: id) }
    }

    func permissions(package: String, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in AvoXPC.encode(try await core.permissions(for: package, client: id)) }
    }

    func setPermission(package: String, permission: String, granted: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in try await core.setPermission(permission, granted: granted, for: package, client: id) }
    }

    func recreateShortcuts(package: String?, reply: @escaping @Sendable (NSError?) -> Void) {
        run(reply) { [self] in
            try await core.recreateShortcuts(for: package, client: id)
            await service.refreshRequirement()
        }
    }

    // MARK: Displays

    func openDisplay(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        run(reply) { [self] in
            let open = try AvoXPC.decode(OpenDisplayRequest.self, from: request)
            return AvoXPC.encode(OpenDisplayReply(displayID: try await core.openDisplay(open, client: id)))
        }
    }

    func resizeDisplay(_ displayID: UInt32, width: UInt32, height: UInt32, dpi: UInt32) {
        Task { [self] in await core.resizeDisplay(displayID, width: width, height: height, dpi: dpi, client: id) }
    }

    func closeDisplay(_ displayID: UInt32) {
        Task { [self] in await core.closeDisplay(displayID, client: id) }
    }

    func setDisplayVisible(_ displayID: UInt32, visible: Bool) {
        Task { [self] in await core.setDisplayVisible(displayID, visible: visible, client: id) }
    }

    func sendInput(_ record: Data) {
        Task { [self] in await core.sendInput(record, client: id) }
    }

    func shareFiles(_ displayID: UInt32, files: [FileHandle], names: [String], reply: @escaping @Sendable (NSError?) -> Void) {
        let descriptors = files.map { OwnedDescriptor(dup($0.fileDescriptor)) }
        run(reply) { [self] in
            guard descriptors.count == names.count else { throw AvoError.internalError("file and name counts differ") }
            try await core.shareFiles(Array(zip(descriptors, names)), displayID: displayID, client: id)
        }
    }

    // MARK: Engine

    func engineSetSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {
        let list = SurfaceList(surfaces)
        Task { [self] in
            guard await core.role(of: id) == .engine else { return }
            await core.engineSetSurfaces(displayID, surfaces: list)
        }
    }

    func enginePresent(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {
        Task { [self] in
            guard await core.role(of: id) == .engine else { return }
            await core.enginePresent(displayID, surfaceIndex: surfaceIndex, sequence: sequence)
        }
    }
}

/// A file descriptor received over XPC; closed when the last reference goes away.
public final class OwnedDescriptor: Sendable {
    public let value: Int32

    public init(_ value: Int32) {
        self.value = value
    }

    deinit {
        if value >= 0 { close(value) }
    }
}
