import Foundation

/// Everything the Control Panel can change about the VM (spec §6).
public struct VMConfig: Codable, Equatable, Sendable {
    public enum Renderer: String, Codable, CaseIterable, Sendable {
        case vulkan
        case gles
    }

    public enum Orientation: String, Codable, CaseIterable, Sendable {
        case portrait
        case landscape
    }

    /// Google services strategy chosen at first setup (spec: Strategi GMS).
    public enum GMSMode: String, Codable, CaseIterable, Sendable {
        /// Pure AOSP with F-Droid or Aurora Store.
        case none
        /// microG with signature spoofing restricted to microG.
        case microG
        /// User-supplied GApps package installed by the wizard.
        case bringYourOwn
    }

    public struct WindowSize: Codable, Equatable, Sendable {
        /// Content size in points.
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var rotated: WindowSize { WindowSize(width: height, height: width) }
    }

    public static let memoryRangeMiB = 2048...16384
    public static let fpsChoices = [30, 60, 90, 120]
    public static let dpiRange = 120...640
    /// RAM recommended for the "Game berat" preset.
    public static let heavyGameMemoryMiB = 8192

    // Performa
    public var memoryMiB: Int
    public var cpuCount: Int
    public var balloonWhenIdle: Bool

    // Storage
    public var dataDiskGiB: Int
    /// Custom directory for the Android image and data disk; nil uses AvoPaths.
    public var imageLocation: String?

    // Grafis
    public var renderer: Renderer
    public var fpsLimit: Int
    /// Density for new displays; nil derives it from the window's backing scale
    /// (160 dpi per point, so 320 on Retina screens).
    public var defaultDPI: Int?

    // Display
    public var defaultWindowSize: WindowSize
    public var defaultOrientation: Orientation
    /// Render at the screen's backing scale (sharp) instead of 1x (faster).
    public var retinaScaling: Bool

    // Sistem
    public var rooted: Bool
    public var deviceProfileID: String
    public var gms: GMSMode

    // Shortcuts (spec §4)
    public var createDesktopAlias: Bool
    public var addToDock: Bool

    public init(memoryMiB: Int = 4096, cpuCount: Int = 4, balloonWhenIdle: Bool = true,
                dataDiskGiB: Int = 32, imageLocation: String? = nil,
                renderer: Renderer = .vulkan, fpsLimit: Int = 60, defaultDPI: Int? = nil,
                defaultWindowSize: WindowSize = WindowSize(width: 412, height: 892),
                defaultOrientation: Orientation = .portrait, retinaScaling: Bool = true,
                rooted: Bool = false, deviceProfileID: String = DeviceProfile.defaultID,
                gms: GMSMode = .none, createDesktopAlias: Bool = true, addToDock: Bool = false) {
        self.memoryMiB = memoryMiB
        self.cpuCount = cpuCount
        self.balloonWhenIdle = balloonWhenIdle
        self.dataDiskGiB = dataDiskGiB
        self.imageLocation = imageLocation
        self.renderer = renderer
        self.fpsLimit = fpsLimit
        self.defaultDPI = defaultDPI
        self.defaultWindowSize = defaultWindowSize
        self.defaultOrientation = defaultOrientation
        self.retinaScaling = retinaScaling
        self.rooted = rooted
        self.deviceProfileID = deviceProfileID
        self.gms = gms
        self.createDesktopAlias = createDesktopAlias
        self.addToDock = addToDock
    }

    /// Defaults sized for the Mac the VM runs on: half the RAM (2–8 GB) and
    /// the performance cores, leaving the efficiency cores to macOS.
    public static func recommended(for host: HostInfo) -> VMConfig {
        var config = VMConfig()
        let halfMiB = Int(host.physicalMemoryBytes / 1_048_576 / 2)
        config.memoryMiB = min(max(roundDown(halfMiB, to: 512), memoryRangeMiB.lowerBound), 8192)
        config.cpuCount = max(2, min(host.performanceCores, 8))
        return config
    }

    /// Preset "Game berat": Vulkan, 120 FPS cap and at least 8 GB when the Mac allows it.
    public mutating func applyHeavyGamePreset(host: HostInfo) {
        renderer = .vulkan
        fpsLimit = 120
        if host.maxGuestMemoryMiB >= Self.heavyGameMemoryMiB {
            memoryMiB = max(memoryMiB, Self.heavyGameMemoryMiB)
        }
    }

    private static func roundDown(_ value: Int, to step: Int) -> Int { value / step * step }
}

// MARK: - Validation

