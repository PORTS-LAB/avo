import AvoKit
import Foundation
import Testing
@testable import AvoPackages

@Suite struct CuttlefishImageIdentityTests {
    @Test func readsTheBuildFromVBMetaProperties() throws {
        let image = SyntheticImage()
        let files = image.files
        let identity = try CuttlefishImageIdentity.read(vbmeta: [try #require(files["vbmeta.img"]), try #require(files["vbmeta_system.img"])],
                                                        bootHeader: files["init_boot.img"])
        #expect(identity.build == "16373615")
        #expect(identity.release == AndroidRelease(version: "17", sdk: 37, securityPatch: "2026-06-05", buildTag: "CP2A.260605.016"))
        #expect(identity.product == "aosp_cf_arm64_only_phone")
        #expect(identity.device == "vsoc_arm64_only")
        #expect(identity.variant == "userdebug")
        #expect(identity.problem(minimumSDK: 36) == nil)
    }

    @Test func readsTheBootHeader() throws {
        let header = try #require(BootImageHeader(SyntheticImage.bootImage(version: "17", patch: "2026-06")))
        #expect(header.headerVersion == 4)
        #expect(header.osVersion == "17.0.0")
        #expect(header.securityPatch == "2026-06")
        #expect(BootImageHeader(Data("VNDRBOOT".utf8) + Data(count: 64)) == nil)
    }

    @Test func parsesAVBProperties() throws {
        let image = SyntheticImage.vbmeta([("a", "1"), ("com.android.build.system.os_version", "17")])
        let properties = try AVBProperties.parse(image)
        #expect(properties.map(\.0) == ["a", "com.android.build.system.os_version"])
        #expect(properties.map(\.1) == ["1", "17"])
        #expect(throws: (any Error).self) { try AVBProperties.parse(Data("AVB0".utf8)) }
        #expect(throws: (any Error).self) { try AVBProperties.parse(Data(count: 512)) }
    }

    @Test func saysWhyAnImageWillNotDo() throws {
        func problem(_ change: (inout SyntheticImage) -> Void) throws -> String? {
            var image = SyntheticImage()
            change(&image)
            let files = image.files
            return try CuttlefishImageIdentity.read(vbmeta: [try #require(files["vbmeta.img"])], bootHeader: nil).problem(minimumSDK: 36)
        }
        #expect(try problem { $0.device = "vsoc_x86_64_only" }?.contains("vsoc_x86_64_only") == true)
        #expect(try problem { $0.device = "oriole_arm64" }?.contains("Cuttlefish") == true)
        #expect(try problem { $0.variant = "user" }?.contains("userdebug") == true)
        #expect(try problem { $0.version = "15" }?.contains("Android 16") == true)
        #expect(try problem { $0.version = "16" } == nil)
    }

    @Test func refusesImagesWithoutABuildFingerprint() {
        #expect(throws: AndroidImageError.self) {
            try CuttlefishImageIdentity.read(vbmeta: [SyntheticImage.vbmeta([("x", "y")])], bootHeader: nil)
        }
    }
}

@Suite struct AndroidImageImportTests {
    func installer(_ paths: AvoPaths, freeSpace: Int64? = nil) -> AndroidImageInstaller {
        AndroidImageInstaller(store: AndroidImageStore(paths: paths), client: AndroidBuildClient(source: .standard),
                              freeSpace: { _ in freeSpace })
    }

    @Test func checksAFolderAZipAndFetchCuttlefishsLayout() throws {
        let paths = try scratchPaths()
        let source = try scratchFolder("source")
        defer { try? FileManager.default.removeItem(at: source) }
        let images = installer(paths)

        let folder = try SyntheticImage().write(to: source.appending(path: "img"))
        let direct = try images.inspect(folder)
        #expect(direct.layout == .folder(folder))
        #expect(direct.identity.build == "16373615")
        #expect(direct.size == SyntheticImage().files.values.reduce(0) { $0 + Int64($1.count) })

        // scripts/fetch-cuttlefish.sh's build folder: <build>/img and BUILD_ID.
        try Data("16373615\n".utf8).write(to: source.appending(path: "BUILD_ID"))
        #expect(layoutPath(try images.inspect(source).layout) == folder.resolvingSymlinksInPath().path)

        let zip = source.appending(path: "aosp_cf_arm64_only_phone-img-16373615.zip")
        try SyntheticImage().zip().write(to: zip)
        let zipped = try images.inspect(zip)
        #expect(zipped.layout == .zip(zip))
        #expect(zipped.identity == direct.identity)
        #expect(zipped.size == direct.size)

        // A build folder with only the zip.
        let onlyZip = try scratchFolder("zip-only")
        defer { try? FileManager.default.removeItem(at: onlyZip) }
        try SyntheticImage().zip().write(to: onlyZip.appending(path: "aosp_cf_arm64_only_phone-img-16373615.zip"))
        #expect(layoutPath(try images.inspect(onlyZip).layout)
                == onlyZip.appending(path: "aosp_cf_arm64_only_phone-img-16373615.zip").resolvingSymlinksInPath().path)
    }

    func layoutPath(_ layout: AndroidImageCandidate.Layout) -> String {
        switch layout {
        case .zip(let url), .folder(let url): url.resolvingSymlinksInPath().path
        }
    }

    @Test func refusesWhatIsNotAUsableImage() throws {
        let paths = try scratchPaths()
        let images = installer(paths)
        let source = try scratchFolder("source")
        defer { try? FileManager.default.removeItem(at: source) }

        #expect(throws: AndroidImageError.self) { try images.inspect(source.appending(path: "missing")) }
        #expect(throws: AndroidImageError.self) { try images.inspect(source) }
        let text = source.appending(path: "notes.txt")
        try Data("x".utf8).write(to: text)
        #expect(throws: AndroidImageError.self) { try images.inspect(text) }

        // A zip without super.img.
        let partial = source.appending(path: "partial-img-1.zip")
        try makeStoredZip(SyntheticImage().files.filter { $0.key != "super.img" }.map { ($0.key, $0.value) }).write(to: partial)
        #expect(throws: AndroidImageError.self) { try images.inspect(partial) }
        // Not a zip at all.
        let broken = source.appending(path: "broken-img-1.zip")
        try Data(repeating: 1, count: 100).write(to: broken)
        #expect(throws: AndroidImageError.self) { try images.inspect(broken) }

        // An x86 image, a user build and Android 15.
        for change in [{ (image: inout SyntheticImage) in image.device = "vsoc_x86_64" },
                       { (image: inout SyntheticImage) in image.variant = "user" },
                       { (image: inout SyntheticImage) in image.version = "15" }] {
            var image = SyntheticImage()
            change(&image)
            let folder = try image.write(to: source.appending(path: UUID().uuidString))
            #expect(throws: AndroidImageError.self) { try images.inspect(folder) }
        }
        // A damaged boot image.
        let damaged = try SyntheticImage().write(to: source.appending(path: "damaged"))
        try Data(repeating: 0, count: 64).write(to: damaged.appending(path: "boot.img"))
        #expect(throws: AndroidImageError.self) { try images.inspect(damaged) }
    }

    @Test func importsAFolderWithAManifest() async throws {
        let paths = try scratchPaths()
        let images = installer(paths)
        let store = images.store
        let folder = try SyntheticImage().write(to: try scratchFolder("source").appending(path: "img"))
        let candidate = try images.inspect(folder)
        let events = EventLog()
        let summary = try await images.importImage(candidate) { events.add($0) }

        #expect(summary.directory == store.root.appending(path: "android-17-16373615", directoryHint: .isDirectory).standardizedFileURL)
        #expect(summary.origin == .imported(name: "img"))
        #expect(summary.build == "16373615")
        #expect(summary.isManaged)
        let manifest = try CuttlefishImageManifest.load(from: summary.directory)
        #expect(manifest.schema == 2 && manifest.format == "cuttlefish" && manifest.trust == "local")
        #expect(manifest.id == "android-17-16373615")
        #expect(manifest.fingerprint.contains("vsoc_arm64_only:17"))
        #expect(Set(manifest.files.map(\.name)) == Set(SyntheticImage().files.keys))
        for file in manifest.files {
            let data = try #require(SyntheticImage().files[file.name])
            #expect(file.sha256 == sha256Hex(data))
            #expect(file.size == Int64(data.count))
        }
        // The original stays; nothing is left half-done.
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "super.img").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".staging") }.isEmpty)
        #expect(events.all.first == .preparing)
        #expect(events.all.contains(.finishing))
        // Checked when installed: verify needs no hashing and passes.
        try store.verify(summary)
        #expect(store.managed() == [summary])

        // The same build again is the installed one.
        let again = try images.inspect(folder)
        #expect(again.installed == summary)
        #expect(try await images.importImage(again) { _ in } == summary)
    }

    @Test func importsAZip() async throws {
        let paths = try scratchPaths()
        let images = installer(paths)
        var image = SyntheticImage()
        image.version = "16"
        image.build = "15581820"
        image.securityPatch = "2025-12-05"
        let source = try scratchFolder("source")
        let zip = source.appending(path: "aosp_cf_arm64_only_phone-img-15581820.zip")
        // Other entries of the zip, safe or not, are left out.
        try image.zip(extra: [("../evil.img", Data("x".utf8)), ("notes/readme.txt", Data("y".utf8))]).write(to: zip)
        let summary = try await images.importImage(try images.inspect(zip)) { _ in }
        #expect(summary.release?.version == "16")
        #expect(summary.release?.securityPatch == "2025-12-05")
        let names = try FileManager.default.contentsOfDirectory(atPath: summary.directory.path).sorted()
        #expect(names == (Array(image.files.keys) + ["manifest.json", ".verified.json"]).sorted())
        #expect(!FileManager.default.fileExists(atPath: paths.images.appending(path: "evil.img").path))
        #expect(!FileManager.default.fileExists(atPath: summary.directory.appending(path: "notes").path))
    }

    @Test func refusesToImportWithoutSpace() async throws {
        let paths = try scratchPaths()
        let images = installer(paths, freeSpace: 1000)
        let zip = try scratchFolder("source").appending(path: "a-img-1.zip")
        try SyntheticImage().zip().write(to: zip)
        let candidate = try images.inspect(zip)
        await #expect(throws: AndroidImageError.notEnoughSpace(needed: candidate.size + AndroidImageInstaller.margin, available: 1000)) {
            try await images.importImage(candidate) { _ in }
        }
    }

    @Test func verificationCatchesChangedFiles() async throws {
        let paths = try scratchPaths()
        let images = installer(paths)
        let summary = try await images.importImage(try images.inspect(try SyntheticImage().write(to: try scratchFolder("s").appending(path: "img")))) { _ in }
        let boot = summary.directory.appending(path: "boot.img")
        // Same size, other bytes (a new inode as well).
        var bytes = try Data(contentsOf: boot)
        bytes[5000] ^= 0xFF
        try FileManager.default.removeItem(at: boot)
        try bytes.write(to: boot)
        #expect(throws: AvoError.internalError("boot.img failed its checksum.")) { try images.store.verify(summary) }
        try Data("short".utf8).write(to: boot)
        #expect(throws: AvoError.internalError("boot.img has the wrong size.")) { try images.store.verify(summary) }
        try FileManager.default.removeItem(at: boot)
        #expect(throws: AvoError.self) { try images.store.verify(summary) }
    }

    @Test func finishRefusesAnotherBuildThanExpected() throws {
        let paths = try scratchPaths()
        let images = installer(paths)
        let staging = try images.makeStaging()
        try SyntheticImage().write(to: staging)
        #expect(throws: AndroidImageError.self) {
            try images.finish(staging, files: [], origin: .imported(name: "x"), expected: ("999", AndroidRelease(version: "17", sdk: 37)))
        }
    }
}

