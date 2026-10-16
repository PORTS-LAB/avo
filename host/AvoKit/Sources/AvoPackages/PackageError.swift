import Foundation

public enum PackageError: Error, Equatable, Sendable, LocalizedError {
    case notAZipArchive
    case malformed(String)
    case unsupportedCompression(UInt16)
    case encrypted
    case checksumMismatch(String)
    case entryTooLarge(String, UInt64)
    case missingEntry(String)
    case unknownFormat
    case noBaseAPK
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notAZipArchive: "The file is not an Android package (not a ZIP archive)."
        case .malformed(let detail): "The package is damaged: \(detail)."
        case .unsupportedCompression(let method): "The package uses an unsupported compression method (\(method))."
        case .encrypted: "The package is encrypted. Encrypted APKM files need APKMirror Installer and cannot be installed by Avo."
        case .checksumMismatch(let entry): "The package is damaged (\(entry) failed its checksum)."
        case .entryTooLarge(let entry, let size): "\(entry) is unexpectedly large (\(size) bytes)."
        case .missingEntry(let entry): "The package is missing \(entry)."
        case .unknownFormat: "The file is not an APK, XAPK, APKM or APKS package."
        case .noBaseAPK: "The bundle does not contain a base APK."
        case .io(let detail): "The package could not be read: \(detail)."
        }
    }
}
