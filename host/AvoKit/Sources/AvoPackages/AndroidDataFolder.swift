import AvoKit
import Foundation

/// `avo-data.json`: what a folder of Android's data is, so another Mac (or
/// this one, after the drive was away) recognises and checks it before use.
///
/// The folder (`Avo Android Data`, AvoPaths.portableDataItems) holds the
/// data disk and the disks bound to it; Avo's settings, apps list, key
/// mappings and Android images stay with each Mac.
public struct AndroidDataManifest: Codable, Equatable, Sendable {
    public static let formatName = "avo-android-data"
    /// Readers refuse a higher version: a newer Avo changed what the folder holds.
    public static let formatVersion = 1

    public var format: String
    public var formatVersion: Int
    /// The folder's own id: the location record names it, so another
    /// folder of the same name is never taken for this one.
    public var id: UUID
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// The Mac that used it last (its name in System Settings › General › Sharing).
    public var lastMac: String?
    /// The newest Android that used the data (as android-data.json).
    public var android: AndroidRelease?
    public var build: String?
    /// The data disk's size, and whether Android created its storage on it.
    public var diskBytes: Int64?
    public var storageCreated: Bool
    /// Google apps are in this Android (Settings › Google Apps).
    public var googleApps: Bool?
    public var avoVersion: String?

    public init(id: UUID = UUID(), createdAt: Date = Date(), lastUsedAt: Date? = nil, lastMac: String? = nil,
                android: AndroidRelease? = nil, build: String? = nil, diskBytes: Int64? = nil, storageCreated: Bool = false,
                googleApps: Bool? = nil, avoVersion: String? = nil) {
        format = Self.formatName
        formatVersion = Self.formatVersion
        self.id = id
        self.createdAt = Self.wholeSeconds(createdAt)
        self.lastUsedAt = lastUsedAt.map(Self.wholeSeconds)
        self.lastMac = lastMac
        self.android = android
        self.build = build
        self.diskBytes = diskBytes
        self.storageCreated = storageCreated
        self.googleApps = googleApps
        self.avoVersion = avoVersion
    }

    public static func wholeSeconds(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    public enum ReadError: Error, Equatable {
        case missing
        case unreadable
        case notPermitted
        /// Another format, or a version this Avo does not read.
        case unknownFormat(version: Int)
    }

    public static func load(from folder: URL) throws(ReadError) -> AndroidDataManifest {
        let url = folder.appending(path: AvoPaths.dataManifestName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let code = (error as NSError).code
            let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if posix == Int(EPERM) || code == NSFileReadNoPermissionError { throw .notPermitted }
            throw FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        struct Head: Decodable { var format: String?; var formatVersion: Int? }
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { throw .unreadable }
        guard head.format == formatName, let version = head.formatVersion else { throw .unknownFormat(version: head.formatVersion ?? 0) }
        guard version <= formatVersion else { throw .unknownFormat(version: version) }
        guard let manifest = try? JSONDecoder.avoImages.decode(AndroidDataManifest.self, from: data) else { throw .unreadable }
        return manifest
    }

    public func write(to folder: URL) throws {
        try JSONEncoder.avoImages.encode(self).write(to: folder.appending(path: AvoPaths.dataManifestName), options: .atomic)
    }
}

/// A folder of Android's data: Avo's own storage (vm/) or one elsewhere.
public struct AndroidDataFolder: Sendable {
    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    public var dataDisk: URL { url.appending(path: "userdata.img") }
    public var disks: URL { url.appending(path: "cuttlefish", directoryHint: .isDirectory) }
    /// The disk that holds the key to Android's encrypted data.
    public var metadataDisk: URL { disks.appending(path: "metadata.img") }

    /// Android's data is here (a data disk, or a manifest Avo wrote).
    public var holdsData: Bool {
        FileManager.default.fileExists(atPath: dataDisk.path)
            || FileManager.default.fileExists(atPath: url.appending(path: AvoPaths.dataManifestName).path)
    }

    /// The portable items that are here, relative to the folder.
    public func presentItems() -> [String] {
        AvoPaths.portableDataItems.filter { FileManager.default.fileExists(atPath: url.appending(path: $0).path) }
    }

    /// `android-data.json`.
    public func dataRecord() -> AndroidDataRecord? {
        (try? Data(contentsOf: url.appending(path: "android-data.json")))
            .flatMap { try? JSONDecoder.avoImages.decode(AndroidDataRecord.self, from: $0) }
    }

    /// The newest Android that used the data: android-data.json, else the manifest.
    public func newestAndroid(manifest: AndroidDataManifest?) -> (release: AndroidRelease, build: String?)? {
        if let record = dataRecord() { return (record.release, record.build) }
        return manifest?.android.map { ($0, manifest?.build) }
    }

    /// Android wrote its storage on the data disk. Without sparse files (exFAT,
    /// Mac OS Extended) a new disk has all its blocks at once, so there it is
    /// what is at the start of the disk that tells (Android's file system).
    public static func isWritten(_ disk: URL) -> Bool {
        var info = stat()
        guard stat(disk.path, &info) == 0, info.st_blocks > 0 else { return false }
        guard pathconf(disk.path, _PC_MIN_HOLE_SIZE) <= 0 else { return true }
        guard let handle = try? FileHandle(forReadingFrom: disk) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1 << 20)) ?? Data()
        return head.contains { $0 != 0 }
    }

