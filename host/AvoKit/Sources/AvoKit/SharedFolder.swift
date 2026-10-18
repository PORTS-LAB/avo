import Foundation

// Settings › Storage › Shared Folder: a folder on the Mac that Android sees
// as /sdcard/Avo Shared, both ways. The engine serves it to Android over
// virtio-fs (engine/hvf/vmm/src/virtio/fs.rs); the daemon mounts it in
// Android's media storage and tells Android's media index about the Mac's
// changes (SharedFolderBridge). It is chosen here and takes effect when
// Android next starts.

public enum SharedFolder {
    /// The folder's name in Android's storage.
    public static let androidName = "Avo Shared"
    /// Where apps and file pickers find it.
    public static let androidPath = "/sdcard/Avo Shared"
}

/// Why the chosen folder cannot be shared.
public enum SharedFolderProblem: Codable, Equatable, Sendable {
    /// Its volume isn't connected.
    case volumeMissing(volume: String, path: String)
    case folderMissing(path: String)
    case notAFolder(path: String)
    /// macOS does not let Avo use it (Files & Folders, Removable Volumes).
    case notPermitted(path: String)
    /// Avo's own folder or Android's data, which must not be shared.
    case avoData(path: String)

    public var message: String {
        switch self {
        case let .volumeMissing(volume, _):
            String(localized: "The shared folder is on “\(volume)”, which isn’t connected. Android starts without it.", bundle: .avoKit)
        case let .folderMissing(path):
            String(localized: "The shared folder is missing: \(path). Android starts without it.", bundle: .avoKit)
        case let .notAFolder(path):
            String(localized: "\(path) is not a folder.", bundle: .avoKit)
        case let .notPermitted(path):
            String(localized: "macOS doesn’t let Avo use \(path). Allow Avo in System Settings › Privacy & Security › Files & Folders.", bundle: .avoKit)
        case let .avoData(path):
            String(localized: "\(path) holds Avo’s own files or Android’s data. Choose another folder to share.", bundle: .avoKit)
        }
    }
}

/// Whether Android uses the folder now.
public enum SharedFolderMount: String, Codable, Sendable {
    /// Android waits for its storage (a screen lock not entered yet).
    case waiting
    /// At /sdcard/Avo Shared.
    case mounted
    /// This start has no shared folder: it was off or missing when Android started.
    case unavailable
    /// Android could not mount it (see the daemon's log).
    case failed
}

/// The shared folder as Settings › Storage shows it.
public struct SharedFolderStatus: Codable, Equatable, Sendable {
    /// The chosen folder (nil: none chosen yet).
    public var path: String?
    /// Sharing is on in the settings.
    public var enabled: Bool
    public var volume: VolumeSummary?
    public var problem: SharedFolderProblem?
    /// What the running Android does with it (nil: Android is not running).
    public var mount: SharedFolderMount?

    public init(path: String?, enabled: Bool, volume: VolumeSummary? = nil, problem: SharedFolderProblem? = nil,
                mount: SharedFolderMount? = nil) {
        self.path = path
        self.enabled = enabled
        self.volume = volume
        self.problem = problem
        self.mount = mount
    }

    /// Android can read the folder but not change it.
    public var readOnly: Bool { volume?.isReadOnly ?? false }
}
