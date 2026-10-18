import AvoKit
import Foundation
import Testing
@testable import AvoPackages

/// Against Google's real Android Build API, only when asked:
///
///     AVO_LIVE_BUILD_API=1 swift test --filter AndroidImageLiveTests
///
/// `AVO_IMPORT_IMAGE=<folder or zip>` also imports that image into a
/// scratch folder (the original is only read).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AVO_LIVE_BUILD_API"] == "1"))
struct AndroidImageLiveTests {
    @Test func listsTheBuildsAvoOffers() async throws {
        let folder = try scratchFolder("live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = AndroidImageCatalog(source: .standard, cacheFile: folder.appending(path: "builds.json"))
        let started = Date()
        let offers = try await catalog.offers()
        print("catalog (\(String(format: "%.1f", Date().timeIntervalSince(started))) s):")
        for offer in offers {
            print("  \(offer.release.name) (API \(offer.release.sdkFull ?? "\(offer.release.sdk)"), patch \(offer.release.securityPatch ?? "?"))"
                  + " build \(offer.build) \(offer.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "") \(offer.downloadSize) bytes \(offer.md5)")
        }
        #expect(!offers.isEmpty)
        #expect(offers.allSatisfy { $0.release.sdk >= 36 && $0.downloadSize > 100 << 20 && $0.md5.count == 32 })
        // The second listing comes from the version cache.
        let again = Date()
        #expect(try await catalog.offers() == offers)
        print("again: \(String(format: "%.1f", Date().timeIntervalSince(again))) s")
    }

    @Test func downloadsASmallArtifactAndReadsTheImageZipsDirectory() async throws {
        let client = AndroidBuildClient(source: .standard)
        let build = try #require(try await client.builds(branch: "aosp-android-latest-release", limit: 1).first?.buildId)
        // A whole small artifact, through the same downloader images use, checked against the API's MD5.
        let artifact = try #require(try await client.artifact("android-info.txt", build: build))
        let folder = try scratchFolder("live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "android-info.txt.partial")
        let link = try await client.signedURL("android-info.txt", build: build)
        let result = try await RangeDownloader().download(link, to: file, entityTag: nil) { _, _ in }
        #expect(result.size == artifact.size)
        #expect(try Checksum.md5(of: file) == artifact.md5)
        print("android-info.txt of \(build): \(result.size) bytes, ETag \(result.entityTag ?? "-"), MD5 matches")

        // build.prop: half of it, then the rest with a range request.
        let props = try #require(try await client.artifact("build.prop", build: build))
        let propsFile = folder.appending(path: "build.prop.partial")
        let propsLink = try await client.signedURL("build.prop", build: build)
        let head = try await client.range(propsLink, 0...(props.size / 2 - 1))
        try head.write(to: propsFile)
        let rest = try await RangeDownloader().download(propsLink, to: propsFile, entityTag: "\"\(props.md5 ?? "")\"") { _, _ in }
        #expect(rest.size == props.size)
        #expect(try Checksum.md5(of: propsFile) == props.md5)
        print("build.prop resumed at \(head.count) of \(props.size) bytes, MD5 matches")

        // The image zip's directory from its last 64 KiB: what a download unpacks to.
        let source = AndroidBuildSource.standard
        let zip = try #require(try await client.artifact(source.imageArtifact(build: build), build: build))
        let zipLink = try await client.signedURL(zip.name, build: build)
        let tail = try await client.range(zipLink, (zip.size - 65_557)...(zip.size - 1))
        let entries = try ZipArchive.entries(tail: tail, archiveSize: UInt64(zip.size))
        print("\(zip.name): \(zip.size) bytes, unpacks to \(entries.reduce(0) { $0 + $1.uncompressedSize }) bytes in \(entries.count) files")
        #expect(Set(CuttlefishImageFiles.required).isSubset(of: Set(entries.map(\.path))))
    }

    /// `AVO_LIVE_FULL_DOWNLOAD=1`: the whole newest image (about 1.1 GB), paused
    /// after 150 MB and resumed, checked, unpacked and installed into a
    /// scratch folder that is removed afterwards.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVO_LIVE_FULL_DOWNLOAD"] == "1"))
    func downloadsARealImageWithAPause() async throws {
        let paths = try scratchPaths()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let catalog = AndroidImageCatalog(source: .standard, cacheFile: paths.home.appending(path: "builds.json"))
        let offer = try #require(try await catalog.offers().first)
        let installer = AndroidImageInstaller(store: AndroidImageStore(paths: paths), client: AndroidBuildClient(source: .standard))
        let started = Date()
        let paused = CancelFlag()
        let first = Task {
            try await installer.download(offer) { event in
                if case .progress(let progress) = event, progress.received > 150 << 20 { paused.set() }
            }
        }
        while !paused.isSet { try await Task.sleep(for: .milliseconds(50)) }
        first.cancel()
        _ = await first.result
        let kept = installer.downloadedBytes(offer)
        print("paused at \(kept) bytes after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        #expect(kept >= 150 << 20 && kept < offer.downloadSize)
        let log = EventLog()
        let image = try await installer.download(offer) { log.add($0) }
        let seconds = Date().timeIntervalSince(started)
        let firstReport = log.all.compactMap { event -> Int64? in if case .progress(let p) = event { return p.received } else { return nil } }.first
        print("resumed from \(firstReport ?? -1) bytes; installed \(image.name) build \(image.build ?? "?") in \(String(format: "%.0f", seconds)) s at \(image.path)")
        #expect((firstReport ?? 0) >= kept)
        let manifest = try CuttlefishImageManifest.load(from: image.directory)
        print("manifest: \(manifest.id), \(manifest.files.count) files, origin \(manifest.origin)")
        #expect(manifest.files.first { $0.name == "super.img" }?.size ?? 0 > 1 << 30)
        try installer.store.verify(image)
        #expect(try FileManager.default.contentsOfDirectory(atPath: installer.store.downloads.path).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AVO_IMPORT_IMAGE"] != nil))
    func importsARealImage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["AVO_IMPORT_IMAGE"])
        let paths = try scratchPaths()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = AndroidImageInstaller(store: AndroidImageStore(paths: paths), client: AndroidBuildClient(source: .standard))
        let candidate = try installer.inspect(URL(filePath: path))
        print("candidate: \(candidate.identity.release.name) build \(candidate.identity.build), \(candidate.identity.fingerprint), \(candidate.size) bytes")
        let started = Date()
        let image = try await installer.importImage(candidate) { _ in }
        print("imported in \(String(format: "%.1f", Date().timeIntervalSince(started))) s to \(image.path)")
        let verifyStart = Date()
        try installer.store.verify(image)
        print("verified (cached identities) in \(String(format: "%.2f", Date().timeIntervalSince(verifyStart))) s")
        let manifest = try String(contentsOf: image.directory.appending(path: "manifest.json"), encoding: .utf8)
        print(manifest)
        #expect(image.release?.sdk ?? 0 >= 36)
    }
}
