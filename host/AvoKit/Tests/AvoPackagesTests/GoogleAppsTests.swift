import Foundation
import Testing
@testable import AvoPackages

/// A ZIP with stored entries, so tests choose every name (even unsafe ones).
private func storedZip(_ entries: [(String, Data)]) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    var body = Data()
    var directory = Data()
    for (name, content) in entries {
        var crc = CRC32()
        crc.update(content)
        let nameBytes = Data(name.utf8)
        let offset = UInt32(body.count)
        var common = le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0))
        common += le(crc.checksum) + le(UInt32(content.count)) + le(UInt32(content.count))
        common += le(UInt16(nameBytes.count)) + le(UInt16(0))
        body += le(UInt32(0x0403_4B50)) + common + nameBytes + content
        directory += le(UInt32(0x0201_4B50)) + le(UInt16(20)) + common
        directory += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(offset) + nameBytes
    }
    var end = le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0))
    end += le(UInt16(entries.count)) + le(UInt16(entries.count)) + le(UInt32(directory.count)) + le(UInt32(body.count)) + le(UInt16(0))
    return body + directory + end
}

/// The layout of MindTheGapps-17.0.0-arm64 (contents shortened).
private let mindTheGapps: [(String, Data)] = [
    ("META-INF/com/google/android/update-binary", Data("#!/sbin/sh\n".utf8)),
    ("META-INF/com/google/android/updater-script", Data("# dummy\n".utf8)),
    ("build.prop", Data("arch=arm64\nversion=37\nversion_nice=17.0.0\n".utf8)),
    ("system/addon.d/addond_head", Data("#!/sbin/sh\n".utf8)),
    ("system/product/app/GoogleCalendarSyncAdapter/GoogleCalendarSyncAdapter.apk", Data(repeating: 1, count: 300)),
    ("system/product/etc/permissions/privapp-permissions-google-product.xml", Data("<permissions/>".utf8)),
    ("system/product/priv-app/Phonesky/Phonesky.apk", Data(repeating: 2, count: 1000)),
    ("system/product/priv-app/Velvet/Velvet.apk", Data(repeating: 3, count: 500)),
    ("system/product/priv-app/VelvetTitan/VelvetTitan.apk", Data(repeating: 4, count: 700)),
    ("system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk", Data(repeating: 5, count: 200)),
    ("system/system_ext/priv-app/SetupWizard/SetupWizard.apk", Data(repeating: 6, count: 100)),
    ("toybox", Data(repeating: 7, count: 10)),
]

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "avo-gapps-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ entries: [(String, Data)], zipNamed name: String = "gapps.zip", in directory: URL) throws -> URL {
    let url = directory.appending(path: name)
    try storedZip(entries).write(to: url)
    return url
}

