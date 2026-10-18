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

    /// What the test image (AOSP Cuttlefish 16373615) reports with no profile.
    static let imageFingerprint = "generic/aosp_cf_arm64_only_phone/vsoc_arm64_only:17/CP2A.260605.016/16373615:userdebug/test-keys"

    @Test func defaultProfileIsAvosHonestIdentity() throws {
        let catalog = try DeviceProfileCatalog(directory: Self.repoProfiles)
        let profile = try #require(catalog.profile(id: DeviceProfile.defaultID))
        #expect(profile.validate().isEmpty)
        #expect(profile.isAvoIdentity)
        // The file and the daemon's built-in copy say the same.
        #expect(profile == DeviceProfile.avo)
        #expect(profile.properties == [
            "ro.product.brand": "Avo", "ro.product.manufacturer": "Avo", "ro.product.model": "AVO-Droid",
            "ro.product.name": "avo_droid", "ro.product.device": "avo_droid",
        ])
        #expect(profile.propertyFile() == """
            ro.product.brand=Avo
            ro.product.device=avo_droid
            ro.product.manufacturer=Avo
            ro.product.model=AVO-Droid
            ro.product.name=avo_droid

            """)
        // Android derives the fingerprint: Avo's names, the image's own build.
        let fingerprint = try #require(profile.fingerprint(image: Self.imageFingerprint))
        #expect(fingerprint == "Avo/avo_droid/avo_droid:17/CP2A.260605.016/16373615:userdebug/test-keys")
        #expect(DeviceProfile.isValidFingerprint(fingerprint))
        // Only the honest identity is outside the "impersonate a phone" group.
        #expect(catalog.profiles.filter(\.isAvoIdentity).map(\.id) == [DeviceProfile.defaultID])
    }

    @Test func honestIdentityKeepsAndroidsOwnFingerprint() {
        var properties = DeviceProfile.avo.properties
        properties["ro.build.fingerprint"] = "Avo/avo_droid/avo_droid:16/BP2A/1:user/release-keys"
        let pinned = DeviceProfile(id: DeviceProfile.defaultID, name: "Avo", properties: properties)
        #expect(pinned.validate() == ["ro.build.fingerprint is Android's own derivation for this profile"])
        properties = DeviceProfile.avo.properties
        properties["ro.product.name"] = nil
        let unnamed = DeviceProfile(id: DeviceProfile.defaultID, name: "Avo", properties: properties)
        #expect(unnamed.validate() == ["missing ro.product.name"])
    }

    @Test func fingerprintOfAnImpersonationIsItsOwn() throws {
        let catalog = try DeviceProfileCatalog(directory: Self.repoProfiles)
        let phone = try #require(catalog.profile(id: "samsung-galaxy-s24-ultra"))
        #expect(!phone.isAvoIdentity)
        #expect(phone.fingerprint(image: Self.imageFingerprint) == phone.properties["ro.build.fingerprint"])
        // Fields a profile leaves alone come from the image.
        let partial = DeviceProfile(id: "x", name: "X", properties: ["ro.product.brand": "Avo"])
        #expect(partial.fingerprint(image: Self.imageFingerprint)
            == "Avo/aosp_cf_arm64_only_phone/vsoc_arm64_only:17/CP2A.260605.016/16373615:userdebug/test-keys")
        #expect(partial.fingerprint(image: "not a fingerprint") == nil)
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

    /// Drivers, ABIs and Avo's own markers would break Android or hide Avo.
    @Test(arguments: ["ro.hardware", "ro.hardware.egl", "ro.hardware.vulkan", "ro.product.cpu.abilist",
                      "ro.product.first_api_level", "ro.product.vendor.cpu.abilist", "ro.boot.avo.version",
                      "ro.avo.version", "ro.boot.hardware"])
    func rejectsNonIdentityProperties(key: String) {
        var properties = Self.validProperties
        properties[key] = "x"
        let problems = DeviceProfile(id: "x", name: "X", properties: properties).validate()
        #expect(problems.contains("\(key) is not an identity property") || problems.contains("\(key) may not be overridden"))
    }

    @Test(arguments: ["ro.product.model", "ro.product.name", "ro.product.vendor.model", "ro.product.odm.device",
                      "ro.product.bootimage.brand", "ro.build.fingerprint", "ro.build.id", "ro.soc.model"])
    func acceptsIdentityProperties(key: String) {
        #expect(DeviceProfile.isIdentityProperty(key))
    }

    @Test func fingerprintFieldsHaveNoSeparators() {
        var properties = Self.validProperties
        properties["ro.product.device"] = "my device"
        properties["ro.product.name"] = "a/b"
        let problems = DeviceProfile(id: "x", name: "X", properties: properties).validate()
        #expect(problems.contains("ro.product.device is part of the build fingerprint: no spaces, '/' or ':'"))
        #expect(problems.contains("ro.product.name is part of the build fingerprint: no spaces, '/' or ':'"))
        // The model is free text ("Pixel 9 Pro").
        properties = Self.validProperties
        properties["ro.product.model"] = "Pixel 9 Pro"
        #expect(DeviceProfile(id: "x", name: "X", properties: properties).validate().isEmpty)
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
        // Nothing usable: only the built-in honest identity.
        #expect(catalog.profiles == [DeviceProfile.avo])
        #expect(catalog.rejected.count == 2)
    }

    @Test func catalogKeepsTheHonestIdentityWhenItsFileIsBroken() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "avo-profiles-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{".utf8).write(to: dir.appending(path: "\(DeviceProfile.defaultID).json"))
        let phone = DeviceProfile(id: "phone", name: "Phone", properties: Self.validProperties)
        try JSONEncoder().encode(phone).write(to: dir.appending(path: "phone.json"))
        let catalog = try DeviceProfileCatalog(directory: dir)
        #expect(catalog.profiles.map(\.id) == [DeviceProfile.defaultID, "phone"])
        #expect(catalog.profile(id: DeviceProfile.defaultID) == DeviceProfile.avo)
    }

    static let validProperties = [
        "ro.product.brand": "a",
        "ro.product.manufacturer": "A",
        "ro.product.model": "A1",
        "ro.product.device": "c",
        "ro.build.fingerprint": "a/b/c:16/BP2A/1:user/release-keys",
    ]

    // MARK: Hardware emulation (the "Emulate this phone's hardware" checkbox)

    @Test func everyRepositoryTemplateWithHardwareIsValid() throws {
        let catalog = try DeviceProfileCatalog(directory: Self.repoProfiles)
        let withHardware = catalog.profiles.filter(\.hasHardware)
        // The phones carry hardware; Avo's honest identity does not.
        #expect(withHardware.count >= 5)
        #expect(!(catalog.profile(id: DeviceProfile.defaultID)?.hasHardware ?? true))
        for profile in withHardware {
            #expect(profile.validate().isEmpty, "\(profile.id): \(profile.validate())")
            let soc = try #require(profile.hardware?.soc)
            #expect(!soc.manufacturer.isEmpty && !soc.model.isEmpty)
        }
    }

    @Test func emulationAddsHardwarePropertiesButIdentityWins() {
        let gpu = DeviceHardware.GPU(glVendor: "Qualcomm", glRenderer: "Adreno (TM) 750",
                                     vkName: "Adreno (TM) 750", vkVendorID: 0x5143, vkDriverID: 8)
        let soc = DeviceHardware.SoC(manufacturer: "QTI", model: "SM8650", platform: "pineapple", board: "pineapple",
                                     properties: ["ro.vendor.qti.soc_model": "SM8650"])
        var properties = Self.validProperties
        properties["ro.soc.model"] = "KEEP-ME" // the profile set it itself
        let profile = DeviceProfile(id: "x", name: "X", properties: properties,
                                    hardware: DeviceHardware(soc: soc, gpu: gpu))
        // Off: only the identity.
        #expect(profile.properties(emulateHardware: false) == properties)
        let on = profile.properties(emulateHardware: true)
        #expect(on["ro.soc.model"] == "KEEP-ME")                       // identity wins over hardware
        #expect(on["ro.soc.manufacturer"] == "QTI")
        #expect(on["ro.board.platform"] == "pineapple")
        #expect(on["ro.vendor.qti.soc_model"] == "SM8650")
        #expect(on["debug.avo.vk.vendor"] == "0x5143")
        #expect(on["debug.avo.vk.driver_id"] == "8")
        // vkName falls back to the GLES renderer name.
        #expect(on["debug.avo.vk.name"] == "Adreno (TM) 750")
        // The GLES layer's strings; an unset one stays unset (ANGLE's own).
        #expect(on["debug.avo.gl.vendor"] == "Qualcomm")
        #expect(on["debug.avo.gl.renderer"] == "Adreno (TM) 750")
        #expect(on["debug.avo.gl.version"] == nil)
        // The layer activation is NOT a boot property: the daemon sets
        // debug.gles.layers and debug.vulkan.layers only after installing the
        // layer files, so a missing layer is never named system-wide at boot.
        #expect(on["debug.vulkan.layers"] == nil)
        #expect(on["debug.gles.layers"] == nil)
    }

    @Test func hardwareValidationRejectsUnsafeSoCProperties() {
        func problems(_ key: String) -> [String] {
            let soc = DeviceHardware.SoC(manufacturer: "QTI", model: "SM8650", properties: [key: "x"])
            return DeviceHardware(soc: soc).validate()
        }
        // Driver, ABI, API-level and security keys are never hardware naming.
        #expect(!problems("ro.hardware.egl").isEmpty)
        #expect(!problems("ro.board.api_level").isEmpty)
        #expect(!problems("ro.product.cpu.abilist").isEmpty)
        #expect(!problems("persist.sys.x").isEmpty)
        // Vendor and board naming is allowed.
        #expect(problems("ro.vendor.qti.soc_model").isEmpty)
        #expect(problems("ro.mediatek.platform").isEmpty)
        #expect(problems("ro.hardware.chipname").isEmpty)
    }

    @Test func hardwareValidationKeepsGPUNamesWithinAProperty() {
        // debug.* properties hold at most 91 bytes; init drops longer lines.
        let fits = DeviceHardware.GPU(glVersion: String(repeating: "v", count: 91))
        #expect(DeviceHardware(gpu: fits).validate().isEmpty)
        let long = DeviceHardware.GPU(glVersion: String(repeating: "v", count: 92))
        #expect(DeviceHardware(gpu: long).validate() == ["gpu.glVersion is longer than 91 bytes"])
        let twoLines = DeviceHardware.GPU(glRenderer: "Adreno\n750")
        #expect(DeviceHardware(gpu: twoLines).validate() == ["gpu.glRenderer contains a newline"])
    }

    @Test func hardwareValidationChecksCPUClusters() {
        let good = DeviceHardware.CPU(clusters: [.init(cores: 1, implementer: 0x41, part: 0xD82, maxFreqKHz: 3_300_000)])
        #expect(DeviceHardware(cpu: good).validate().isEmpty)
        let noCores = DeviceHardware.CPU(clusters: [])
        #expect(DeviceHardware(cpu: noCores).validate().contains("cpu has no clusters"))
        let badFreq = DeviceHardware.CPU(clusters: [.init(cores: 2, implementer: 0x41, part: 0xD81, maxFreqKHz: 1000, minFreqKHz: 2000)])
        #expect(DeviceHardware(cpu: badFreq).validate().contains("cpu cluster 0 min frequency above max"))
    }

    @Test func profileWithoutHardwareHasNoneToEmulate() {
        let profile = DeviceProfile(id: "x", name: "X", properties: Self.validProperties)
        #expect(!profile.hasHardware)
        #expect(profile.properties(emulateHardware: true) == Self.validProperties)
    }
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
