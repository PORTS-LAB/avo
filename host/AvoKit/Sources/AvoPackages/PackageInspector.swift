import Foundation

public enum PackageFormat: String, Sendable, Codable {
    /// A single APK.
    case apk
    /// APKPure bundle: manifest.json, split APKs and optional OBB expansions.
    case xapk
    /// APKMirror bundle: info.json and split APKs.
    case apkm
    /// SAI or bundletool split set.
    case apks
}

public struct APKPart: Sendable, Hashable, Codable {
    /// Path inside the bundle; nil when the package is a plain APK.
    public var entryPath: String?
    /// `split` attribute of the manifest; nil for the base APK.
    public var splitName: String?
    public var size: UInt64

    /// File name used for `pm install-write`.
    public var installName: String {
        if let splitName { return "split_\(splitName).apk" }
        return "base.apk"
    }
}

public struct OBBFile: Sendable, Hashable, Codable {
    public var entryPath: String
    /// Destination relative to /sdcard, e.g. `Android/obb/<pkg>/main.12.<pkg>.obb`.
    public var destination: String
    public var size: UInt64
}

public enum IconLayer: Sendable, Equatable {
    /// ARGB color.
    case color(UInt32)
    /// PNG, WebP or JPEG bytes.
    case bitmap(Data)
    /// Binary VectorDrawable XML.
    case vector(Data)
}

public enum PackageIcon: Sendable, Equatable {
    case bitmap(Data)
    case adaptive(background: IconLayer?, foreground: IconLayer?, monochrome: IconLayer?)
}

public enum CompatibilityIssue: Sendable, Equatable, Codable {
    /// Native code only for ABIs Apple Silicon cannot run (32-bit ARM, x86).
    case noArm64Code(abis: [String])
    /// Needs a newer Android than the image provides.
    case requiresNewerAndroid(minSdk: Int, available: Int)

    public var isBlocking: Bool { true }

    public var message: String {
        switch self {
        case .noArm64Code(let abis):
            "This app only contains \(abis.joined(separator: ", ")) code. Avo runs 64-bit ARM Android, so the app cannot start."
        case .requiresNewerAndroid(let minSdk, let available):
            "This app needs Android API \(minSdk); the Android image provides API \(available)."
        }
    }
}

public struct PackageSummary: Sendable {
    public var format: PackageFormat
    public var packageName: String
    public var label: String
    public var versionName: String?
    public var versionCode: Int64
    public var minSdk: Int?
    public var targetSdk: Int?
    public var permissions: [String]
    public var icon: PackageIcon?
    /// APKs that will be installed, base first.
    public var parts: [APKPart]
    /// Config splits left out (ABIs the guest cannot run).
    public var skippedSplits: [String]
    public var obbFiles: [OBBFile]
    public var nativeABIs: [String]
    public var compatibility: [CompatibilityIssue]

    public var installBytes: UInt64 { parts.reduce(0) { $0 + $1.size } }
    public var obbBytes: UInt64 { obbFiles.reduce(0) { $0 + $1.size } }
    public var isInstallable: Bool { !compatibility.contains { $0.isBlocking } }
}

/// An opened package file. Keeps the archives open so the daemon can stream
/// the selected parts to the guest after the user confirms.
public final class PackageArchive: @unchecked Sendable {
    public static let guestSDK = 36
    public static let supportedABIs: Set<String> = ["arm64-v8a"]
    static let knownABIs = ["arm64-v8a", "armeabi-v7a", "armeabi", "x86", "x86_64", "riscv64", "mips", "mips64"]

    public let url: URL
    public let summary: PackageSummary
    private let outer: ZipArchive
    private let scratch: URL

    /// Inspects `url`. `guestSDK` is the API level of the Android image.
    public convenience init(url: URL, guestSDK: Int = PackageArchive.guestSDK, languages: [String] = Locale.preferredLanguages) throws {
        try self.init(url: url, guestSDK: guestSDK, languages: languages) { try ZipArchive(url: url) }
    }