@Suite struct AndroidImageStoreTests {
    /// An installed (managed) image of `image` in `store`.
    func install(_ image: SyntheticImage, in paths: AvoPaths) async throws -> AndroidImageSummary {
        let installer = AndroidImageInstaller(store: AndroidImageStore(paths: paths), client: AndroidBuildClient(source: .standard),
                                              freeSpace: { _ in nil })
        let folder = try image.write(to: try scratchFolder("src").appending(path: "img"))
        return try await installer.importImage(try installer.inspect(folder)) { _ in }
    }

    func sixteen() -> SyntheticImage {
        var image = SyntheticImage()
        image.version = "16"
        image.build = "15581820"
        image.securityPatch = "2025-12-05"
        return image
    }

    @Test func choosesAndRemembersThePreviousImage() async throws {
        let paths = try scratchPaths()
        let store = AndroidImageStore(paths: paths)
        #expect(store.imageForBoot(override: nil) == nil)
        let older = try await install(sixteen(), in: paths)
        let newer = try await install(SyntheticImage(), in: paths)
        // Nothing chosen: the newest Android.
        #expect(store.imageForBoot(override: nil) == newer)
        try store.select(older)
        #expect(store.imageForBoot(override: nil) == older)
        #expect(store.selection().current == older.path)
        #expect(store.selection().previous == newer.path)
        try store.select(newer)
        #expect(store.selection().previous == older.path)
        #expect(store.previousImage() == older)
        // Choosing the current one again changes nothing.
        try store.select(newer)
        #expect(store.selection().previous == older.path)
        #expect(store.installed().map(\.build) == ["16373615", "15581820"])
    }

