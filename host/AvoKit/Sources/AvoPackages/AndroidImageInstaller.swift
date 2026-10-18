import AvoKit
import CryptoKit
import Foundation

/// A file or folder on this Mac that holds an Android image, checked
/// ("Use an Image on This Mac…").
public struct AndroidImageCandidate: Equatable, Sendable {
    public enum Layout: Equatable, Sendable {
        /// `<product>-img-<build>.zip`.
        case zip(URL)
        /// A folder with the `.img` files.
        case folder(URL)
    }

    /// What the user chose.
    public var source: URL
    public var layout: Layout
    public var identity: CuttlefishImageIdentity
    /// Bytes of the image files (unpacked).
    public var size: Int64
    /// The same build, already installed.
    public var installed: AndroidImageSummary?

    public var name: String { source.lastPathComponent }
}

/// Downloads and imports Android images into an `AndroidImageStore`.
public struct AndroidImageInstaller: Sendable {
    public let store: AndroidImageStore
    public let client: AndroidBuildClient
    let downloads: URLSessionConfiguration
    /// Free bytes on the volume of a folder (tests pretend).
    let freeSpace: @Sendable (URL) -> Int64?
    /// Kept free beyond what an image needs.
    static let margin: Int64 = 512 << 20

    public init(store: AndroidImageStore, client: AndroidBuildClient,
                downloads: URLSessionConfiguration = RangeDownloader.defaultConfiguration,
                freeSpace: @escaping @Sendable (URL) -> Int64? = AndroidImageInstaller.freeSpace(at:)) {
        self.store = store
        self.client = client
        self.downloads = downloads
        self.freeSpace = freeSpace
    }

    public typealias Report = @Sendable (AndroidImageJob.Event) -> Void

    // MARK: Downloading

    struct PartialDownload: Codable, Equatable {
        var md5: String
        var size: Int64
        var entityTag: String?
    }

    func partialFile(_ offer: AndroidImageOffer) -> URL { store.downloads.appending(path: offer.artifact + ".partial") }
    func partialInfo(_ offer: AndroidImageOffer) -> URL { store.downloads.appending(path: offer.artifact + ".json") }