@Suite struct GoogleAppsPackageTests {
    @Test func readsAMindTheGappsZip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try GoogleAppsPackage(url: write(mindTheGapps, in: directory))
        #expect(package.arch == "arm64")
        #expect(package.sdk == 37)
        #expect(package.versionName == "17.0.0")
        // Only what goes to /product and /system_ext; never META-INF, toybox or addon.d.
        #expect(package.files.map(\.path) == [
            "product/app/GoogleCalendarSyncAdapter/GoogleCalendarSyncAdapter.apk",
            "product/etc/permissions/privapp-permissions-google-product.xml",
            "product/priv-app/Phonesky/Phonesky.apk",
            "product/priv-app/Velvet/Velvet.apk",
            "product/priv-app/VelvetTitan/VelvetTitan.apk",
            "system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk",
            "system_ext/priv-app/SetupWizard/SetupWizard.apk",
        ])
        let phonesky = try #require(package.files.first { $0.path.hasSuffix("Phonesky.apk") })
        #expect(phonesky.size == 1000)
        var bytes = Data()
        try package.stream(phonesky) { bytes.append($0) }
        #expect(bytes == Data(repeating: 2, count: 1000))
    }

    @Test func appliesTheInstallersRules() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try GoogleAppsPackage(url: write(mindTheGapps, in: directory))
        let phone = try package.plan(sdk: 37, arch: "arm64", product: "vsoc_arm64_only").map(\.path)
        #expect(phone.contains("product/priv-app/Velvet/Velvet.apk"))
        #expect(!phone.contains { $0.contains("VelvetTitan") })
        #expect(!phone.contains { $0.contains("SetupWizard") })
        #expect(phone.contains("system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"))
        // The Pixel Tablet gets the tablet Google app instead.
        let tablet = try package.plan(sdk: 37, arch: "arm64", product: "tangorpro").map(\.path)
        #expect(tablet.contains("product/priv-app/VelvetTitan/VelvetTitan.apk"))
        #expect(!tablet.contains("product/priv-app/Velvet/Velvet.apk"))
        // Prefixes are whole folder names.
        #expect(GoogleAppsPackage.installs("product/priv-app/VelvetTitanic/x.apk", product: "vsoc_arm64_only"))
    }

    @Test func refusesPackagesForOtherDevices() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try GoogleAppsPackage(url: write(mindTheGapps, in: directory))
        #expect(throws: GoogleAppsError.wrongAndroidVersion(package: "Android 17.0.0 (SDK 37)", deviceSDK: 36)) {
            try package.plan(sdk: 36, arch: "arm64", product: "vsoc_arm64_only")
        }
        #expect(throws: GoogleAppsError.wrongArchitecture(package: "arm64", device: "x86_64")) {
            try package.plan(sdk: 37, arch: "x86_64", product: "vsoc_x86_64")
        }
    }

    @Test func refusesWhatIsNotAMindTheGappsPackage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let noProp = mindTheGapps.filter { $0.0 != "build.prop" }
        #expect(throws: GoogleAppsError.notAPackage) { try GoogleAppsPackage(url: write(noProp, zipNamed: "a.zip", in: directory)) }
        let noSystem = mindTheGapps.filter { !$0.0.hasPrefix("system/") }
        #expect(throws: GoogleAppsError.notAPackage) { try GoogleAppsPackage(url: write(noSystem, zipNamed: "b.zip", in: directory)) }
        let escaping = mindTheGapps + [("system/product/../../evil.so", Data([0]))]
        #expect(throws: GoogleAppsError.unsafePath("system/product/../../evil.so")) {
            try GoogleAppsPackage(url: write(escaping, zipNamed: "c.zip", in: directory))
        }
        let forSystem = mindTheGapps + [("system/etc/permissions/x.xml", Data([0]))]
        #expect(throws: GoogleAppsError.unsupportedLayout("system/etc/permissions/x.xml")) {
            try GoogleAppsPackage(url: write(forSystem, zipNamed: "d.zip", in: directory))
        }
        let apk = directory.appending(path: "e.zip")
        try Data("not a zip".utf8).write(to: apk)
        #expect(throws: PackageError.notAZipArchive) { try GoogleAppsPackage(url: apk) }
    }

    @Test func readsARezippedFolder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = mindTheGapps.map { ("MindTheGapps-17.0.0-arm64/" + $0.0, $0.1) }
            + [("__MACOSX/MindTheGapps-17.0.0-arm64/._build.prop", Data([0]))]
        let package = try GoogleAppsPackage(url: write(nested, in: directory))
        #expect(package.sdk == 37)
        #expect(package.files.count == 7)
    }

    @Test func readsAnUnzippedFolder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "MindTheGapps")
        for (path, content) in mindTheGapps + [("system/.DS_Store", Data([0])), ("system/product/._Phonesky", Data([0]))] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url)
        }
        let package = try GoogleAppsPackage(url: root)
        #expect(package.files.count == 7)
        let plan = try package.plan(sdk: 37, arch: "arm64", product: "vsoc_arm64_only")
        #expect(plan.count == 5)
        let velvet = try #require(plan.first { $0.path == "product/priv-app/Velvet/Velvet.apk" })
        var bytes = Data()
        try package.stream(velvet) { bytes.append($0) }
        #expect(bytes == Data(repeating: 3, count: 500))

        // A symbolic link could point anywhere on the Mac.
        try FileManager.default.createSymbolicLink(at: root.appending(path: "system/product/lib64"), withDestinationURL: URL(filePath: "/etc"))
        #expect(throws: GoogleAppsError.unsafePath("system/product/lib64")) { try GoogleAppsPackage(url: root) }
    }

    @Test func errorsSpeakIndonesian() throws {
        let path = try #require(Bundle.avoKit.path(forResource: "id", ofType: "lproj"))
        let indonesian = try #require(Bundle(path: path))
        let device = "x86_64"
        #expect(String(localized: "The package is built for \("arm64"), but Android here is \(device).", bundle: indonesian)
            == "Paket ini dibuat untuk arm64, sedangkan Android di sini x86_64.")
        #expect(GoogleAppsError.wrongArchitecture(package: "arm64", device: "x86_64").errorDescription
            == "The package is built for arm64, but Android here is x86_64.") // tests run in English
    }

    @Test func parsesBuildProp() {
        let properties = GoogleAppsPackage.parseProperties("# comment\narch=arm64\r\nversion = 37\nbroken\nversion=99\n")
        #expect(properties == ["arch": "arm64", "version": "37"])
    }
}