public struct ConfigIssue: Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable { case error, warning }

    public var field: String
    public var severity: Severity
    public var message: String

    public init(field: String, severity: Severity, message: String) {
        self.field = field
        self.severity = severity
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

extension VMConfig {
    /// Checks the configuration against the spec's limits and the host.
    /// `previous` is the configuration currently in effect, used for rules
    /// such as "the data disk can grow but never shrink".
    public func validate(previous: VMConfig?, host: HostInfo) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        func error(_ field: String, _ message: String) { issues.append(.init(field: field, severity: .error, message: message)) }
        func warning(_ field: String, _ message: String) { issues.append(.init(field: field, severity: .warning, message: message)) }

        if !Self.memoryRangeMiB.contains(memoryMiB) {
            error("memoryMiB", "RAM must be between 2 and 16 GB.")
        } else if memoryMiB % 256 != 0 {
            error("memoryMiB", "RAM must be a multiple of 256 MB.")
        } else if memoryMiB > host.maxGuestMemoryMiB {
            error("memoryMiB", "This Mac can give Android at most \(host.maxGuestMemoryMiB / 1024) GB.")
        }

        if cpuCount < 1 || cpuCount > host.totalCores {
            error("cpuCount", "CPU cores must be between 1 and \(host.totalCores).")
        } else if cpuCount > host.performanceCores {
            warning("cpuCount", "More cores than this Mac's \(host.performanceCores) performance cores can slow macOS down.")
        }

        if dataDiskGiB < 8 {
            error("dataDiskGiB", "The data disk must be at least 8 GB.")
        }
        if let previous, dataDiskGiB < previous.dataDiskGiB {
            error("dataDiskGiB", "The data disk can be enlarged but not shrunk (currently \(previous.dataDiskGiB) GB).")
        }

        if !Self.fpsChoices.contains(fpsLimit) {
            error("fpsLimit", "FPS limit must be one of \(Self.fpsChoices.map(String.init).joined(separator: ", ")).")
        }
        if let dpi = defaultDPI, !Self.dpiRange.contains(dpi) {
            error("defaultDPI", "DPI must be between \(Self.dpiRange.lowerBound) and \(Self.dpiRange.upperBound).")
        }
        if defaultWindowSize.width < 240 || defaultWindowSize.height < 240 {
            error("defaultWindowSize", "Windows must be at least 240 × 240 points.")
        }
        if fpsLimit >= 90 && renderer == .vulkan && memoryMiB < Self.heavyGameMemoryMiB {
            warning("memoryMiB", "Heavy games run best with at least 8 GB of RAM.")
        }
        if deviceProfileID.isEmpty {
            error("deviceProfileID", "Choose a device profile.")
        }
        return issues
    }
}

// MARK: - Restart rules (spec §6 table)

/// When a configuration change takes effect.
public enum ConfigChangeEffect: String, Codable, Comparable, Sendable {
    /// Applied right away to the running VM and open windows.
    case immediate
    /// Applies to windows opened after the change.
    case newWindows
    /// Needs the VM to restart.
    case restartRequired

    private var rank: Int {
        switch self {
        case .immediate: 0
        case .newWindows: 1
        case .restartRequired: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

extension VMConfig {
    /// Fields that changed between `old` and `self`, each with its effect.
    public func changes(from old: VMConfig) -> [(field: String, effect: ConfigChangeEffect)] {
        var result: [(String, ConfigChangeEffect)] = []
        func check<T: Equatable>(_ keyPath: KeyPath<VMConfig, T>, _ name: String, _ effect: ConfigChangeEffect) {
            if self[keyPath: keyPath] != old[keyPath: keyPath] { result.append((name, effect)) }
        }
        // Performa: all need a restart.
        check(\.memoryMiB, "memoryMiB", .restartRequired)
        check(\.cpuCount, "cpuCount", .restartRequired)
        check(\.balloonWhenIdle, "balloonWhenIdle", .restartRequired)
        // Storage: resizing or moving the disk needs a restart.
        check(\.dataDiskGiB, "dataDiskGiB", .restartRequired)
        check(\.imageLocation, "imageLocation", .restartRequired)
        // Grafis ("sebagian"): the renderer needs a restart, the FPS cap and DPI do not.
        check(\.renderer, "renderer", .restartRequired)
        check(\.fpsLimit, "fpsLimit", .immediate)
        check(\.defaultDPI, "defaultDPI", .newWindows)
        // Display: never needs a restart.
        check(\.defaultWindowSize, "defaultWindowSize", .newWindows)
        check(\.defaultOrientation, "defaultOrientation", .newWindows)
        check(\.retinaScaling, "retinaScaling", .newWindows)
        // Sistem: root, device profile and GMS are applied at boot.
        check(\.rooted, "rooted", .restartRequired)
        check(\.deviceProfileID, "deviceProfileID", .restartRequired)
        check(\.gms, "gms", .restartRequired)
        // Shortcuts.
        check(\.createDesktopAlias, "createDesktopAlias", .immediate)
        check(\.addToDock, "addToDock", .immediate)
        return result
    }

    public func effect(of old: VMConfig) -> ConfigChangeEffect {
        changes(from: old).map(\.effect).max() ?? .immediate
    }
}

// MARK: - Persistence

extension VMConfig {
    public static func load(from url: URL) throws -> VMConfig {
        try JSONDecoder().decode(VMConfig.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
