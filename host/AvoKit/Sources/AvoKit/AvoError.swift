import Foundation

/// Errors that cross process boundaries (XPC) and reach the UI.
public enum AvoError: Error, Codable, Equatable, Sendable, LocalizedError {
    case vmNotRunning
    case vmStartFailed(String)
    case engineMissing
    case imageMissing
    case guestUnavailable
    case guestIncompatible(String)
    case installFailed(String)
    case unsupportedPackage(String)
    case packageNotFound(String)
    case displayUnavailable(String)
    case invalidConfiguration([String])
    case unauthorizedCaller
    case daemonUnreachable(String)
    case socketPathTooLong(String)
    case timedOut(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .vmNotRunning: "Android is not running."
        case .vmStartFailed(let detail): "Android could not start: \(detail)"
        case .engineMissing: "The VM engine is not installed in this build of Avo."
        case .imageMissing: "The Android image has not been downloaded yet."
        case .guestUnavailable: "Android did not respond."
        case .guestIncompatible(let detail): detail
        case .installFailed(let detail): "Installation failed: \(detail)"
        case .unsupportedPackage(let detail): "This file cannot be installed: \(detail)"
        case .packageNotFound(let package): "\(package) is not installed."
        case .displayUnavailable(let detail): "The app window could not be opened: \(detail)"
        case .invalidConfiguration(let issues): issues.joined(separator: "\n")
        case .unauthorizedCaller: "The caller is not allowed to talk to the Avo daemon."
        case .daemonUnreachable(let detail): "Avo's background service is not reachable (\(detail))."
        case .socketPathTooLong(let path): "Socket path is too long: \(path)"
        case .timedOut(let operation): "\(operation) timed out."
        case .internalError(let detail): detail
        }
    }
}
