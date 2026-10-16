import Foundation
import IOSurface

// XPC between the Runtime Daemon and its clients (Control Panel, menu bar,
// App Shims and the engine). Structured payloads travel as JSON `Data` so the
// @objc surface stays small and can evolve without breaking older shims;
// input records travel in the Input channel wire format, and frames as
// IOSurface objects.

/// Exported by the daemon on `AvoIdentifiers.daemonMachService`.
@objc public protocol AvoDaemonXPC {
    /// Must be the first call. `request`: JSON `ClientHello`; reply: JSON `DaemonHello`.
    func hello(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: VM lifecycle
    /// Reply: JSON `VMStatus`.
    func status(reply: @escaping @Sendable (Data) -> Void)
    func startVM(reply: @escaping @Sendable (NSError?) -> Void)
    func stopVM(reply: @escaping @Sendable (NSError?) -> Void)
    func restartVM(reply: @escaping @Sendable (NSError?) -> Void)
    func takeSnapshot(reply: @escaping @Sendable (NSError?) -> Void)
    /// Wipes the user data disk (Sistem → Reset Android).
    func resetAndroid(reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Configuration
    /// Reply: JSON `ConfigurationSnapshot`.
    func configuration(reply: @escaping @Sendable (Data) -> Void)
    /// `config`: JSON `VMConfig`. Reply: JSON `ConfigUpdateResult`.
    func updateConfiguration(_ config: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)

    // MARK: Apps
    /// Reply: JSON `[AppRecord]`.
    func apps(reply: @escaping @Sendable (Data) -> Void)
    /// Reply: PNG data of the launcher icon, if known.
    func icon(forPackage package: String, reply: @escaping @Sendable (Data?) -> Void)
    /// `request`: JSON `InstallRequest`; `file` is the package, opened by the
    /// caller (the daemon has no access of its own to Downloads or Documents).
    /// Progress arrives as `DaemonEvent.installProgress`.
    func install(_ request: Data, file: FileHandle, reply: @escaping @Sendable (NSError?) -> Void)
    func uninstall(package: String, reply: @escaping @Sendable (NSError?) -> Void)
    func forceStop(package: String, reply: @escaping @Sendable (NSError?) -> Void)
    func deleteAppData(package: String, reply: @escaping @Sendable (NSError?) -> Void)
    /// Reply: JSON `[AppPermission]`.
    func permissions(package: String, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func setPermission(package: String, permission: String, granted: Bool, reply: @escaping @Sendable (NSError?) -> Void)
    /// Regenerates App Shims and aliases (all apps when `package` is nil).
    func recreateShortcuts(package: String?, reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Displays (App Shims)
    /// `request`: JSON `OpenDisplayRequest`. Reply: JSON `OpenDisplayReply`.
    func openDisplay(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func resizeDisplay(_ displayID: UInt32, width: UInt32, height: UInt32, dpi: UInt32)
    func closeDisplay(_ displayID: UInt32)
    func setDisplayVisible(_ displayID: UInt32, visible: Bool)
    /// One Input channel record (docs/protocol.md). Fire and forget.
    func sendInput(_ record: Data)
    /// Copies files (opened by the caller) into /sdcard/Download and shares
    /// them with the app on `displayID`. `names` are the files' names.
    func shareFiles(_ displayID: UInt32, files: [FileHandle], names: [String], reply: @escaping @Sendable (NSError?) -> Void)

    // MARK: Engine
    /// Called by the engine process: the swapchain for a display (IOSurfaces).
    func engineSetSurfaces(_ displayID: UInt32, surfaces: [IOSurface])
    /// Called by the engine process for every presented frame.
    func enginePresent(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64)
}

/// Exported by every client so the daemon can push events and frames.
@objc public protocol AvoClientXPC {
    /// JSON `DaemonEvent`.
    func handleEvent(_ event: Data)
    /// Swapchain of a display owned by this client (sent on open and resize).
    func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface])
    /// A new frame is in `surfaces[surfaceIndex]`.
    func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64)
}

public enum AvoXPC {
    public static func daemonInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: AvoDaemonXPC.self)
        let surfaces = NSSet(array: [NSArray.self, IOSurface.self]) as! Set<AnyHashable>
        interface.setClasses(surfaces, for: #selector(AvoDaemonXPC.engineSetSurfaces(_:surfaces:)),
                             argumentIndex: 1, ofReply: false)
        let handles = NSSet(array: [NSArray.self, FileHandle.self]) as! Set<AnyHashable>
        interface.setClasses(handles, for: #selector(AvoDaemonXPC.shareFiles(_:files:names:reply:)),
                             argumentIndex: 1, ofReply: false)
        let strings = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(strings, for: #selector(AvoDaemonXPC.shareFiles(_:files:names:reply:)),
                             argumentIndex: 2, ofReply: false)
        return interface
    }

