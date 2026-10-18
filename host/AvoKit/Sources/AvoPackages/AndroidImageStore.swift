import AvoKit
import Foundation

// The Android images on this Mac and which one Android starts with.
//
//   ~/Library/Application Support/Avo/images/
//     selection.json                 the image Android starts with, and the one before it
//     android-17-16373615/           an image Avo installed (downloaded or imported)
//       manifest.json                CuttlefishImageManifest: SHA-256 and size of every file
//       .verified.json               file identities already checked against it
//       boot.img init_boot.img vendor_boot.img super.img vbmeta*.img …
//   ~/Library/Caches/Avo/images/     partial downloads, the catalog's version cache
//   ~/Library/Application Support/Avo/vm/ (or the folder Android's data is in, AvoPaths.data)
//     cuttlefish/avo-image.json      the image avo-vmm's writable copies come from
//     android-data.json              the newest Android that used the data disk
//
// Images elsewhere (~/Library/Caches/Avo/cuttlefish/<build>/img from
// scripts/fetch-cuttlefish.sh, images/cuttlefish, the AvoCuttlefishImages
// developer setting) are used where they are and never changed.

/// Where an image came from.
public enum AndroidImageOrigin: Codable, Equatable, Hashable, Sendable {
    /// Downloaded from the Android Build API and checked against the MD5 it gave.
    case androidBuild(branch: String, target: String, build: String, artifact: String, md5: String)
    /// Copied or unpacked from a file or folder on this Mac.
    case imported(name: String)
    /// Used where it is: a folder scripts/fetch-cuttlefish.sh or an older Avo
    /// made, or the developer setting. Avo never changes it.
    case external
}

/// `images/<id>/manifest.json`: an AOSP Cuttlefish image Avo installed.
///
/// These builds are Google's, so there is no Avo signature (schema 1,
/// `AndroidImage`, is for images Avo builds and signs). The trust is local:
/// Avo checked the download against the MD5 the Android Build API gave over
/// HTTPS (or read the files the user chose), and recorded every file's size
/// and SHA-256; the daemon checks the files against it before each start.
public struct CuttlefishImageManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let cuttlefish = "cuttlefish"
    public static let localTrust = "local"

    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var sha256: String
        public var size: Int64

        public init(name: String, sha256: String, size: Int64) {
            self.name = name
            self.sha256 = sha256
            self.size = size
        }
    }

    public var schema: Int
    public var format: String
    public var trust: String
    public var id: String
    public var release: AndroidRelease
    public var build: String
    public var fingerprint: String
    public var origin: AndroidImageOrigin
    public var installedAt: Date
    public var files: [File]

    public init(id: String, release: AndroidRelease, build: String, fingerprint: String, origin: AndroidImageOrigin,
                installedAt: Date = Date(), files: [File]) {
        schema = Self.schemaVersion
        format = Self.cuttlefish
        trust = Self.localTrust
        self.id = id
        self.release = release
        self.build = build
        self.fingerprint = fingerprint
        self.origin = origin
        // Whole seconds, as the file keeps it (ISO 8601).
        self.installedAt = Date(timeIntervalSince1970: installedAt.timeIntervalSince1970.rounded(.down))
        self.files = files
    }

    public static let fileName = "manifest.json"

    public static func load(from directory: URL) throws -> CuttlefishImageManifest {
        let data = try Data(contentsOf: directory.appending(path: fileName))
        let manifest = try JSONDecoder.avoImages.decode(CuttlefishImageManifest.self, from: data)
        guard manifest.schema == schemaVersion, manifest.format == cuttlefish else {
            throw AndroidImageError.notAnImage(String(localized: "Its manifest is not one this version of Avo reads.", bundle: .avoKit))
        }
        return manifest
    }

    public func write(to directory: URL) throws {
        try JSONEncoder.avoImages.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }
}

/// An Android image on this Mac.
public struct AndroidImageSummary: Equatable, Hashable, Sendable, Identifiable {
    /// The image folder, standardized.
    public var directory: URL
    /// What the files say; nil when they do not say (an unusual folder).
    public var release: AndroidRelease?
    /// The CI build number.
    public var build: String?
    public var origin: AndroidImageOrigin
    public var installedAt: Date?
    /// Bytes of the image's files.
    public var size: Int64