    static func loadInfo(_ url: URL) -> PartialDownload? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PartialDownload.self, from: $0) }
    }

    static func saveInfo(_ info: PartialDownload, to url: URL) {
        try? JSONEncoder().encode(info).write(to: url, options: .atomic)
    }

    /// Bytes of `offer` downloaded so far (for Resume).
    public func downloadedBytes(_ offer: AndroidImageOffer) -> Int64 {
        Self.size(of: partialFile(offer)) ?? 0
    }

    /// Downloads `offer`, continuing an earlier partial download, checks it
    /// against the API's MD5, unpacks it and installs it. Cancelling the
    /// calling task keeps what was downloaded (`discardDownload` removes it).
    public func download(_ offer: AndroidImageOffer, report: @escaping Report) async throws -> AndroidImageSummary {
        report(.preparing)
        if let existing = store.managed().first(where: { $0.build == offer.build && $0.release?.version == offer.release.version }),
           (try? store.verify(existing)) != nil {
            return existing
        }
        let partial = partialFile(offer)
        let infoFile = partialInfo(offer)
        try FileManager.default.createDirectory(at: store.downloads, withIntermediateDirectories: true)
        let fresh = PartialDownload(md5: offer.md5, size: offer.downloadSize, entityTag: nil)
        let info = Self.loadInfo(infoFile)
        if info?.md5 != fresh.md5 || info?.size != fresh.size {
            // Another file than the one half downloaded: start over.
            try? FileManager.default.removeItem(at: partial)
            Self.saveInfo(fresh, to: infoFile)
        }

        let have = Self.size(of: partial) ?? 0
        var link = try await client.signedURL(offer.artifact, build: offer.build)
        let unpacked = await unpackedSize(of: offer, at: link)
        try checkSpace(needed: max(offer.downloadSize - have, 0) + unpacked.total + unpacked.superImage + Self.margin, for: store.root)

        if have < offer.downloadSize {
            let meter = DownloadMeter(total: offer.downloadSize)
            var renewals = 0
            while true {
                do {
                    let result = try await RangeDownloader(configuration: downloads).download(
                        link, to: partial, entityTag: Self.loadInfo(infoFile)?.entityTag,
                        onResponse: { tag in
                            // Kept at once, so Resume after Pause can say which bytes it has.
                            var info = fresh
                            info.entityTag = tag
                            Self.saveInfo(info, to: infoFile)
                        },
                        progress: { received, _ in
                            if let progress = meter.update(received) { report(.progress(progress)) }
                        })
                    if result.size != offer.downloadSize {
                        throw AndroidImageError.checksumMismatch(offer.artifact)
                    }
                    break
                } catch RangeDownloader.Failure.expired where renewals < 3 {
                    // The signed link lasts minutes: a new one continues the download.
                    renewals += 1
                    link = try await client.signedURL(offer.artifact, build: offer.build)
                } catch RangeDownloader.Failure.status(416) where (Self.size(of: partial) ?? 0) == offer.downloadSize {
                    break
                } catch RangeDownloader.Failure.status(let status) {
                    throw AndroidImageError.api(status: status, message: nil)
                }
            }
        }

        report(.verifying(0))
        let md5 = try await Self.offload { _ in try Checksum.md5(of: partial) { report(.verifying($0)) } }
        guard md5 == offer.md5.lowercased() else {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: infoFile)
            throw AndroidImageError.checksumMismatch(offer.artifact)
        }
        let summary = try await installZip(partial, origin: .androidBuild(branch: offer.branch, target: offer.target, build: offer.build,
                                                                          artifact: offer.artifact, md5: offer.md5),
                                           expected: (offer.build, offer.release), report: report)
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: infoFile)
        return summary
    }

    /// Removes what a stopped download left.
    public func discardDownload(_ offer: AndroidImageOffer) {
        try? FileManager.default.removeItem(at: partialFile(offer))
        try? FileManager.default.removeItem(at: partialInfo(offer))
    }

    /// What the zip unpacks to, from its directory (a range request for its
    /// last 64 KiB); an estimate when the server does not say.
    func unpackedSize(of offer: AndroidImageOffer, at link: URL) async -> (total: Int64, superImage: Int64) {
        let estimate = (offer.downloadSize * 2, offer.downloadSize * 3 / 2)
        let length = min(offer.downloadSize, 65_557)
        guard length > 22,
              let tail = try? await client.range(link, (offer.downloadSize - length)...(offer.downloadSize - 1)),
              let entries = try? ZipArchive.entries(tail: tail, archiveSize: UInt64(offer.downloadSize)) else { return estimate }
        let total = entries.reduce(Int64(0)) { $0 + Int64(clamping: $1.uncompressedSize) }
        let superImage = entries.first { $0.path == "super.img" }.map { Int64(clamping: $0.uncompressedSize) } ?? estimate.1
        return (total, superImage)
    }

    func checkSpace(needed: Int64, for folder: URL) throws {
        guard let free = freeSpace(folder), free < needed else { return }
        throw AndroidImageError.notEnoughSpace(needed: needed, available: free)
    }

    public static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe = probe.deletingLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Importing

    /// Checks a file or folder the user chose: an image zip, a folder with
    /// the `.img` files, the build folder scripts/fetch-cuttlefish.sh makes
    /// (with `img/` or the zip), or another Avo's image folder.
    public func inspect(_ url: URL, minimumSDK: Int = AndroidBuildSource.standard.minimumSDK) throws -> AndroidImageCandidate {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw AndroidImageError.notAnImage(String(localized: "Avo can’t find \(url.lastPathComponent).", bundle: .avoKit))
        }
        let layout: AndroidImageCandidate.Layout
        if isFolder.boolValue {
            let inner = url.appending(path: "img", directoryHint: .isDirectory)
            let zips = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "zip" && $0.lastPathComponent.contains("-img-") }
            if CuttlefishImageFiles.isImage(url) {
                layout = .folder(url)
            } else if CuttlefishImageFiles.isImage(inner) {
                layout = .folder(inner)
            } else if zips.count == 1 {
                layout = .zip(zips[0])
            } else {
                throw AndroidImageError.notAnImage(String(localized: "There’s no Android image in this folder. Avo looks for boot.img, init_boot.img, vendor_boot.img, super.img and vbmeta.img.",
                                                          bundle: .avoKit))
            }
        } else if url.pathExtension.lowercased() == "zip" {
            layout = .zip(url)
        } else {
            throw AndroidImageError.notAnImage(String(localized: "Choose an Android image zip (\(AndroidBuildSource.standard.imageArtifact(build: "…"))) or the folder with its .img files.",
                                                      bundle: .avoKit))
        }

        let identity: CuttlefishImageIdentity
        let size: Int64
        switch layout {
        case .folder(let folder):
            for name in CuttlefishImageFiles.required where !ImageFileMagic.check(folder.appending(path: name)) {
                throw AndroidImageError.notAnImage(String(localized: "\(name) doesn’t look like part of an Android image.", bundle: .avoKit))
            }
            identity = try AndroidImageStore.identity(of: folder)
            size = CuttlefishImageFiles.all.reduce(Int64(0)) { $0 + (Self.size(of: folder.appending(path: $1)) ?? 0) }
        case .zip(let zip):
            let archive: ZipArchive
            do {
                archive = try ZipArchive(url: zip)
            } catch {
                throw AndroidImageError.notAnImage(String(localized: "The zip is damaged, or it isn’t an Android image zip.", bundle: .avoKit))
            }
            let missing = CuttlefishImageFiles.required.filter { archive.entry($0) == nil }
            guard missing.isEmpty else {
                throw AndroidImageError.notAnImage(String(localized: "The zip has no \(missing.joined(separator: ", ")), so it isn’t an Android image Avo can use.",
                                                          bundle: .avoKit))
            }
            let vbmeta = ["vbmeta.img", "vbmeta_system.img"].compactMap { try? archive.data(at: $0, limit: 1 << 20) }
            identity = try CuttlefishImageIdentity.read(vbmeta: vbmeta, bootHeader: nil)
            size = archive.entries.filter { CuttlefishImageFiles.all.contains($0.path) }
                .reduce(Int64(0)) { $0 + Int64(clamping: $1.uncompressedSize) }
        }
        if let problem = identity.problem(minimumSDK: minimumSDK) { throw AndroidImageError.notAnImage(problem) }
        let installed = store.managed().first { $0.build == identity.build && $0.release?.version == identity.release.version }
        return AndroidImageCandidate(source: url, layout: layout, identity: identity, size: size, installed: installed)
    }

    /// Installs a checked candidate: an APFS clone of a folder's files (a
    /// copy on another volume), or the zip unpacked. The original stays.
    public func importImage(_ candidate: AndroidImageCandidate, report: @escaping Report) async throws -> AndroidImageSummary {
        report(.preparing)
        if let installed = candidate.installed, (try? store.verify(installed)) != nil { return installed }
        let origin = AndroidImageOrigin.imported(name: candidate.name)
        let expected = (candidate.identity.build, candidate.identity.release)
        switch candidate.layout {
        case .zip(let zip):
            try checkSpace(needed: candidate.size + Self.margin, for: store.root)
            return try await installZip(zip, origin: origin, expected: expected, report: report)
        case .folder(let folder):
            // Clones take no space; a copy from another volume does.
            if Self.volume(of: folder) != Self.volume(of: store.root) { try checkSpace(needed: candidate.size + Self.margin, for: store.root) }
            return try await installFolder(folder, origin: origin, expected: expected, report: report)
        }
    }

    // MARK: Installing

    /// Unpacks the image files of a zip (nothing else in it), taking their
    /// SHA-256 as they are written.
    func installZip(_ zip: URL, origin: AndroidImageOrigin, expected: (build: String, release: AndroidRelease),
                    report: @escaping Report) async throws -> AndroidImageSummary {
        report(.unpacking(0))
        let staging = try makeStaging()
        do {
            let files = try await Self.offload { cancelled in
                let archive = try ZipArchive(url: zip)
                // The image files only, each once (the first entry of a name).
                let entries = CuttlefishImageFiles.all.compactMap { archive.entry($0) }
                let total = max(entries.reduce(0.0) { $0 + Double($1.uncompressedSize) }, 1)
                var done = 0.0
                var reported = 0.0
                var files: [CuttlefishImageManifest.File] = []
                for entry in entries {
                    let url = staging.appending(path: entry.path)
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw AndroidImageError.io(String(localized: "Can’t create \(entry.path).", bundle: .avoKit))
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    var hasher = SHA256()
                    do {
                        try archive.stream(entry, chunkSize: 4 << 20) { chunk in
                            if cancelled() { throw CancellationError() }
                            hasher.update(data: chunk)
                            try handle.write(contentsOf: chunk)
                            done += Double(chunk.count)
                            if done / total - reported >= 0.005 {
                                reported = done / total
                                report(.unpacking(reported))
                            }
                        }
                        try handle.close()
                    } catch let error as PackageError {
                        try? handle.close()
                        throw AndroidImageError.notAnImage(error.localizedDescription)
                    } catch {
                        try? handle.close()
                        throw error
                    }
                    files.append(.init(name: entry.path, sha256: Self.hex(hasher.finalize()), size: Int64(clamping: entry.uncompressedSize)))
                }
                return files
            }
            report(.finishing)
            return try finish(staging, files: files, origin: origin, expected: expected)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Clones (or copies) the image files of a folder, then takes their SHA-256.
    func installFolder(_ folder: URL, origin: AndroidImageOrigin, expected: (build: String, release: AndroidRelease),
                       report: @escaping Report) async throws -> AndroidImageSummary {
        report(.unpacking(0))
        let staging = try makeStaging()
        do {
            let files = try await Self.offload { cancelled in
                let names = CuttlefishImageFiles.all.filter { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
                for name in names {
                    if cancelled() { throw CancellationError() }
                    // copyItem clones on APFS (the files stay shared until changed).
                    try FileManager.default.copyItem(at: folder.appending(path: name), to: staging.appending(path: name))
                }
                let total = max(names.reduce(0.0) { $0 + Double(Self.size(of: staging.appending(path: $1)) ?? 0) }, 1)
                var done = 0.0
                var reported = 0.0
                return try names.map { name -> CuttlefishImageManifest.File in
                    let url = staging.appending(path: name)
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    var size: Int64 = 0
                    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                        if cancelled() { throw CancellationError() }
                        hasher.update(data: chunk)
                        size += Int64(chunk.count)
                        done += Double(chunk.count)
                        if done / total - reported >= 0.005 {
                            reported = done / total
                            report(.unpacking(reported))
                        }
                    }
                    return .init(name: name, sha256: Self.hex(hasher.finalize()), size: size)
                }
            }
            report(.finishing)
            return try finish(staging, files: files, origin: origin, expected: expected)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func makeStaging() throws -> URL {
        let staging = store.root.appending(path: AndroidImageStore.stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Checks the unpacked files, writes the manifest (and the identities it
    /// just checked) and moves the image into place.
    func finish(_ staging: URL, files: [CuttlefishImageManifest.File], origin: AndroidImageOrigin,
                expected: (build: String, release: AndroidRelease)) throws -> AndroidImageSummary {
        for name in CuttlefishImageFiles.required where !ImageFileMagic.check(staging.appending(path: name)) {
            throw AndroidImageError.notAnImage(String(localized: "\(name) doesn’t look like part of an Android image.", bundle: .avoKit))
        }
        let identity = try AndroidImageStore.identity(of: staging)
        guard identity.build == expected.build, identity.release.version == expected.release.version else {
            throw AndroidImageError.notAnImage(String(localized: "The files are Android \(identity.release.version) build \(identity.build), not the build Avo expected (\(expected.build)).",
                                                      bundle: .avoKit))
        }
        // The catalog's release (from build.prop) knows the exact API level.
        let release = expected.release.sdkFull != nil ? expected.release : identity.release
        let id = AndroidImageStore.folderName(release: release, build: identity.build)
        let manifest = CuttlefishImageManifest(id: id, release: release, build: identity.build, fingerprint: identity.fingerprint,
                                               origin: origin, files: files)
        try manifest.write(to: staging)
        var stamps = VerifiedFiles()
        for file in files {
            if let identity = FileIdentity(staging.appending(path: file.name)) {
                stamps.files[file.name] = VerifiedFiles.Stamp(identity: identity, sha256: file.sha256)
            }
        }
        stamps.save(staging)

        let destination = store.root.appending(path: id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            if let existing = store.summary(of: destination), existing.isManaged, (try? store.verify(existing)) != nil {
                try? FileManager.default.removeItem(at: staging)
                return existing
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return store.summary(of: destination) ?? AndroidImageStore.summary(manifest, at: destination)
    }

    // MARK: Helpers

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    static func volume(of url: URL) -> URL? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe = probe.deletingLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Runs long file work on a thread of its own instead of Swift's
    /// cooperative pool; the work sees the calling task's cancellation.
    static func offload<T: Sendable>(_ work: @escaping @Sendable (_ cancelled: @escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try work { flag.isSet } })
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Turns byte counts into progress reports a few times a second, with speed.
final class DownloadMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private var rate = TransferRate()
    private var lastReport = -1.0
    private let start = Date()

    init(total: Int64) {
        self.total = total
    }

    func update(_ received: Int64) -> DownloadProgress? {
        lock.withLock {
            let now = Date().timeIntervalSince(start)
            rate.add(bytes: received, at: now)
            guard now - lastReport >= 0.25 || received >= total else { return nil }
            lastReport = now
            return DownloadProgress(received: received, total: total, bytesPerSecond: rate.bytesPerSecond)
        }
    }
}