    @Test func removesOnlyImagesAvoInstalledAndNotTheCurrentOne() async throws {
        let paths = try scratchPaths()
        let store = AndroidImageStore(paths: paths)
        let older = try await install(sixteen(), in: paths)
        let newer = try await install(SyntheticImage(), in: paths)
        try store.select(older)
        try store.select(newer)
        #expect(throws: AndroidImageError.self) { try store.remove(newer) }
        try store.remove(older)
        #expect(store.previousImage() == nil)
        #expect(store.selection().previous == nil)
        let external = try #require(store.summary(of: try SyntheticImage().write(to: try scratchFolder("ext").appending(path: "img"))))
        #expect(!external.isManaged)
        #expect(throws: AndroidImageError.self) { try store.remove(external) }
    }

    @Test func findsImagesFetchCuttlefishDownloaded() throws {
        let paths = try scratchPaths()
        let store = AndroidImageStore(paths: paths)
        let build = paths.home.appending(path: "Library/Caches/Avo/cuttlefish/16373615", directoryHint: .isDirectory)
        try SyntheticImage().write(to: build.appending(path: "img"))
        try Data("16373615\n".utf8).write(to: build.appending(path: "BUILD_ID"))
        var older = SyntheticImage()
        older.build = "16102939"
        try older.write(to: paths.home.appending(path: "Library/Caches/Avo/cuttlefish/16102939/img"))
        let found = store.external(override: nil)
        #expect(found.map(\.build) == ["16373615", "16102939"])
        #expect(found.first?.origin == .external)
        #expect(found.first?.release?.version == "17")
        #expect(store.imageForBoot(override: nil)?.build == "16373615")
        // The developer setting wins over everything.
        let override = try SyntheticImage().write(to: try scratchFolder("override"))
        #expect(store.imageForBoot(override: override.path)?.path == override.standardizedFileURL.path)
        // images/cuttlefish wins over the downloads.
        try older.write(to: paths.images.appending(path: "cuttlefish"))
        #expect(store.imageForBoot(override: nil)?.build == "16102939")
    }

