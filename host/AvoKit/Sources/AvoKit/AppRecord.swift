import Foundation

/// One installed Android app as the daemon tracks it.
///
/// The guest is the source of truth (AppInstalled / AppRemoved events and
/// ListApps); the registry adds host-side state such as the App Shim.
public struct AppRecord: Codable, Identifiable, Hashable, Sendable {
    public var package: String
    public var label: String
    public var versionName: String
    public var versionCode: Int64
    public var sizeBytes: Int64?
    public var installedAt: Date?
    public var updatedAt: Date?
    public var systemApp: Bool
    public var launchable: Bool
    public var installer: String?
    /// SHA-256 of the icon PNG, used to skip regenerating unchanged shim icons.
    public var iconDigest: String?
    /// Host-side shortcuts created for this app.
    public var shortcuts: Shortcuts

    public struct Shortcuts: Codable, Hashable, Sendable {
        public var shimPath: String?
        /// Code directory hash of the ad-hoc signed shim, pinned for XPC caller checks.
        public var shimCDHash: String?
        public var desktopAliasPath: String?
        public var inDock: Bool

        public init(shimPath: String? = nil, shimCDHash: String? = nil, desktopAliasPath: String? = nil, inDock: Bool = false) {
            self.shimPath = shimPath
            self.shimCDHash = shimCDHash
            self.desktopAliasPath = desktopAliasPath
            self.inDock = inDock
        }
    }

    public var id: String { package }

    public init(package: String, label: String, versionName: String = "", versionCode: Int64 = 0,
                sizeBytes: Int64? = nil, installedAt: Date? = nil, updatedAt: Date? = nil,
                systemApp: Bool = false, launchable: Bool = true, installer: String? = nil,
                iconDigest: String? = nil, shortcuts: Shortcuts = Shortcuts()) {
        self.package = package
        self.label = label
        self.versionName = versionName
        self.versionCode = versionCode
        self.sizeBytes = sizeBytes
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.systemApp = systemApp
        self.launchable = launchable
        self.installer = installer
        self.iconDigest = iconDigest
        self.shortcuts = shortcuts
    }

    /// Display name with a fallback for apps without a label.
    public var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? package : trimmed
    }
}

/// VM lifecycle as shown in the menu bar and Control Panel.
public enum VMState: String, Codable, Sendable {
    case notInstalled
    case stopped
    case starting
    case running
    case suspending
    case suspended
    case stopping
    case failed
}

public struct VMStatus: Codable, Equatable, Sendable {
    public var state: VMState
    public var detail: String?
    public var androidVersion: String?
    public var protocolVersion: UInt32?
    public var bootedAt: Date?
    public var openDisplays: Int

    public init(state: VMState, detail: String? = nil, androidVersion: String? = nil,
                protocolVersion: UInt32? = nil, bootedAt: Date? = nil, openDisplays: Int = 0) {
        self.state = state
        self.detail = detail
        self.androidVersion = androidVersion
        self.protocolVersion = protocolVersion
        self.bootedAt = bootedAt
        self.openDisplays = openDisplays
    }

    public static let stopped = VMStatus(state: .stopped)
}