    public static func clientInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: AvoClientXPC.self)
        let surfaces = NSSet(array: [NSArray.self, IOSurface.self]) as! Set<AnyHashable>
        interface.setClasses(surfaces, for: #selector(AvoClientXPC.setSurfaces(_:surfaces:)),
                             argumentIndex: 1, ofReply: false)
        return interface
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        // Encoding our own Codable models cannot fail; crash loudly if it does.
        try! encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    // MARK: Errors

    public static let errorDomain = "\(AvoIdentifiers.prefix).error"

    public static func nsError(_ error: any Error) -> NSError {
        let avoError = (error as? AvoError) ?? .internalError(error.localizedDescription)
        let payload = encode(avoError)
        return NSError(domain: errorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: avoError.localizedDescription,
            "AvoError": payload,
        ])
    }

    public static func avoError(_ error: NSError) -> AvoError {
        if error.domain == errorDomain, let payload = error.userInfo["AvoError"] as? Data,
           let decoded = try? decode(AvoError.self, from: payload) {
            return decoded
        }
        return .internalError(error.localizedDescription)
    }
}

// MARK: - Payloads

public struct ClientHello: Codable, Sendable {
    public enum Role: Codable, Equatable, Sendable {
        case controlPanel
        case shim(package: String)
        case engine
    }

    public var role: Role
    public var version: String

    public init(role: Role, version: String) {
        self.role = role
        self.version = version
    }
}

public struct DaemonHello: Codable, Sendable {
    public var daemonVersion: String
    public var status: VMStatus

    public init(daemonVersion: String, status: VMStatus) {
        self.daemonVersion = daemonVersion
        self.status = status
    }
}

public struct ConfigurationSnapshot: Codable, Sendable {
    public var config: VMConfig
    public var host: HostInfo
    public var profiles: [DeviceProfile]
    /// Settings saved but waiting for the next VM restart.
    public var pendingRestart: Bool

    public init(config: VMConfig, host: HostInfo, profiles: [DeviceProfile], pendingRestart: Bool) {
        self.config = config
        self.host = host
        self.profiles = profiles
        self.pendingRestart = pendingRestart
    }
}

public struct ConfigUpdateResult: Codable, Sendable {
    public var effect: ConfigChangeEffect
    public var issues: [ConfigIssue]

    public init(effect: ConfigChangeEffect, issues: [ConfigIssue]) {
        self.effect = effect
        self.issues = issues
    }
}

public struct InstallRequest: Codable, Sendable {
    public var id: UUID
    /// The package file (.apk, .xapk, .apkm, .apks) on the Mac.
    public var path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }
}

public struct InstallProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case inspecting, startingVM, transferring, installing, copyingOBB, creatingShortcuts, finished, failed
    }

    public var id: UUID
    public var phase: Phase
    /// 0...1 when the phase has measurable progress.
    public var fraction: Double?
    public var package: String?
    public var message: String?

    public init(id: UUID, phase: Phase, fraction: Double? = nil, package: String? = nil, message: String? = nil) {
        self.id = id
        self.phase = phase
        self.fraction = fraction
        self.package = package
        self.message = message
    }
}

public struct AppPermission: Codable, Hashable, Sendable {
    public var name: String
    public var label: String
    public var granted: Bool
    public var runtime: Bool

    public init(name: String, label: String, granted: Bool, runtime: Bool) {
        self.name = name
        self.label = label
        self.granted = granted
        self.runtime = runtime
    }
}

public struct OpenDisplayRequest: Codable, Sendable {
    public var package: String
    /// Display size in pixels and density.
    public var width: UInt32
    public var height: UInt32
    public var dpi: UInt32
    public var notificationKey: String?
    public var dataURI: String?
    public var mimeType: String?

    public init(package: String, width: UInt32, height: UInt32, dpi: UInt32,
                notificationKey: String? = nil, dataURI: String? = nil, mimeType: String? = nil) {
        self.package = package
        self.width = width
        self.height = height
        self.dpi = dpi
        self.notificationKey = notificationKey
        self.dataURI = dataURI
        self.mimeType = mimeType
    }
}

public struct OpenDisplayReply: Codable, Sendable {
    public var displayID: UInt32

    public init(displayID: UInt32) {
        self.displayID = displayID
    }
}

public enum DisplayOrientation: String, Codable, Sendable {
    case unspecified, portrait, landscape, reversePortrait, reverseLandscape
}

/// Events the daemon pushes to clients.
public enum DaemonEvent: Codable, Sendable, Equatable {
    case vmStatus(VMStatus)
    case appInstalled(AppRecord)
    case appRemoved(package: String)
    case installProgress(InstallProgress)
    case displayReady(displayID: UInt32)
    case displayClosed(displayID: UInt32)
    case displayTitle(displayID: UInt32, title: String)
    case orientationRequest(displayID: UInt32, orientation: DisplayOrientation)
    case configurationChanged(VMConfig)
}
