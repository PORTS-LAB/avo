import AppKit
import AvoADB
import AvoDaemonCore
import AvoKit
import AvoShimKit
import CryptoKit
import os
import Security

/// The Runtime Daemon process: a LaunchAgent (registered by Avo.app) that
/// owns the VM, vends the XPC service and shows the menu bar item.
@MainActor
final class DaemonAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Daemon")
    private var service: DaemonService?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        do {
            try start()
        } catch {
            logger.fault("daemon failed to start: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }

    private func start() throws {
        let avoApp = Self.hostApplication()
        let paths = AvoPaths()
        try paths.createDirectories()

        let profiles = (try? DeviceProfileCatalog(directory: avoApp.appending(path: "Contents/Resources/profiles/devices")))
            ?? DeviceProfileCatalog(profiles: [DeviceProfile(id: DeviceProfile.defaultID, name: "Avo Virtual Device", properties: [:])])
        let template = avoApp.appending(path: "Contents/Library/Shim/AvoShim.app")
        let builder = FileManager.default.fileExists(atPath: template.path)
            ? ShimBuilder(template: template, hostApplication: avoApp, directory: paths.shims) : nil

        let imageKey = Self.imagePublicKey()
        let logger = self.logger
        let deps = DaemonCore.Dependencies(
            paths: paths,
            engine: CrosvmEngine(executable: avoApp.appending(path: "Contents/MacOS/crosvm")),
            adbKey: try ADBKey.loadOrCreate(at: paths.adbKey),
            profiles: profiles,
            host: HostInfo.current(),
            shortcuts: ShortcutManager(builder: builder, paths: paths),
            notifications: UserNotificationPresenter(),
            clipboard: PasteboardBridge(),
            launcher: WorkspaceLauncher(),
            softwareVersion: "avo-host \(Self.version)",
            loadImage: {
                let config = (try? VMConfig.load(from: paths.config)) ?? VMConfig()
                let root = config.imageLocation.map { URL(filePath: $0) } ?? paths.images
                let image = try AndroidImage.installed(in: root)
                if let imageKey {
                    try image.verify(publicKey: imageKey)
                } else {
                    logger.warning("no image signing key in this build; skipping image verification")
                }
                return image
            })
        let core = DaemonCore(deps)
        Task { await core.start() }

        let listener = NSXPCListener(machServiceName: AvoIdentifiers.daemonMachService)
        let service = DaemonService(core: core, policy: Self.callerPolicy(avoApp: avoApp), listener: listener)
        service.resume()
        self.service = service
        menuBar = MenuBarController(core: core, avoApp: avoApp)
        logger.notice("daemon ready (Avo.app at \(avoApp.path, privacy: .public))")
    }

    /// Avo.app/Contents/Library/Helpers/AvoDaemon.app → Avo.app
    static func hostApplication() -> URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent() // Helpers
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Avo.app
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Release builds carry the team that signed them; local builds are ad hoc.
    static func callerPolicy(avoApp: URL) -> CallerPolicy {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .teamID(team)
        }
        return .development(appBundle: avoApp)
    }

    /// Ed25519 key that signs Android image manifests (Info.plist `AvoImagePublicKey`, base64).
    static func imagePublicKey() -> Curve25519.Signing.PublicKey? {
        guard let base64 = Bundle.main.object(forInfoDictionaryKey: "AvoImagePublicKey") as? String,
              let data = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}
