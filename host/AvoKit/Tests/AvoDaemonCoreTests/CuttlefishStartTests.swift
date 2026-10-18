import AvoKit
import AvoPackages
import Foundation
import Testing
@testable import AvoDaemonCore

/// The daemon's half of Android versions: which image a start uses, that it
/// is checked, and that avo-vmm's copies follow a new one.
@Suite struct CuttlefishStartTests {
    /// A folder with the files a Cuttlefish image has; vbmeta.img carries the
    /// build's fingerprint as AVB properties.
    func makeImage(_ folder: URL, version: String = "17", build: String = "16373615") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func u64(_ value: Int) -> Data { withUnsafeBytes(of: UInt64(value).bigEndian) { Data($0) } }
        let fingerprint = "generic/aosp_cf_arm64_only_phone/vsoc_arm64_only:\(version)/CP2A/\(build):userdebug/test-keys"
        var descriptors = Data()
        for (key, value) in [("com.android.build.vendor.fingerprint", fingerprint), ("com.android.build.vendor.security_patch", "2026-06-05")] {
            var body = u64(key.utf8.count) + u64(value.utf8.count) + Data(key.utf8) + Data([0]) + Data(value.utf8) + Data([0])
            body += Data(count: (8 - body.count % 8) % 8)
            descriptors += u64(0) + u64(body.count) + body
        }
        var vbmeta = Data("AVB0".utf8) + Data(count: 8) + u64(0) + u64(descriptors.count)
        vbmeta += Data(count: 96 - vbmeta.count) + u64(0) + u64(descriptors.count)
        vbmeta += Data(count: 256 - vbmeta.count) + descriptors
        let files: [String: Data] = [
            "boot.img": Data("ANDROID!".utf8) + Data(count: 4000),
            "init_boot.img": Data("ANDROID!".utf8) + Data(count: 4000),
            "vendor_boot.img": Data("VNDRBOOT".utf8) + Data(count: 4000),
            "super.img": Data([0x3A, 0xFF, 0x26, 0xED]) + Data(count: 8000),
            "vbmeta.img": vbmeta + Data(count: 4096 - vbmeta.count),
        ]
        for (name, data) in files { try data.write(to: folder.appending(path: name)) }
        return folder
    }

    func scratch() throws -> AvoPaths {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-start-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AvoPaths(home: root, temporaryDirectory: root.appending(path: "tmp"))
    }

    @Test func withoutAnImageAndroidIsNotInstalled() throws {
        let paths = try scratch()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        #expect(throws: AvoError.imageMissing) { try CuttlefishImage.prepareStart(paths: paths, override: nil) }
    }

    @Test func usesTheChosenImageAndMakesAvoVMMCopyItsFilesAgain() async throws {
        let paths = try scratch()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let store = AndroidImageStore(paths: paths)
        // An image scripts/fetch-cuttlefish.sh downloaded, which an older Avo booted.
        let legacy = try makeImage(paths.home.appending(path: "Library/Caches/Avo/cuttlefish/16102939/img"), build: "16102939")
        let instance = store.instance
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        for name in ["super.img", "vbmeta.img", "metadata.img"] { try Data(name.utf8).write(to: instance.appending(path: name)) }

        let first = try CuttlefishImage.prepareStart(paths: paths, override: nil)
        #expect(first.directory.standardizedFileURL.path == legacy.standardizedFileURL.path)
        #expect(first.version == "cuttlefish-16102939")
        #expect(first.sdk == 37)
        // The same image an older Avo used: the copies stay.
        #expect(FileManager.default.fileExists(atPath: instance.appending(path: "super.img").path))

        // An image installed in Avo and chosen in Settings › System › Android version.
        let installer = AndroidImageInstaller(store: store, client: AndroidBuildClient(source: .standard), freeSpace: { _ in nil })
        let source = try makeImage(paths.home.appending(path: "Downloads/img"))
        let installed = try await installer.importImage(try installer.inspect(source)) { _ in }
        try store.select(installed)
        let second = try CuttlefishImage.prepareStart(paths: paths, override: nil)
        #expect(second.directory.standardizedFileURL.path == installed.path)
        #expect(!FileManager.default.fileExists(atPath: instance.appending(path: "super.img").path))
        #expect(!FileManager.default.fileExists(atPath: instance.appending(path: "vbmeta.img").path))
        #expect(FileManager.default.fileExists(atPath: instance.appending(path: "metadata.img").path))

        // A damaged file stops the start.
        try Data(count: 10).write(to: installed.directory.appending(path: "boot.img"))
        #expect(throws: AvoError.self) { try CuttlefishImage.prepareStart(paths: paths, override: nil) }

        // The developer setting wins.
        let override = try makeImage(paths.home.appending(path: "override"), build: "1")
        #expect(try CuttlefishImage.prepareStart(paths: paths, override: override.path).version == "cuttlefish-1")
    }

    @Test func avoVMMBootsTheImageOfTheStart() {
        let paths = AvoPaths(home: URL(filePath: "/Users/test"), temporaryDirectory: URL(filePath: "/tmp/t"))
        let image = URL(filePath: "/Users/test/Library/Application Support/Avo/images/android-17-1/", directoryHint: .isDirectory)
        let launch = EngineLaunch(config: VMConfig(), paths: paths,
                                  image: AndroidImage(schema: 1, version: "v", sdk: 37, kernel: "boot.img", initrd: nil, partitions: [],
                                                      overlayStock: "", overlayRooted: "", files: [], directory: image),
                                  bootConfigDisk: paths.vm.appending(path: "avo_config.img"))
        let arguments = VMMEngine.arguments(images: launch.image.directory, launch: launch)
        #expect(arguments.prefix(2) == ["cuttlefish", image.path])
    }
}
