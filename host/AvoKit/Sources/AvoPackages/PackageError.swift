import AvoKit
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
        case .notAZipArchive:
            String(localized: "The file is not an Android package (not a ZIP archive).", bundle: .avoKit)
        case .malformed(let detail):
            String(localized: "The package is damaged: \(detail).", bundle: .avoKit)
        case .unsupportedCompression(let method):
            String(localized: "The package uses an unsupported compression method (\(Int(method))).", bundle: .avoKit)
        case .encrypted:
            String(localized: "The package is encrypted. Encrypted APKM files need APKMirror Installer and cannot be installed by Avo.", bundle: .avoKit)
        case .checksumMismatch(let entry):
            String(localized: "The package is damaged (\(entry) failed its checksum).", bundle: .avoKit)
        case .entryTooLarge(let entry, let size):
            String(localized: "\(entry) is unexpectedly large (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))).", bundle: .avoKit)
        case .missingEntry(let entry):
            String(localized: "The package is missing \(entry).", bundle: .avoKit)
        case .unknownFormat:
            String(localized: "The file is not an APK, XAPK, APKM or APKS package.", bundle: .avoKit)
        case .noBaseAPK:
            String(localized: "The bundle does not contain a base APK.", bundle: .avoKit)
        case .io(let detail):
            String(localized: "The package could not be read: \(detail).", bundle: .avoKit)
        }
    }
}