    /// Bytes the folder's items take on their volume, and their sizes.
    public func usage() -> (allocated: Int64, logical: Int64) {
        var allocated: Int64 = 0
        var logical: Int64 = 0
        for item in presentItems() {
            var info = stat()
            guard stat(url.appending(path: item).path, &info) == 0 else { continue }
            allocated += Int64(info.st_blocks) * 512
            logical += Int64(info.st_size)
        }
        return (allocated, logical)
    }

    /// What the folder says about itself, for Settings › Storage.
    public func summary(manifest: AndroidDataManifest?) -> AndroidDataSummary {
        var info = stat()
        let disk = stat(dataDisk.path, &info) == 0 ? Int64(info.st_size) : (manifest?.diskBytes ?? 0)
        let newest = newestAndroid(manifest: manifest)
        let exists = FileManager.default.fileExists(atPath: dataDisk.path)
        return AndroidDataSummary(id: manifest?.id, android: newest?.release.name, sdk: newest?.release.sdk, build: newest?.build,
                                  diskBytes: disk, allocatedBytes: usage().allocated,
                                  created: exists ? Self.isWritten(dataDisk) : (manifest?.storageCreated ?? false),
                                  createdAt: manifest?.createdAt, lastUsedAt: manifest?.lastUsedAt, lastMac: manifest?.lastMac,
                                  googleApps: manifest?.googleApps)
    }

    /// Why this Mac cannot use the data (nil: it can): a format it does not
    /// read, files that belong to it gone, or an Android newer than every
    /// image here (`images`, newest first).
    public func problem(images: [AndroidImageSummary]) -> StorageProblem? {
        let manifest: AndroidDataManifest?
        do {
            manifest = try AndroidDataManifest.load(from: url)
        } catch .unknownFormat(let version) {
            return .unknownFormat(path: url.path, version: version)
        } catch .notPermitted {
            return .notPermitted(path: url.path)
        } catch {
            manifest = nil
        }
        let created = FileManager.default.fileExists(atPath: dataDisk.path) ? Self.isWritten(dataDisk) : (manifest?.storageCreated ?? false)
        if created {
            // The data disk is encrypted with a key on the metadata disk:
            // without it (or without the disk itself) Android cannot read its data.
            let missing = ["userdata.img", "cuttlefish/metadata.img"].filter { !FileManager.default.fileExists(atPath: url.appending(path: $0).path) }
            if !missing.isEmpty { return .incomplete(path: url.path, missing: missing) }
        }
        if created, let newest = newestAndroid(manifest: manifest) {
            return Self.newerAndroidProblem(data: newest.release, build: newest.build, images: images, starting: nil)
        }
        return nil
    }

    /// Data from `data` refused for this Mac's images (newest first), or for
    /// the one Android `starting` with: Android cannot use data from a newer
    /// version (`AndroidRelease.isOlder`).
    public static func newerAndroidProblem(data: AndroidRelease, build: String?, images: [AndroidImageSummary],
                                           starting: AndroidImageSummary?) -> StorageProblem? {
        let fits = images.contains { $0.release.map { !$0.isOlder(than: data) } ?? false }
        if let starting {
            guard let release = starting.release, release.isOlder(than: data) else { return nil }
        } else if fits || images.isEmpty {
            return nil
        }
        let newest = images.compactMap(\.release).sorted { $1.isOlder(than: $0) }.first
        return .newerAndroid(data: data.name, build: build, newestHere: newest?.name, installed: fits)
    }
}

extension AndroidImageStore {
    /// Refuses to start `image` on data from a newer Android (data carried
    /// from a Mac with a newer Android, or another image chosen meanwhile).
    public func newerDataProblem(starting image: AndroidImageSummary, override: String?) -> StorageProblem? {
        guard let record = dataRecord() else { return nil }
        return AndroidDataFolder.newerAndroidProblem(data: record.release, build: record.build, images: installed(override: override),
                                                     starting: image)
    }
}