    /// Inspects an already-open package file; `url` only names it.
    public convenience init(fileDescriptor: Int32, url: URL, guestSDK: Int = PackageArchive.guestSDK,
                            languages: [String] = Locale.preferredLanguages) throws {
        try self.init(url: url, guestSDK: guestSDK, languages: languages) { try ZipArchive(fileDescriptor: fileDescriptor) }
    }

    private init(url: URL, guestSDK: Int, languages: [String], open: () throws -> ZipArchive) throws {
        self.url = url
        let scratch = FileManager.default.temporaryDirectory.appending(path: "avo-inspect-\(UUID().uuidString)")
        self.scratch = scratch
        let outer: ZipArchive
        do {
            outer = try open()
        } catch PackageError.notAZipArchive {
            throw PackageError.unknownFormat
        }
        self.outer = outer
        summary = try Self.inspect(outer, url: url, scratch: scratch, guestSDK: guestSDK, languages: languages)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Streams the bytes of one APK part.
    public func stream(_ part: APKPart, _ body: (Data) throws -> Void) throws {
        guard let path = part.entryPath else {
            // A plain APK: send the file as is, through the already-open source.
            let source = outer.source
            var offset: UInt64 = 0
            while offset < source.size {
                let count = Int(min(UInt64(1 << 20), source.size - offset))
                try body(Data(try source.read(at: offset, count: count)))
                offset += UInt64(count)
            }
            return
        }
        guard let entry = outer.entry(path) else { throw PackageError.missingEntry(path) }
        try outer.stream(entry, body)
    }

    public func stream(_ obb: OBBFile, _ body: (Data) throws -> Void) throws {
        guard let entry = outer.entry(obb.entryPath) else { throw PackageError.missingEntry(obb.entryPath) }
        try outer.stream(entry, body)
    }

    // MARK: Inspection

    private struct ParsedAPK {
        let archive: ZipArchive
        let part: APKPart
        let manifest: BinaryXMLElement
    }

    private static func inspect(_ outer: ZipArchive, url: URL, scratch: URL, guestSDK: Int,
                                languages: [String]) throws -> PackageSummary {
        if outer.entries.contains(where: \.isEncrypted) && outer.entry("AndroidManifest.xml") == nil {
            throw PackageError.encrypted
        }
        if outer.entry("AndroidManifest.xml") != nil {
            let manifest = try BinaryXML.parse(outer.data(at: "AndroidManifest.xml"))
            let base = ParsedAPK(archive: outer, part: APKPart(entryPath: nil, splitName: nil, size: outer.source.size),
                                 manifest: manifest)
            return try summarize(format: .apk, base: base, splits: [], skipped: [], obb: [],
                                 guestSDK: guestSDK, languages: languages)
        }

        let format: PackageFormat
        if outer.entry("manifest.json") != nil {
            format = .xapk
        } else if outer.entry("info.json") != nil {
            format = .apkm
        } else if outer.entries.contains(where: { $0.path.hasSuffix(".apk") }) {
            format = .apks
        } else {
            throw PackageError.unknownFormat
        }

        // Candidate APKs: bundletool sets keep splits in splits/ and also ship
        // standalone and universal APKs that must not be mixed with them.
        var candidates = outer.entries.filter { $0.path.hasSuffix(".apk") && !$0.isDirectory }
        if candidates.contains(where: { $0.path.hasPrefix("splits/") }) {
            candidates = candidates.filter { $0.path.hasPrefix("splits/") }
        }
        guard !candidates.isEmpty else { throw PackageError.noBaseAPK }

        var base: ParsedAPK?
        var splits: [ParsedAPK] = []
        var skipped: [String] = []
        for entry in candidates {
            let archive = try outer.nestedArchive(entry, scratch: scratch)
            let manifest = try BinaryXML.parse(archive.data(at: "AndroidManifest.xml"))
            let splitName = manifest.attribute("split")?.stringValue
            let parsed = ParsedAPK(archive: archive,
                                   part: APKPart(entryPath: entry.path, splitName: splitName, size: entry.uncompressedSize),
                                   manifest: manifest)
            if let splitName {
                if let abi = abiOfConfigSplit(splitName), !supportedABIs.contains(abi) {
                    skipped.append(splitName)
                } else {
                    splits.append(parsed)
                }
            } else if base == nil {
                base = parsed
            } else {
                skipped.append(entry.path) // a second base (e.g. universal.apk next to splits)
            }
        }
        guard let base else { throw PackageError.noBaseAPK }
        splits.sort { ($0.part.splitName ?? "") < ($1.part.splitName ?? "") }

        let packageName = base.manifest.attribute("package")?.stringValue ?? ""
        let obb = format == .xapk ? try obbFiles(in: outer, package: packageName) : []
        return try summarize(format: format, base: base, splits: splits, skipped: skipped, obb: obb,
                             guestSDK: guestSDK, languages: languages)
    }

    private static func summarize(format: PackageFormat, base: ParsedAPK, splits: [ParsedAPK], skipped: [String],
                                  obb: [OBBFile], guestSDK: Int, languages: [String]) throws -> PackageSummary {
        let manifest = base.manifest
        guard let packageName = manifest.attribute("package")?.stringValue, !packageName.isEmpty else {
            throw PackageError.malformed("manifest has no package name")
        }
        let table = try? ResourceTable(data: base.archive.data(at: "resources.arsc", limit: 256 << 20))
        let application = manifest.first("application")

        func text(_ value: ResourceValue?) -> String? {
            switch value {
            case .string(let s)?: s
            case .reference(let id)?: table?.string(id, languages: languages)
            default: value?.stringValue
            }
        }

        let label = text(application?.attribute("label", id: AndroidAttribute.label))
            ?? text(manifest.attribute("label", id: AndroidAttribute.label))
            ?? packageName
        let versionCode = (manifest.attribute("versionCode", id: AndroidAttribute.versionCode)?.intValue ?? 0)
            | (manifest.attribute("versionCodeMajor", id: AndroidAttribute.versionCodeMajor)?.intValue ?? 0) << 32
        let usesSdk = manifest.first("uses-sdk")
        let minSdk = usesSdk?.attribute("minSdkVersion", id: AndroidAttribute.minSdkVersion)?.intValue.map(Int.init)
        let targetSdk = usesSdk?.attribute("targetSdkVersion", id: AndroidAttribute.targetSdkVersion)?.intValue.map(Int.init)
        let permissions = (manifest.children(named: "uses-permission") + manifest.children(named: "uses-permission-sdk-23"))
            .compactMap { $0.attribute("name", id: AndroidAttribute.name)?.stringValue }

        // Native code: lib/<abi>/ in any part, plus ABI config splits (kept or skipped).
        var abis = Set<String>()
        for apk in [base] + splits {
            for entry in apk.archive.entries where entry.path.hasPrefix("lib/") {
                let components = entry.path.split(separator: "/")
                if components.count >= 3 { abis.insert(String(components[1])) }
            }
            if let split = apk.part.splitName, let abi = abiOfConfigSplit(split) { abis.insert(abi) }
        }
        for split in skipped { if let abi = abiOfConfigSplit(split) { abis.insert(abi) } }

        var issues: [CompatibilityIssue] = []
        if !abis.isEmpty && abis.isDisjoint(with: supportedABIs) {
            issues.append(.noArm64Code(abis: abis.sorted()))
        }
        if let minSdk, minSdk > guestSDK {
            issues.append(.requiresNewerAndroid(minSdk: minSdk, available: guestSDK))
        }

        let iconValue = application?.attribute("icon", id: AndroidAttribute.icon)
        let icon = table.flatMap { table in
            iconValue.flatMap { loadIcon($0, table: table, archives: [base.archive] + splits.map(\.archive)) }
        }

        return PackageSummary(
            format: format, packageName: packageName, label: label,
            versionName: text(manifest.attribute("versionName", id: AndroidAttribute.versionName)),
            versionCode: versionCode, minSdk: minSdk, targetSdk: targetSdk,
            permissions: permissions.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
            icon: icon, parts: [base.part] + splits.map(\.part), skippedSplits: skipped,
            obbFiles: obb, nativeABIs: abis.sorted(), compatibility: issues)
    }

    static func abiOfConfigSplit(_ split: String) -> String? {
        guard split.hasPrefix("config.") else { return nil }
        // Split names spell ABIs with underscores (arm64_v8a); x86_64 has one natively.
        let qualifier = split.dropFirst("config.".count)
        return knownABIs.first { $0.replacingOccurrences(of: "-", with: "_") == qualifier }
    }

    private static func obbFiles(in archive: ZipArchive, package: String) throws -> [OBBFile] {
        struct Manifest: Decodable {
            struct Expansion: Decodable {
                let file: String
                let install_path: String?
            }
            let expansions: [Expansion]?
        }
        var files: [OBBFile] = []
        if let data = try? archive.data(at: "manifest.json"),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            for expansion in manifest.expansions ?? [] {
                guard let entry = archive.entry(expansion.file) else { continue }
                let destination = expansion.install_path ?? expansion.file
                files.append(OBBFile(entryPath: entry.path, destination: destination, size: entry.uncompressedSize))
            }
        }
        if files.isEmpty {
            // XAPK v1 has no expansions list; OBBs sit under Android/obb/<package>/.
            for entry in archive.entries where entry.path.hasPrefix("Android/obb/") && entry.path.hasSuffix(".obb") {
                files.append(OBBFile(entryPath: entry.path, destination: entry.path, size: entry.uncompressedSize))
            }
        }
        // Only accept destinations inside this package's OBB directory.
        let allowed = "Android/obb/\(package)/"
        return files.filter { $0.destination.hasPrefix(allowed) && !$0.destination.contains("..") }
    }

