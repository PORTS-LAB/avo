import Foundation

/// "Google apps" in Settings › Google Apps (spec: Strategi GMS, "Bring your
/// own GApps"): a MindTheGapps package the user supplies, from a file or a
/// GitHub release of the package line that matches Android
/// (`GoogleAppsLine`), installed as privileged system apps. Avo never ships
/// or mirrors Google's files.
public enum GoogleApps {
    /// AOSP test-keys builds are uncertified: their GSF Android ID must be
    /// registered here before Google lets the device sign in.
    public static let registrationURL = URL(string: "https://www.google.com/android/uncertified")!
    public static let playStore = "com.android.vending"
    public static let playServices = "com.google.android.gms"
    public static let servicesFramework = "com.google.android.gsf"
    public static let googleApp = "com.google.android.googlequicksearchbox"
    /// What sign-in rests on. Google Play updates all but the framework, and
    /// an update outlives its system app as an ordinary app that keeps its
    /// data but can no longer sign in, so Remove takes these out also when
    /// their system files are gone already.
    public static let corePackages: Set<String> = [playServices, playStore, servicesFramework, googleApp]
}

extension AvoPaths {
    /// `~/Library/Caches/Avo/gapps`: packages the Control Panel copied from a
    /// file the user chose (the daemon never reads Downloads or Documents
    /// itself), and releases the daemon downloaded (`downloads/`).
    public var googleAppsCache: URL { home.appending(path: "Library/Caches/Avo/gapps", directoryHint: .isDirectory) }
    /// `~/Library/Caches/Avo/gapps-releases`: the last list of each package
    /// line's GitHub releases (`GoogleAppsCatalog`), shown while GitHub can't
    /// be asked. Beside `googleAppsCache`, whose leftovers the daemon prunes.
    public var googleAppsReleases: URL { home.appending(path: "Library/Caches/Avo/gapps-releases", directoryHint: .isDirectory) }
}

public struct GoogleAppsInstallRequest: Codable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        /// A .zip or an unzipped package folder inside `AvoPaths.googleAppsCache`.
        case local(path: String)
        /// A GitHub release page (`…/releases/latest`, `…/releases/tag/<tag>`),
        /// repository or asset link.
        case github(url: String)
    }

    public var id: UUID
    public var source: Source

    public init(id: UUID = UUID(), source: Source) {
        self.id = id
        self.source = source
    }
}

public struct GoogleAppsProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Reading the package, or looking up the GitHub release.
        case preparing
        case downloading
        /// Comparing the download with the release's SHA-256.
        case verifying
        case startingVM
        case disablingVerity
        case restarting
        /// Making /product and /system_ext writable (`remount`).
        case remounting
        case transferring
        /// Copying into the system partitions.
        case installing
        /// After the last restart: does Android list Google Play?
        case checking
        /// Something failed after files went in: removing them again
        /// (GoogleAppsCommit's manifest) and restarting Android.
        case restoring
        /// Remove: taking the files out (fraction 0), then the updates
        /// Google Play left behind (fraction 1).
        case removing
        case finished
        case failed
        /// The user stopped the install before Android was changed.
        case cancelled
    }

    public var id: UUID
    public var phase: Phase
    /// 0...1 for downloading and transferring.
    public var fraction: Double?
    public var message: String?
    /// Google apps are being removed (Settings › Google Apps › Remove), not installed.
    public var removal: Bool

    public init(id: UUID, phase: Phase, fraction: Double? = nil, message: String? = nil, removal: Bool = false) {
        self.id = id
        self.phase = phase
        self.fraction = fraction
        self.message = message
        self.removal = removal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        phase = try container.decode(Phase.self, forKey: .phase)
        fraction = try container.decodeIfPresent(Double.self, forKey: .fraction)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        removal = try container.decodeIfPresent(Bool.self, forKey: .removal) ?? false
    }

    /// How far the whole install is, 0...1, for one bar across its steps:
    /// each step has its share (the restarts the most, as they take the
    /// longest), and downloading and copying move through theirs. Nil for a
    /// step that does not say (a restart, starting Android, restoring),
    /// which can come at more than one point: the bar stays where it is.
    public var overall: Double? {
        func within(_ start: Double, _ end: Double) -> Double { start + (end - start) * min(max(fraction ?? 0, 0), 1) }
        switch phase {
        case .preparing: return 0
        case .downloading: return within(0, 0.30)
        case .verifying: return 0.30
        case .disablingVerity: return 0.34
        case .remounting: return 0.56
        case .transferring: return within(0.58, 0.78)
        case .installing: return 0.80
        case .checking: return 0.95
        case .removing: return within(0.10, 0.90)
        case .finished: return 1
        case .startingVM, .restarting, .restoring, .failed, .cancelled: return nil
        }
    }

    /// Up to here nothing in Android has changed, so the install can stop.
    public var isCancellable: Bool { [.preparing, .downloading, .verifying].contains(phase) }
    public var isDone: Bool { [.finished, .failed, .cancelled].contains(phase) }
    /// Avo is changing Android (or restarting it for that): stopping,
    /// restarting or resetting Android has to wait.
    public var changesAndroid: Bool { !isDone && !isCancellable }
}

public struct GoogleAppsStatus: Codable, Equatable, Sendable {
    /// False when this Android image cannot take Google apps.
    public var supported: Bool
    /// Nil while Android is not running (unknown).
    public var installed: Bool?
    public var playStoreVersion: String?
    public var playServicesVersion: String?
    /// False when Android lists Google Play services but not as a system
    /// app: the system files are gone and only Google Play's update of it
    /// is left, which can't sign in (Remove, then install again).
    public var systemApps: Bool?
    /// Whether verified boot (dm-verity) is off for the system partitions.
    public var verityDisabled: Bool?
    /// The GSF Android ID (decimal) to register at `GoogleApps.registrationURL`;
    /// nil until Google Play services has checked in.
    public var androidID: String?
    /// The install running now, if any.
    public var progress: GoogleAppsProgress?

    public init(supported: Bool, installed: Bool? = nil, playStoreVersion: String? = nil, playServicesVersion: String? = nil,
                systemApps: Bool? = nil, verityDisabled: Bool? = nil, androidID: String? = nil, progress: GoogleAppsProgress? = nil) {
        self.supported = supported
        self.installed = installed
        self.playStoreVersion = playStoreVersion
        self.playServicesVersion = playServicesVersion
        self.systemApps = systemApps
        self.verityDisabled = verityDisabled
        self.androidID = androidID
        self.progress = progress
    }
}
