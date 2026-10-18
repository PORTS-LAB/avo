import AvoKit
import Foundation

/// Why a Google apps package or release cannot be used.
public enum GoogleAppsError: Error, Equatable, Sendable, LocalizedError {
    case notAPackage
    case unsupportedLayout(String)
    case unsafePath(String)
    case wrongArchitecture(package: String, device: String)
    case wrongAndroidVersion(package: String, deviceSDK: Int)
    case invalidReleaseURL(String)
    case noPackageInRelease(String)
    case noChecksum(String)
    case checksumMismatch(String)
    case download(String)

    public var errorDescription: String? {
        switch self {
        case .notAPackage:
            String(localized: "This is not a MindTheGapps package: build.prop or the system folder is missing. Choose the .zip, or the folder it unzips to.", bundle: .avoKit)
        case .unsupportedLayout(let path):
            String(localized: "The package has files Avo does not install (\(path)). Use a MindTheGapps package.", bundle: .avoKit)
        case .unsafePath(let path):
            String(localized: "The package has an unsafe file name: \(path).", bundle: .avoKit)
        case let .wrongArchitecture(package, device):
            String(localized: "The package is built for \(package), but Android here is \(device).", bundle: .avoKit)
        case let .wrongAndroidVersion(package, sdk):
            // The package line that fits this Android (`17.0.0-arm64` for API level 37).
            if let line = GoogleAppsLine(sdk: sdk) {
                String(localized: "The package is for \(package), but this Android has API level \(sdk). Use \(line.name).", bundle: .avoKit)
            } else {
                String(localized: "The package is for \(package), but this Android has API level \(sdk).", bundle: .avoKit)
            }
        case .invalidReleaseURL(let url):
            String(localized: "\(url) is not a GitHub release link.", bundle: .avoKit)
        case .noPackageInRelease(let release):
            String(localized: "Release \(release) has no .zip package.", bundle: .avoKit)
        case .noChecksum(let asset):
            String(localized: "The release publishes no SHA-256 checksum for \(asset), so Avo cannot verify the download.", bundle: .avoKit)
        case .checksumMismatch(let asset):
            String(localized: "\(asset) does not match the release’s SHA-256 checksum. Try downloading it again.", bundle: .avoKit)
        case .download(let detail):
            String(localized: "The download failed: \(detail)", bundle: .avoKit)
        }
    }
}

/// A MindTheGapps flashable package, as a .zip or the folder it unzips to:
///
///     build.prop                 arch=arm64, version=<SDK>, version_nice=<Android>.0.0
///     META-INF/…                 the recovery installer (never run)
///     system/product/…           → /product
///     system/system_ext/…        → /system_ext
///     system/addon.d/…           recovery OTA survival script (not used)
///     toybox                     for the recovery installer
///
/// A package nested one folder deep (re-zipped by Finder) works too.
public final class GoogleAppsPackage: Sendable {
    public struct File: Sendable, Hashable {
        /// Where it goes, relative to the root of Android's partitions:
        /// `product/priv-app/Phonesky/Phonesky.apk`.
        public let path: String
        public let size: UInt64
        let source: Source
    }

    enum Source: Sendable, Hashable {
        case zip(ZipEntry)
        case file(URL)
    }

    /// The package's build.prop.
    public let properties: [String: String]
    /// Everything for /product and /system_ext, before `plan` applies the installer's rules.
    public let files: [File]
    private let zip: ZipArchive?