    // MARK: Icons

    private static func loadIcon(_ value: ResourceValue, table: ResourceTable, archives: [ZipArchive]) -> PackageIcon? {
        guard case .reference(let id) = value, let resolved = table.drawable(id) else { return nil }
        if case .string(let path) = resolved {
            if path.hasSuffix(".xml"), let xml = file(path, in: archives) {
                if let root = try? BinaryXML.parse(xml), root.name == "adaptive-icon" {
                    func layer(_ name: String) -> IconLayer? {
                        guard let element = root.first(name),
                              let drawable = element.attribute("drawable", id: AndroidAttribute.drawable) else { return nil }
                        return iconLayer(drawable, table: table, archives: archives)
                    }
                    let adaptive = PackageIcon.adaptive(background: layer("background"), foreground: layer("foreground"),
                                                        monochrome: layer("monochrome"))
                    if case .adaptive(nil, nil, _) = adaptive {} else { return adaptive }
                }
                // Not adaptive (or unreadable): fall back to the best bitmap.
                if let bitmap = table.drawable(id, adaptive: false), case .string(let bitmapPath) = bitmap,
                   !bitmapPath.hasSuffix(".xml"), let data = file(bitmapPath, in: archives) {
                    return .bitmap(data)
                }
                return nil
            }
            return file(path, in: archives).map(PackageIcon.bitmap)
        }
        return nil
    }

    private static func iconLayer(_ value: ResourceValue, table: ResourceTable, archives: [ZipArchive]) -> IconLayer? {
        switch value {
        case .color(let argb):
            return .color(argb)
        case .reference(let id):
            guard let resolved = table.drawable(id, adaptive: false) else { return nil }
            if case .color(let argb) = resolved { return .color(argb) }
            guard case .string(let path) = resolved, let data = file(path, in: archives) else { return nil }
            return path.hasSuffix(".xml") ? .vector(data) : .bitmap(data)
        default:
            return nil
        }
    }

    /// A file from the base APK or, for density splits, from any split.
    private static func file(_ path: String, in archives: [ZipArchive]) -> Data? {
        for archive in archives {
            if let entry = archive.entry(path), let data = try? archive.data(of: entry, limit: 16 << 20) { return data }
        }
        return nil
    }
}