    @Test func aStartWithAnotherImageReplacesTheInstancesCopies() async throws {
        let paths = try scratchPaths()
        let store = AndroidImageStore(paths: paths)
        let older = try await install(sixteen(), in: paths)
        let newer = try await install(SyntheticImage(), in: paths)
        let instance = store.instance
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        func makeCopies() throws {
            for name in ["super.img", "vbmeta.img", "metadata.img", "misc.img"] { try Data(name.utf8).write(to: instance.appending(path: name)) }
        }
        try makeCopies()
        // An instance from before the records, made from the image an older Avo picked.
        #expect(try store.prepareStart(with: older, unrecorded: older.directory) == .none)
        #expect(FileManager.default.fileExists(atPath: instance.appending(path: "super.img").path))
        #expect(store.bootRecord()?.path == older.path)
        #expect(try store.prepareStart(with: older, unrecorded: nil) == .none)
        // Another image: super and vbmeta go, the metadata disk (Android's data key) stays.
        #expect(try store.prepareStart(with: newer, unrecorded: nil) == .replaced)
        #expect(!FileManager.default.fileExists(atPath: instance.appending(path: "super.img").path))
        #expect(!FileManager.default.fileExists(atPath: instance.appending(path: "vbmeta.img").path))
        #expect(FileManager.default.fileExists(atPath: instance.appending(path: "metadata.img").path))
        #expect(FileManager.default.fileExists(atPath: instance.appending(path: "misc.img").path))
        #expect(store.bootRecord()?.path == newer.path)
        // No copies yet (avo-vmm makes them): nothing to replace.
        #expect(try store.prepareStart(with: older, unrecorded: nil) == .none)
    }