@Suite struct GitHubReleaseTests {
    @Test func mapsReleaseLinksToTheAPI() throws {
        let latest = "https://api.github.com/repos/MindTheGapps/17.0.0-arm64/releases/latest"
        for link in ["https://github.com/MindTheGapps/17.0.0-arm64/releases/latest",
                     "https://github.com/MindTheGapps/17.0.0-arm64",
                     "github.com/MindTheGapps/17.0.0-arm64/releases/",
                     " https://github.com/MindTheGapps/17.0.0-arm64.git ",
                     latest] {
            let mapped = try GitHubRelease.apiURL(for: link)
            #expect(mapped.url.absoluteString == latest, "\(link)")
            #expect(mapped.asset == nil)
        }
        let tag = try GitHubRelease.apiURL(for: "https://github.com/MindTheGapps/17.0.0-arm64/releases/tag/MindTheGapps-17.0.0-arm64-20261006_111038")
        #expect(tag.url.absoluteString
            == "https://api.github.com/repos/MindTheGapps/17.0.0-arm64/releases/tags/MindTheGapps-17.0.0-arm64-20261006_111038")
        let asset = try GitHubRelease.apiURL(for: "https://github.com/MindTheGapps/17.0.0-arm64/releases/download/T1/MindTheGapps-17.0.0-arm64-T1.zip")
        #expect(asset.url.absoluteString == "https://api.github.com/repos/MindTheGapps/17.0.0-arm64/releases/tags/T1")
        #expect(asset.asset == "MindTheGapps-17.0.0-arm64-T1.zip")
        for bad in ["http://github.com/MindTheGapps/17.0.0-arm64", "https://example.com/MindTheGapps/17.0.0-arm64",
                    "https://github.com/MindTheGapps", "https://github.com/MindTheGapps/17.0.0-arm64/issues", "not a link"] {
            #expect(throws: GoogleAppsError.invalidReleaseURL(bad)) { try GitHubRelease.apiURL(for: bad) }
        }
    }

    /// The API's answer for MindTheGapps-17.0.0-arm64 (other fields left out).
    static let release = Data("""
        {"url": "https://api.github.com/repos/MindTheGapps/17.0.0-arm64/releases/1", "tag_name": "MindTheGapps-17.0.0-arm64-20261006_111038",
         "name": null, "draft": false, "prerelease": false, "assets": [
          {"name": "MindTheGapps-17.0.0-arm64-20261006_111038.zip", "size": 544284432, "content_type": "application/zip",
           "digest": "sha256:6b38929ec345d96b6d64ad82f391869b7a60b3260efb0661b543b109b3ce646d",
           "browser_download_url": "https://github.com/MindTheGapps/17.0.0-arm64/releases/download/MindTheGapps-17.0.0-arm64-20261006_111038/MindTheGapps-17.0.0-arm64-20261006_111038.zip"},
          {"name": "MindTheGapps-17.0.0-arm64-20261006_111038.zip.sha256sum", "size": 112, "digest": null,
           "browser_download_url": "https://github.com/MindTheGapps/17.0.0-arm64/releases/download/MindTheGapps-17.0.0-arm64-20261006_111038/MindTheGapps-17.0.0-arm64-20261006_111038.zip.sha256sum"},
          {"name": "release.x509.pem", "size": 1464,
           "browser_download_url": "https://github.com/MindTheGapps/17.0.0-arm64/releases/download/MindTheGapps-17.0.0-arm64-20261006_111038/release.x509.pem"}
        ]}
        """.utf8)

    @Test func findsThePackageAndItsChecksum() throws {
        let release = try GitHubRelease.parse(Self.release)
        #expect(release.tagName == "MindTheGapps-17.0.0-arm64-20261006_111038")
        let zip = try #require(release.packageAsset())
        #expect(zip.name == "MindTheGapps-17.0.0-arm64-20261006_111038.zip")
        #expect(zip.size == 544_284_432)
        #expect(zip.sha256 == "6b38929ec345d96b6d64ad82f391869b7a60b3260efb0661b543b109b3ce646d")
        #expect(release.checksumAsset(for: zip)?.name == "MindTheGapps-17.0.0-arm64-20261006_111038.zip.sha256sum")
        #expect(release.packageAsset(preferring: "other.zip") == nil)
        #expect(try GitHubRelease.parse(Data(#"{"tag_name": "x", "assets": []}"#.utf8)).packageAsset() == nil)
    }

    @Test func readsChecksums() {
        let hash = "6b38929ec345d96b6d64ad82f391869b7a60b3260efb0661b543b109b3ce646d"
        let name = "MindTheGapps-17.0.0-arm64-20261006_111038.zip"
        #expect(Checksum.sha256(fromDigest: "sha256:" + hash.uppercased()) == hash)
        #expect(Checksum.sha256(fromDigest: "md5:abc") == nil)
        #expect(Checksum.sha256(fromDigest: "sha256:1234") == nil)
        #expect(Checksum.sha256(fromSumFile: "\(hash)  \(name)\n", name: name) == hash)
        #expect(Checksum.sha256(fromSumFile: "\(hash) *out/\(name)\n", name: name) == hash)
        #expect(Checksum.sha256(fromSumFile: hash + "\n", name: name) == hash)
        #expect(Checksum.sha256(fromSumFile: "\(hash)  other.zip\n", name: name) == nil)
    }

    @Test func hashesFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "abc")
        try Data("abc".utf8).write(to: file)
        #expect(try Checksum.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