    public init(directory: URL, release: AndroidRelease?, build: String?, origin: AndroidImageOrigin, installedAt: Date?, size: Int64) {
        // One spelling per folder (with the trailing slash), so summaries compare equal.
        self.directory = URL(filePath: directory.standardizedFileURL.path, directoryHint: .isDirectory)
        self.release = release
        self.build = build
        self.origin = origin
        self.installedAt = installedAt
        self.size = size
    }

    public var id: String { path }
    public var path: String { directory.path }
    /// Installed (and removable) by Avo, with a manifest it checks.
    public var isManaged: Bool { origin != .external }
    /// `Android 17`, or `Android` when the files do not say.
    public var name: String { release?.name ?? "Android" }

    /// Newest Android first; within one, the newest build.
    public static func newestFirst(_ a: AndroidImageSummary, _ b: AndroidImageSummary) -> Bool {
        switch (a.release, b.release) {
        case let (x?, y?) where x.isOlder(than: y): return false
        case let (x?, y?) where y.isOlder(than: x): return true
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        if let x = a.build.flatMap({ Int($0) }), let y = b.build.flatMap({ Int($0) }), x != y { return x > y }
        if a.isManaged != b.isManaged { return a.isManaged }
        return a.path < b.path
    }
}

/// `images/selection.json`.
public struct AndroidImageSelection: Codable, Equatable, Sendable {
    public var current: String?
    /// The image before it, kept to go back to.
    public var previous: String?
    public var changedAt: Date?

    public init(current: String? = nil, previous: String? = nil, changedAt: Date? = nil) {
        self.current = current
        self.previous = previous
        self.changedAt = changedAt
    }
}

/// `vm/cuttlefish/avo-image.json`, written by the daemon before each start:
/// the image avo-vmm's writable copies of super and vbmeta come from.
public struct AndroidImageBootRecord: Codable, Equatable, Sendable {
    public var path: String
    public var build: String?
    public var release: AndroidRelease?
    public var date: Date

    public init(path: String, build: String?, release: AndroidRelease?, date: Date) {
        self.path = path
        self.build = build
        self.release = release
        self.date = date
    }
}

/// `vm/android-data.json`: the newest Android that used the data disk.
/// Android upgrades its data on the first start of a newer version, and
/// cannot use it again with an older one.
public struct AndroidDataRecord: Codable, Equatable, Sendable {
    public var release: AndroidRelease
    public var build: String?
    public var date: Date

    public init(release: AndroidRelease, build: String?, date: Date) {
        self.release = release
        self.build = build
        self.date = date
    }
}

/// What changing to another image does to Android's apps and data.
public enum AndroidImageChange: Equatable, Sendable {
    /// Android has no data yet (first setup, or after Reset Android).
    case fresh
    /// The image Android starts with already.
    case same
    /// Another build of the Android version the data is from: apps and data stay.
    case sameVersion
    /// A newer Android: apps and data stay, and they cannot go back.
    case upgrade
    /// Older than Android's data: it starts only after the data is erased.
    case downgrade
}

public struct AndroidImageStore: Sendable {
    public let paths: AvoPaths

    public init(paths: AvoPaths) {
        self.paths = paths
    }

    public var root: URL { paths.images }
    public var cache: URL { paths.home.appending(path: "Library/Caches/Avo/images", directoryHint: .isDirectory) }
    public var downloads: URL { cache.appending(path: "downloads", directoryHint: .isDirectory) }
    public var catalogCache: URL { cache.appending(path: "builds.json") }
    /// avo-vmm's disks (VMMEngine's `--disks`, beside Android's data disk):
    /// writable copies of super and vbmeta, and the misc, metadata and frp disks.
    public var instance: URL { paths.dataDisks }
    var selectionFile: URL { root.appending(path: "selection.json") }
    var bootRecordFile: URL { instance.appending(path: "avo-image.json") }
    var dataRecordFile: URL { paths.data.appending(path: "android-data.json") }
    /// scripts/fetch-cuttlefish.sh's downloads, `<build>/img`.
    var legacyDownloads: URL { paths.home.appending(path: "Library/Caches/Avo/cuttlefish", directoryHint: .isDirectory) }
    static let verifiedName = ".verified.json"
    static let stagingPrefix = ".staging-"

    /// `android-17-16373615`.
    public static func folderName(release: AndroidRelease, build: String) -> String {
        let safe = { (text: String) in String(text.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }) }
        return "android-\(safe(release.version))-\(safe(build))"
    }

    // MARK: Finding images