    @Test func verifiedBootStaysOffForAnotherBuildOfTheSameVersion() async throws {
        let paths = try scratchPaths()
        let store = AndroidImageStore(paths: paths)
        var update = SyntheticImage()
        update.build = "16400000"
        let current = try await install(SyntheticImage(), in: paths)
        let newerBuild = try await install(update, in: paths)
        let sixteen = try await install(sixteen(), in: paths)
        let instance = store.instance
        func disableVerity(from image: AndroidImageSummary) throws {
            // What `avbctl disable-verity` leaves: the image's vbmeta with flag 1.
            try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
            let copy = instance.appending(path: "vbmeta.img")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: image.directory.appending(path: "vbmeta.img"), to: copy)
            try AndroidImageStore.setVBMetaFlags(1, in: copy)
            try Data("super".utf8).write(to: instance.appending(path: "super.img"))
        }
        try store.prepareStart(with: current, unrecorded: nil)
        try disableVerity(from: current)
        #expect(try store.prepareStart(with: newerBuild, unrecorded: nil) == .replacedKeepingVerifiedBootOff)
        let vbmeta = instance.appending(path: "vbmeta.img")
        #expect(AndroidImageStore.vbmetaFlags(vbmeta) == 1)
        var expected = try Data(contentsOf: newerBuild.directory.appending(path: "vbmeta.img"))
        expected[123] = 1
        #expect(try Data(contentsOf: vbmeta) == expected)
        #expect(!FileManager.default.fileExists(atPath: instance.appending(path: "super.img").path))
        // Another Android version: verified boot comes back (Google apps' overlay would not fit).
        try disableVerity(from: newerBuild)
        #expect(try store.prepareStart(with: sixteen, unrecorded: nil) == .replaced)
        #expect(!FileManager.default.fileExists(atPath: vbmeta.path))
    }

    @Test func remembersTheNewestAndroidThatUsedTheData() async throws {
        let paths = try scratchPaths()
        let store = AndroidImageStore(paths: paths)
        let older = try await install(sixteen(), in: paths)
        let newer = try await install(SyntheticImage(), in: paths)
        // No data disk: a first start.
        #expect(store.change(to: newer.release, path: newer.path, current: nil) == .fresh)
        try store.prepareStart(with: older, unrecorded: nil)
        #expect(store.dataRecord() == nil)
        try FileManager.default.createDirectory(at: paths.vm, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.dataDisk.path, contents: Data())
        #expect(store.dataRecord()?.release.version == "16")
        #expect(store.change(to: older.release, path: older.path, current: older) == .same)
        #expect(store.change(to: newer.release, path: newer.path, current: older) == .upgrade)
        try store.prepareStart(with: newer, unrecorded: nil)
        #expect(store.dataRecord()?.release.version == "17")
        #expect(store.dataRecord()?.build == "16373615")
        #expect(store.change(to: older.release, path: older.path, current: newer) == .downgrade)
        // Starting the older one anyway (Android would refuse) keeps the record at 17.
        try store.prepareStart(with: older, unrecorded: nil)
        #expect(store.dataRecord()?.release.version == "17")
        // Reset Android removes the data disk: anything goes again.
        try FileManager.default.removeItem(at: paths.dataDisk)
        #expect(store.change(to: older.release, path: older.path, current: newer) == .fresh)
    }

    @Test func classifiesChanges() {
        let sixteen = AndroidRelease(version: "16", sdk: 36, sdkFull: "36.1", securityPatch: "2025-12-05")
        let seventeen = AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0", securityPatch: "2026-06-05")
        #expect(AndroidImageStore.change(from: sixteen, to: seventeen) == .upgrade)
        #expect(AndroidImageStore.change(from: seventeen, to: sixteen) == .downgrade)
        #expect(AndroidImageStore.change(from: seventeen, to: seventeen) == .sameVersion)
        var patched = seventeen
        patched.securityPatch = "2026-09-05"
        #expect(AndroidImageStore.change(from: seventeen, to: patched) == .sameVersion)
        #expect(AndroidImageStore.change(from: patched, to: seventeen) == .downgrade)
    }

    @Test func leftoversOfAStoppedInstallGo() throws {
        let paths = try scratchPaths()
        let store = AndroidImageStore(paths: paths)
        let staging = paths.images.appending(path: ".staging-123")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        store.removeStaging()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
}

