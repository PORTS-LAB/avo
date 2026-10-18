import Foundation

/// Whether macOS shows Avo's notifications in Notification Center (System
/// Settings › Notifications › Avo). The daemon (AvoDaemon.app, named "Avo")
/// posts them, so it is the process macOS asks and decides for.
public struct MacNotificationPermission: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// macOS has no answer yet: asking shows its alert, which offers Allow.
        case notDetermined
        /// Notifications appear in Notification Center (provisional delivery too).
        case allowed
        /// The user chose Don't Allow or turned Avo off: only System Settings
        /// changes that, macOS does not ask again.
        case denied
        /// macOS refuses to ask for this copy of Avo (`temporaryFolder`, `refusal`).
        case unavailable
    }

    public var state: State
    /// macOS shows its alert and waits for the user's answer.
    public var asking: Bool
    /// Unavailable because Avo runs from a temporary folder (`TemporaryFolder`):
    /// the Avo.app macOS will not show notifications for.
    public var temporaryFolder: String?
    /// Unavailable for another reason: what macOS said.
    public var refusal: String?

    public init(state: State, asking: Bool = false, temporaryFolder: String? = nil, refusal: String? = nil) {
        self.state = state
        self.asking = asking
        self.temporaryFolder = temporaryFolder
        self.refusal = refusal
    }

    public static let allowed = MacNotificationPermission(state: .allowed)

    public var isAllowed: Bool { state == .allowed }
}

/// Folders macOS treats as temporary. Launch Services marks apps there
/// (bundle flag `in-temp-dir`) and leaves them out when it looks an app up by
/// bundle identifier, which is how Notification Center checks who posts:
/// while every copy it knows is in one, the app gets "Notifications are not
/// allowed for this application" without being asked or listed in System
/// Settings, however it was launched or signed (one copy elsewhere, such as
/// /Applications, is enough). That covers a build run from /tmp and an app
/// macOS runs from a randomized copy because it was opened from Downloads
/// without being moved (App Translocation).
public enum TemporaryFolder {
    /// Whether `url` is in one (/tmp and /var are spelled with or without /private).
    public static func contains(_ url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        let roots = ["/tmp", "/var/tmp", "/var/folders", "/private/tmp", "/private/var/tmp", "/private/var/folders",
                     temporaryDirectory.standardizedFileURL.path, temporaryDirectory.resolvingSymlinksInPath().path]
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
        return paths.contains { path in
            path.contains("/AppTranslocation/") || roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
}