    public var arch: String? { properties["arch"] }
    public var sdk: Int? { properties["version"].flatMap { Int($0) } }
    /// `17.0.0` (MindTheGapps' `version_nice`).
    public var versionName: String? { properties["version_nice"] }
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }

    /// Opens a .zip or a package folder.
    public convenience init(url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PackageError.io(String(localized: "\(url.lastPathComponent) is missing", bundle: .avoKit))
        }
        if isDirectory.boolValue {
            let items = try Self.walk(url)
            try self.init(items: items.map { ($0.path, $0.size, Source.file($0.url)) }, zip: nil) { item in
                guard case .file(let url) = item.source else { throw GoogleAppsError.notAPackage }
                return try Data(contentsOf: url)
            }
        } else {
            let zip = try ZipArchive(url: url)
            let items = zip.entries.filter { !$0.isDirectory }.map { ($0.path, $0.uncompressedSize, Source.zip($0)) }
            try self.init(items: items, zip: zip) { item in
                guard case .zip(let entry) = item.source else { throw GoogleAppsError.notAPackage }
                return try zip.data(of: entry, limit: 1 << 20)
            }
        }
    }

    private init(items: [(String, UInt64, Source)], zip: ZipArchive?, read: (File) throws -> Data) throws {
        self.zip = zip
        let entries = items.filter { !Self.isMacJunk($0.0) }
        guard let prefix = Self.packageRoot(entries.map(\.0)) else { throw GoogleAppsError.notAPackage }
        var properties: [String: String] = [:]
        var files: [File] = []
        for (fullPath, size, source) in entries where fullPath.hasPrefix(prefix) {
            let path = String(fullPath.dropFirst(prefix.count))
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw GoogleAppsError.unsafePath(fullPath)
            }
            if path == "build.prop" {
                guard size <= 1 << 20 else { throw GoogleAppsError.notAPackage }
                properties = Self.parseProperties(String(decoding: try read(File(path: path, size: size, source: source)), as: UTF8.self))
                continue
            }
            guard components.count > 2, components[0] == "system" else { continue } // META-INF, toybox
            switch components[1] {
            case "product", "system_ext":
                files.append(File(path: components.dropFirst().joined(separator: "/"), size: size, source: source))
            case "addon.d":
                continue // recovery's backup/restore script for OTA updates
            default:
                throw GoogleAppsError.unsupportedLayout(path)
            }
        }
        guard !properties.isEmpty, !files.isEmpty else { throw GoogleAppsError.notAPackage }
        self.properties = properties
        self.files = files.sorted { $0.path < $1.path }
    }

    /// The files to install on a device, after checking the package is for it.
    /// `arch` is `ro.bionic.arch` (`arm64`), `sdk` `ro.build.version.sdk`,
    /// `product` `ro.build.product`.
    public func plan(sdk deviceSDK: Int, arch deviceArch: String, product: String) throws -> [File] {
        guard let arch, arch == deviceArch else {
            throw GoogleAppsError.wrongArchitecture(package: arch ?? "?", device: deviceArch)
        }
        guard let sdk, sdk == deviceSDK else {
            let name = versionName.map { "Android \($0) (SDK \(sdk.map(String.init) ?? "?"))" } ?? "SDK \(sdk.map(String.init) ?? "?")"
            throw GoogleAppsError.wrongAndroidVersion(package: name, deviceSDK: deviceSDK)
        }
        return files.filter { Self.installs($0.path, product: product) }
    }

    /// The rules of MindTheGapps' own installer (META-INF/com/google/android/
    /// update-binary) that apply here, without running it:
    /// - VelvetTitan (the Google app for tablets) only on tangorpro (Pixel
    ///   Tablet), which gets it instead of Velvet;
    /// - no Google SetupWizard: AOSP's Provision stays, and Android's own
    ///   screen, where a setup wizard would wait, is never shown in Avo.
    public static func installs(_ path: String, product: String) -> Bool {
        let tablet = product == "tangorpro"
        let skipped = [
            tablet ? "product/priv-app/Velvet/" : "product/priv-app/VelvetTitan/",
            "system_ext/priv-app/SetupWizard/",
        ]
        return !skipped.contains { path.hasPrefix($0) }
    }

    /// Streams one file's bytes.
    public func stream(_ file: File, _ body: (Data) throws -> Void) throws {
        switch file.source {
        case .zip(let entry):
            guard let zip else { throw GoogleAppsError.notAPackage }
            try zip.stream(entry, body)
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { try body(chunk) }
        }
    }

    // MARK: Parsing

    /// `key=value` lines; `#` comments.
    static func parseProperties(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, result[key] == nil {
                result[key] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    /// "" when build.prop is at the top, `name/` when the package sits in one folder.
    static func packageRoot(_ paths: [String]) -> String? {
        if paths.contains("build.prop") { return "" }
        let roots = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1] == "build.prop" ? String(parts[0]) + "/" : nil
        }).filter { root in paths.contains { $0.hasPrefix(root + "system/") } }
        return roots.count == 1 ? roots.first : nil
    }

    /// Finder's additions: `__MACOSX/`, `._name` and `.DS_Store`.
    static func isMacJunk(_ path: String) -> Bool {
        path.hasPrefix("__MACOSX/") || path.split(separator: "/").contains { $0 == ".DS_Store" || $0.hasPrefix("._") }
    }

    /// Regular files under a folder, as paths relative to it. Symbolic links
    /// are refused: they could point anywhere on the Mac.
    static func walk(_ root: URL) throws -> [(path: String, size: UInt64, url: URL)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw PackageError.io(root.lastPathComponent)
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [(String, UInt64, URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            // The folder's own path resolved (/var → /private/var), not the item's.
            let full = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path + "/" + url.lastPathComponent
            let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
            if values.isSymbolicLink == true { throw GoogleAppsError.unsafePath(relative) }
            guard values.isRegularFile == true else { continue }
            result.append((relative, UInt64(values.fileSize ?? 0), url))
        }
        return result
    }
}