@Suite struct AndroidImageDownloadPipelineTests {
    func offer(for zip: Data, build: String = "16373615", release: AndroidRelease = AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0")) -> AndroidImageOffer {
        AndroidImageOffer(build: build, branch: "aosp-android-latest-release", target: "aosp_cf_arm64_only_phone-userdebug", release: release,
                          date: nil, artifact: "aosp_cf_arm64_only_phone-img-\(build).zip", downloadSize: Int64(zip.count), md5: md5Hex(zip))
    }

    func installer(_ paths: AvoPaths, _ api: FixtureBuildAPI, freeSpace: Int64? = nil) -> AndroidImageInstaller {
        AndroidImageInstaller(store: AndroidImageStore(paths: paths), client: AndroidBuildClient(source: .standard, transport: api),
                              downloads: RangeFileServer.configuration, freeSpace: { _ in freeSpace })
    }

    @Test func downloadsChecksAndInstalls() async throws {
        let paths = try scratchPaths()
        let api = try FixtureBuildAPI()
        var image = SyntheticImage()
        image.payload = 200_000
        let zip = image.zip()
        let served = api.serve(zip, build: "16373615")
        let events = EventLog()
        let summary = try await installer(paths, api).download(offer(for: zip)) { events.add($0) }
        #expect(summary.origin == .androidBuild(branch: "aosp-android-latest-release", target: "aosp_cf_arm64_only_phone-userdebug",
                                                build: "16373615", artifact: "aosp_cf_arm64_only_phone-img-16373615.zip", md5: md5Hex(zip)))
        // The catalog's release (exact API level) is kept.
        #expect(summary.release?.sdkFull == "37.0")
        let phases = events.all
        #expect(phases.first == .preparing)
        #expect(phases.contains { if case .progress = $0 { true } else { false } })
        #expect(phases.contains(.verifying(0)))
        #expect(phases.contains(.finishing))
        // The download is gone once installed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: AndroidImageStore(paths: paths).downloads.path).isEmpty)
        // Installed already: nothing is downloaded again.
        let before = RangeFileServer.requests(for: served).count
        #expect(try await installer(paths, api).download(offer(for: zip)) { _ in } == summary)
        #expect(RangeFileServer.requests(for: served).count == before)
    }

    @Test func pauseAndResumeContinueTheDownload() async throws {
        let paths = try scratchPaths()
        let api = try FixtureBuildAPI()
        var image = SyntheticImage()
        image.payload = 300_000
        let zip = image.zip()
        let url = api.serve(zip, build: "16373615") { $0.chunkDelay = 0.01; $0.chunkSize = 16_000 }
        let images = installer(paths, api)
        let offer = offer(for: zip)
        let halfway = CancelFlag()
        let task = Task {
            try await images.download(offer) { event in
                if case .progress(let progress) = event, progress.received > Int64(zip.count / 3) { halfway.set() }
            }
        }
        while !halfway.isSet { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let kept = images.downloadedBytes(offer)
        #expect(kept > 0 && kept < Int64(zip.count))
        // Resume: a range request from where it stopped, with the ETag it saw.
        let summary = try await images.download(offer) { _ in }
        #expect(summary.build == "16373615")
        let ranged = try #require(RangeFileServer.requests(for: url).last)
        #expect(ranged.value(forHTTPHeaderField: "Range") == "bytes=\(kept)-")
        #expect(ranged.value(forHTTPHeaderField: "If-Range") == "\"\(md5Hex(zip))\"")
    }

    @Test func anExpiredLinkIsRenewed() async throws {
        let paths = try scratchPaths()
        let api = try FixtureBuildAPI()
        let zip = SyntheticImage().zip()
        let url = api.serve(zip, build: "16373615") { $0.expiredAnswers = 1 }
        _ = try await installer(paths, api).download(offer(for: zip)) { _ in }
        #expect(RangeFileServer.requests(for: url).count == 2)
    }

    @Test func aDamagedDownloadIsThrownAway() async throws {
        let paths = try scratchPaths()
        let api = try FixtureBuildAPI()
        let zip = SyntheticImage().zip()
        api.serve(zip, build: "16373615")
        var wrong = offer(for: zip)
        wrong.md5 = "00000000000000000000000000000000"
        let images = installer(paths, api)
        await #expect(throws: AndroidImageError.checksumMismatch(wrong.artifact)) { try await images.download(wrong) { _ in } }
        #expect(images.downloadedBytes(wrong) == 0)
        #expect(AndroidImageStore(paths: paths).managed().isEmpty)
    }

    @Test func checksDiskSpaceFirst() async throws {
        let paths = try scratchPaths()
        let api = try FixtureBuildAPI()
        let zip = SyntheticImage().zip()
        let url = api.serve(zip, build: "16373615")
        let images = installer(paths, api, freeSpace: 10)
        await #expect(throws: AndroidImageError.self) { try await images.download(offer(for: zip)) { _ in } }
        #expect(RangeFileServer.requests(for: url).isEmpty)
    }

    @Test func refusesFilesOfAnotherBuild() async throws {
        let paths = try scratchPaths()
        let api = try FixtureBuildAPI()
        let zip = SyntheticImage().zip()
        api.serve(zip, build: "15581820")
        // The zip's images say 16373615.
        await #expect(throws: AndroidImageError.self) {
            try await installer(paths, api).download(offer(for: zip, build: "15581820")) { _ in }
        }
    }
}
