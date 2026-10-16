import Foundation
import Testing
@testable import AvoKit

@Suite struct DeviceProfileTests {
    static let repoProfiles = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../profiles/devices")
        .standardizedFileURL

    @Test func repositoryTemplatesAreAllValid() throws {
        let catalog = try DeviceProfileCatalog(directory: Self.repoProfiles)
        #expect(catalog.rejected.isEmpty, "\(catalog.rejected)")
        #expect(catalog.profiles.first?.id == DeviceProfile.defaultID)
        // The spec names these templates explicitly.
        for id in ["samsung-galaxy-s24-ultra", "google-pixel-9-pro", "xiaomi-14", "asus-rog-phone-8", "oneplus-12"] {
            #expect(catalog.profile(id: id) != nil, "missing template \(id)")
        }
    }

    @Test func defaultProfileOverridesNothing() throws {
        let catalog = try DeviceProfileCatalog(directory: Self.repoProfiles)
        let profile = try #require(catalog.profile(id: DeviceProfile.defaultID))
        #expect(profile.properties.isEmpty)
        #expect(profile.propertyFile().isEmpty)
    }

    @Test func requiresIdentityProperties() {
        let profile = DeviceProfile(id: "broken", name: "Broken", properties: ["ro.product.brand": "x"])
        let problems = profile.validate()
        #expect(problems.contains("missing ro.product.model"))
        #expect(problems.contains("missing ro.build.fingerprint"))
    }

    @Test func rejectsSecurityProperties() {
        var properties = Self.validProperties
        properties["ro.debuggable"] = "0"
        properties["persist.sys.foo"] = "1"
        let problems = DeviceProfile(id: "sneaky", name: "Sneaky", properties: properties).validate()
        #expect(problems.contains("ro.debuggable may not be overridden"))
        #expect(problems.contains("persist.sys.foo is not an identity property"))
    }

    @Test(arguments: [
        ("google/caiman/caiman:15/AP4A.250205.002/12821496:user/release-keys", true),
        ("google/caiman:15/AP4A/1:user/release-keys", false),
        ("google/caiman/caiman:15/AP4A.250205.002/12821496:user", false),
        ("google/caiman/caiman:15/AP4A 250205/1:user/release-keys", false),
    ])
    func fingerprintFormat(fingerprint: String, valid: Bool) {
        #expect(DeviceProfile.isValidFingerprint(fingerprint) == valid)
    }

    @Test func propertyFileIsSortedKeyValueLines() {
        let profile = DeviceProfile(id: "x", name: "X", properties: Self.validProperties)
        let lines = profile.propertyFile().split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines.first == "ro.build.fingerprint=a/b/c:16/BP2A/1:user/release-keys")
        #expect(lines.map { $0.split(separator: "=")[0] } == lines.map { $0.split(separator: "=")[0] }.sorted())
    }

    @Test func catalogRejectsMismatchedFileNames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "avo-profiles-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = DeviceProfile(id: "right-id", name: "Right", properties: Self.validProperties)
        try JSONEncoder().encode(profile).write(to: dir.appending(path: "wrong-name.json"))
        try Data("{".utf8).write(to: dir.appending(path: "garbage.json"))
        let catalog = try DeviceProfileCatalog(directory: dir)
        #expect(catalog.profiles.isEmpty)
        #expect(catalog.rejected.count == 2)
    }

    static let validProperties = [
        "ro.product.brand": "a",
        "ro.product.manufacturer": "A",
        "ro.product.model": "A1",
        "ro.product.device": "c",
        "ro.build.fingerprint": "a/b/c:16/BP2A/1:user/release-keys",
    ]
}

@Suite struct XPCPayloadTests {
    @Test func daemonEventsRoundTrip() throws {
        let events: [DaemonEvent] = [
            .vmStatus(VMStatus(state: .running, androidVersion: "16", protocolVersion: 1, openDisplays: 2)),
            .appInstalled(AppRecord(package: "org.fdroid.fdroid", label: "F-Droid", versionName: "1.20", versionCode: 1_020_000)),
            .appRemoved(package: "com.example"),
            .installProgress(InstallProgress(id: UUID(), phase: .transferring, fraction: 0.5)),
            .orientationRequest(displayID: 3, orientation: .landscape),
            .displayTitle(displayID: 3, title: "Inbox"),
        ]
        for event in events {
            #expect(try AvoXPC.decode(DaemonEvent.self, from: AvoXPC.encode(event)) == event)
        }
    }

    @Test func errorsSurviveXPC() {
        let error = AvoXPC.nsError(AvoError.installFailed("INSTALL_FAILED_NO_MATCHING_ABIS"))
        #expect(AvoXPC.avoError(error) == .installFailed("INSTALL_FAILED_NO_MATCHING_ABIS"))
        #expect(error.localizedDescription == "Installation failed: INSTALL_FAILED_NO_MATCHING_ABIS")
        let foreign = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "nope"])
        #expect(AvoXPC.avoError(foreign) == .internalError("nope"))
    }

    @Test func interfacesAcceptSurfaceArrays() {
        // Building the interfaces validates the selectors and class whitelists.
        _ = AvoXPC.daemonInterface()
        _ = AvoXPC.clientInterface()
    }
}