    /// Images Avo installed, newest first.
    public func managed() -> [AndroidImageSummary] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { folder -> AndroidImageSummary? in
                guard let manifest = try? CuttlefishImageManifest.load(from: folder) else { return nil }
                return Self.summary(manifest, at: folder)
            }
            .sorted(by: AndroidImageSummary.newestFirst)
    }

    /// Images Avo uses where they are: the developer setting, images/cuttlefish
    /// and scripts/fetch-cuttlefish.sh's downloads.
    public func external(override: String?) -> [AndroidImageSummary] {
        var folders: [URL] = []
        if let override, !override.isEmpty { folders.append(URL(filePath: override, directoryHint: .isDirectory)) }
        folders.append(root.appending(path: "cuttlefish", directoryHint: .isDirectory))
        let builds = (try? FileManager.default.contentsOfDirectory(at: legacyDownloads, includingPropertiesForKeys: nil)) ?? []
        folders += builds.map { $0.appending(path: "img", directoryHint: .isDirectory) }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .compactMap { summary(of: $0) }
            .filter { !$0.isManaged }
            .sorted(by: AndroidImageSummary.newestFirst)
    }

    /// Every image on this Mac, newest first.
    public func installed(override: String? = nil) -> [AndroidImageSummary] {
        var seen = Set<String>()
        return (managed() + external(override: override)).filter { seen.insert($0.path).inserted }
            .sorted(by: AndroidImageSummary.newestFirst)
    }

    /// The image in `directory`, if it is one.
    public func summary(of directory: URL) -> AndroidImageSummary? {
        if let manifest = try? CuttlefishImageManifest.load(from: directory) { return Self.summary(manifest, at: directory) }
        guard CuttlefishImageFiles.isImage(directory) else { return nil }
        let identity = try? Self.identity(of: directory)
        let buildFile = try? String(contentsOf: directory.deletingLastPathComponent().appending(path: "BUILD_ID"), encoding: .utf8)
        let build = identity?.build ?? buildFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = CuttlefishImageFiles.all.reduce(Int64(0)) { total, name in
            total + ((try? FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.size] as? Int64) ?? 0)
        }
        return AndroidImageSummary(directory: directory, release: identity?.release, build: build, origin: .external,
                                   installedAt: nil, size: size)
    }

    static func summary(_ manifest: CuttlefishImageManifest, at directory: URL) -> AndroidImageSummary {
        AndroidImageSummary(directory: directory, release: manifest.release, build: manifest.build, origin: manifest.origin,
                            installedAt: manifest.installedAt, size: manifest.files.reduce(0) { $0 + $1.size })
    }

    /// What an image folder's vbmeta images and boot header say.
    public static func identity(of directory: URL) throws -> CuttlefishImageIdentity {
        func head(_ name: String, _ count: Int) -> Data? {
            guard let handle = try? FileHandle(forReadingFrom: directory.appending(path: name)) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: count)
        }
        let vbmeta = ["vbmeta.img", "vbmeta_system.img"].compactMap { head($0, 64 << 10) }
        return try CuttlefishImageIdentity.read(vbmeta: vbmeta, bootHeader: head("init_boot.img", 64) ?? head("boot.img", 64))
    }

    // MARK: Choosing

    public func selection() -> AndroidImageSelection {
        (try? Data(contentsOf: selectionFile)).flatMap { try? JSONDecoder.avoImages.decode(AndroidImageSelection.self, from: $0) }
            ?? AndroidImageSelection()
    }

    /// Android starts with `image` from its next start; the image it used
    /// before stays as the previous one.
    public func select(_ image: AndroidImageSummary) throws {
        var selection = selection()
        let wasCurrent = selection.current ?? imageForBoot(override: nil)?.path
        guard wasCurrent != image.path || selection.current != image.path else { return }
        if let wasCurrent, wasCurrent != image.path { selection.previous = wasCurrent }
        selection.current = image.path
        selection.changedAt = Date()
        if selection.previous == image.path { selection.previous = nil }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.avoImages.encode(selection).write(to: selectionFile, options: .atomic)
    }

    /// The image Android starts with: the developer setting, else the one
    /// chosen in Avo, else images/cuttlefish, else the newest on this Mac.
    public func imageForBoot(override: String?) -> AndroidImageSummary? {
        if let override, !override.isEmpty, let image = summary(of: URL(filePath: override, directoryHint: .isDirectory)) {
            return image
        }
        if let current = selection().current, let image = summary(of: URL(filePath: current, directoryHint: .isDirectory)) {
            return image
        }
        if let image = summary(of: root.appending(path: "cuttlefish", directoryHint: .isDirectory)) { return image }
        return installed().first
    }

    /// The image chosen before the current one, if it is still here.
    public func previousImage() -> AndroidImageSummary? {
        guard let previous = selection().previous else { return nil }
        return summary(of: URL(filePath: previous, directoryHint: .isDirectory))
    }

    /// Removes an image Avo installed. Never the one Android starts with.
    public func remove(_ image: AndroidImageSummary) throws {
        guard image.isManaged, image.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw AndroidImageError.io(String(localized: "Avo removes only images it installed itself.", bundle: .avoKit))
        }
        var selection = selection()
        guard selection.current != image.path, imageForBoot(override: nil)?.path != image.path else {
            throw AndroidImageError.io(String(localized: "Android starts with this image. Choose another one first.", bundle: .avoKit))
        }
        try FileManager.default.removeItem(at: image.directory)
        if selection.previous == image.path {
            selection.previous = nil
            try? JSONEncoder.avoImages.encode(selection).write(to: selectionFile, options: .atomic)
        }
    }

    /// Leftovers of installs that stopped halfway (Avo quit meanwhile).
    public func removeStaging() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Checking

    /// Checks an installed image's files against its manifest (sizes and
    /// SHA-256). Files whose identity (size, modification date, inode) was
    /// checked before are not read again. External images have nothing to
    /// check against and pass.
    public func verify(_ image: AndroidImageSummary) throws {
        guard image.isManaged else { return }
        let manifest = try CuttlefishImageManifest.load(from: image.directory)
        let listed = Set(manifest.files.map(\.name))
        let missing = Set(CuttlefishImageFiles.required).subtracting(listed)
        guard missing.isEmpty else {
            throw AvoError.internalError(String(localized: "The image manifest does not cover \(missing.sorted().joined(separator: ", ")).",
                                                bundle: .avoKit))
        }
        var stamps = VerifiedFiles.load(image.directory)
        var changed = false
        for file in manifest.files {
            guard Self.isPlainName(file.name) else {
                throw AvoError.internalError(String(localized: "Invalid file name in image manifest: \(file.name)", bundle: .avoKit))
            }
            let url = image.directory.appending(path: file.name)
            guard let identity = FileIdentity(url), identity.size == file.size else {
                throw AvoError.internalError(String(localized: "\(file.name) has the wrong size.", bundle: .avoKit))
            }
            if stamps.files[file.name] == VerifiedFiles.Stamp(identity: identity, sha256: file.sha256) { continue }
            guard try Checksum.sha256(of: url) == file.sha256.lowercased() else {
                throw AvoError.internalError(String(localized: "\(file.name) failed its checksum.", bundle: .avoKit))
            }
            stamps.files[file.name] = VerifiedFiles.Stamp(identity: identity, sha256: file.sha256)
            changed = true
        }
        if changed { stamps.save(image.directory) }
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name != Self.verifiedName
    }

    // MARK: Starting Android

    /// What a start with another image did to avo-vmm's copies.
    public enum InstanceChange: Equatable, Sendable {
        case none
        /// super and vbmeta went; avo-vmm copies the new image's.
        case replaced
        /// Also, verified boot stays off as Google apps left it (another
        /// build of the same Android version: its overlay still fits).
        case replacedKeepingVerifiedBootOff
    }

    /// Run by the daemon before every start. When avo-vmm's writable copies
    /// of super and vbmeta come from another image than `image`, they go
    /// (avo-vmm copies the new image's at start); the data disk and the
    /// instance's metadata disk (the key to Android's encrypted data) stay.
    /// `avbctl disable-verity` (Google apps) changed the vbmeta copy's flags:
    /// for another build of the same Android version the new copy gets them
    /// too, so Google apps' overlay mounts again; for another version verified
    /// boot is back on and the overlay, which would not fit, stays unused.
    /// `unrecorded` is the image an older Avo booted, for an instance made
    /// before these records existed. Also notes which Android uses the data.
    @discardableResult
    public func prepareStart(with image: AndroidImageSummary, unrecorded: URL?) throws -> InstanceChange {
        let last = bootRecord()
        let madeFrom = last?.path ?? unrecorded?.standardizedFileURL.path
        let copies = ["super.img", "vbmeta.img"].map { instance.appending(path: $0) }
        var change = InstanceChange.none
        // The same build in another folder (Android's data carried to another
        // Mac) is the same image: its copies stay as they are.
        let sameBuild = last?.build != nil && last?.build == image.build && last?.release?.version == image.release?.version
        if madeFrom != image.path, !sameBuild, copies.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let vbmeta = instance.appending(path: "vbmeta.img")
            let flags = Self.vbmetaFlags(vbmeta) ?? 0
            let before = last != nil ? last?.release : unrecorded.flatMap { summary(of: $0)?.release }
            for copy in copies where FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
            change = .replaced
            if flags != 0, let before, let release = image.release, before.version == release.version {
                try FileManager.default.copyItem(at: image.directory.appending(path: "vbmeta.img"), to: vbmeta)
                try Self.setVBMetaFlags(flags, in: vbmeta)
                change = .replacedKeepingVerifiedBootOff
            }
        }
        if !FileManager.default.fileExists(atPath: instance.path) {
            // Elsewhere than Avo's own storage, only inside a data folder that is there.
            try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: paths.isDataInternal)
        }
        let record = AndroidImageBootRecord(path: image.path, build: image.build, release: image.release, date: Date())
        try JSONEncoder.avoImages.encode(record).write(to: bootRecordFile, options: .atomic)
        if let release = image.release {
            var newest = release
            if let old = dataRecord()?.release, !old.isOlder(than: release) { newest = old }
            let data = AndroidDataRecord(release: newest, build: newest == release ? image.build : dataRecord()?.build, date: Date())
            try JSONEncoder.avoImages.encode(data).write(to: dataRecordFile, options: .atomic)
        }
        return change
    }

    /// The flags of a vbmeta image's header (verity and verification off).
    static func vbmetaFlags(_ url: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 128), header.count == 128, header.prefix(4) == Data("AVB0".utf8) else { return nil }
        return header[120..<124].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func setVBMetaFlags(_ flags: UInt32, in url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 120)
        try handle.write(contentsOf: withUnsafeBytes(of: flags.bigEndian) { Data($0) })
    }

    /// The image the last start used (nil before the first start with this Avo).
    public func bootRecord() -> AndroidImageBootRecord? {
        (try? Data(contentsOf: bootRecordFile)).flatMap { try? JSONDecoder.avoImages.decode(AndroidImageBootRecord.self, from: $0) }
    }

    /// The newest Android that used the data disk; nil when there is no data disk.
    public func dataRecord() -> AndroidDataRecord? {
        guard FileManager.default.fileExists(atPath: paths.dataDisk.path) else { return nil }
        return (try? Data(contentsOf: dataRecordFile)).flatMap { try? JSONDecoder.avoImages.decode(AndroidDataRecord.self, from: $0) }
    }

    /// What starting Android with `release` (in `path`) instead of `current` does to its data.
    public func change(to release: AndroidRelease?, path: String?, current: AndroidImageSummary?) -> AndroidImageChange {
        if let path, path == current?.path { return .same }
        guard FileManager.default.fileExists(atPath: paths.dataDisk.path) else { return .fresh }
        guard let release, let data = dataRecord()?.release ?? current?.release else { return .sameVersion }
        return Self.change(from: data, to: release)
    }

    public static func change(from data: AndroidRelease, to release: AndroidRelease) -> AndroidImageChange {
        if release.isOlder(than: data) { return .downgrade }
        if release.sdk > data.sdk || (release.major ?? 0) > (data.major ?? 0) { return .upgrade }
        return .sameVersion
    }
}

/// `.verified.json`: which file identities matched the manifest.
struct VerifiedFiles: Codable {
    struct Stamp: Codable, Equatable {
        var size: Int64
        var modified: Double
        var inode: UInt64
        var sha256: String

        init(identity: FileIdentity, sha256: String) {
            size = identity.size
            modified = identity.modified
            inode = identity.inode
            self.sha256 = sha256.lowercased()
        }
    }

    var files: [String: Stamp] = [:]

    static func load(_ directory: URL) -> VerifiedFiles {
        (try? Data(contentsOf: directory.appending(path: AndroidImageStore.verifiedName)))
            .flatMap { try? JSONDecoder().decode(VerifiedFiles.self, from: $0) } ?? VerifiedFiles()
    }

    func save(_ directory: URL) {
        try? JSONEncoder().encode(self).write(to: directory.appending(path: AndroidImageStore.verifiedName), options: .atomic)
    }
}

/// Size, modification date and inode: what changes when a file is replaced or written.
struct FileIdentity: Equatable {
    var size: Int64
    var modified: Double
    var inode: UInt64

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        size = Int64(info.st_size)
        modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        inode = UInt64(info.st_ino)
    }
}

extension JSONEncoder {
    static var avoImages: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var avoImages: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
