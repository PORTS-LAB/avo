import Foundation
import Testing
@testable import AvoKit

let macBook16 = HostInfo(physicalMemoryBytes: 16 << 30, performanceCores: 4, efficiencyCores: 4,
                         isAppleSilicon: true, macOSVersion: "27.0")
let macStudio64 = HostInfo(physicalMemoryBytes: 64 << 30, performanceCores: 12, efficiencyCores: 4,
                           isAppleSilicon: true, macOSVersion: "27.0")
let macMini8 = HostInfo(physicalMemoryBytes: 8 << 30, performanceCores: 4, efficiencyCores: 4,
                        isAppleSilicon: true, macOSVersion: "27.0")

@Suite struct VMConfigTests {
    @Test func defaultsAreValid() {
        #expect(VMConfig().validate(previous: nil, host: macBook16).filter { $0.severity == .error }.isEmpty)
    }

    @Test func recommendedFitsTheHost() {
        let small = VMConfig.recommended(for: macMini8)
        #expect(small.memoryMiB == 4096)
        #expect(small.cpuCount == 4)
        let big = VMConfig.recommended(for: macStudio64)
        #expect(big.memoryMiB == 8192)
        #expect(big.cpuCount == 8)
        #expect(big.validate(previous: nil, host: macStudio64).isEmpty)
    }

    @Test func maxGuestMemoryLeavesRoomForMacOS() {
        #expect(macMini8.maxGuestMemoryMiB == 4096)
        #expect(macBook16.maxGuestMemoryMiB == 12288)
        #expect(macStudio64.maxGuestMemoryMiB == 16384) // capped by the spec
    }

    @Test(arguments: [1024, 2000, 20480]) func rejectsMemoryOutsideSpec(memory: Int) {
        var config = VMConfig()
        config.memoryMiB = memory
        #expect(config.validate(previous: nil, host: macStudio64).contains { $0.field == "memoryMiB" && $0.severity == .error })
    }

    @Test func rejectsMoreMemoryThanTheMacCanSpare() {
        var config = VMConfig()
        config.memoryMiB = 8192
        let issues = config.validate(previous: nil, host: macMini8)
        #expect(issues.contains { $0.field == "memoryMiB" && $0.severity == .error })
    }

    @Test func dataDiskCanGrowButNotShrink() {
        let current = VMConfig(dataDiskGiB: 64)
        var smaller = current
        smaller.dataDiskGiB = 32
        #expect(smaller.validate(previous: current, host: macBook16).contains { $0.field == "dataDiskGiB" })
        var bigger = current
        bigger.dataDiskGiB = 128
        #expect(!bigger.validate(previous: current, host: macBook16).contains { $0.field == "dataDiskGiB" })
    }

    @Test func fpsMustBeAKnownStep() {
        var config = VMConfig()
        config.fpsLimit = 75
        #expect(config.validate(previous: nil, host: macBook16).contains { $0.field == "fpsLimit" })
        for fps in VMConfig.fpsChoices {
            config.fpsLimit = fps
            #expect(!config.validate(previous: nil, host: macBook16).contains { $0.field == "fpsLimit" })
        }
    }

    @Test func coresBeyondPerformanceCoresWarn() {
        var config = VMConfig()
        config.cpuCount = 6
        let issues = config.validate(previous: nil, host: macBook16)
        #expect(issues.contains { $0.field == "cpuCount" && $0.severity == .warning })
        config.cpuCount = 9
        #expect(config.validate(previous: nil, host: macBook16).contains { $0.field == "cpuCount" && $0.severity == .error })
    }

    @Test func heavyGamePreset() {
        var config = VMConfig(memoryMiB: 4096)
        config.applyHeavyGamePreset(host: macStudio64)
        #expect(config.renderer == .vulkan)
        #expect(config.fpsLimit == 120)
        #expect(config.memoryMiB == 8192)

        // A Mac that cannot spare 8 GB keeps its memory and gets a warning instead.
        var small = VMConfig(memoryMiB: 4096)
        small.applyHeavyGamePreset(host: macMini8)
        #expect(small.memoryMiB == 4096)
        #expect(small.validate(previous: nil, host: macMini8).contains { $0.severity == .warning && $0.field == "memoryMiB" })
    }

    // Spec §6: which tabs need a restart.
    @Test func restartRulesFollowTheSpecTable() {
        let base = VMConfig()
        func effect(_ change: (inout VMConfig) -> Void) -> ConfigChangeEffect {
            var updated = base
            change(&updated)
            return updated.effect(of: base)
        }
        #expect(effect { $0.memoryMiB = 6144 } == .restartRequired)          // Performa
        #expect(effect { $0.cpuCount = 2 } == .restartRequired)
        #expect(effect { $0.balloonWhenIdle.toggle() } == .restartRequired)
        #expect(effect { $0.dataDiskGiB = 64 } == .restartRequired)          // Storage (resize)
        #expect(effect { $0.renderer = .gles } == .restartRequired)          // Grafis: partly
        #expect(effect { $0.fpsLimit = 120 } == .immediate)
        #expect(effect { $0.defaultDPI = 280 } == .newWindows)
        #expect(effect { $0.defaultOrientation = .landscape } == .newWindows) // Display: no restart
        #expect(effect { $0.retinaScaling.toggle() } == .newWindows)
        #expect(effect { $0.rooted = true } == .restartRequired)             // Sistem
        #expect(effect { $0.deviceProfileID = "xiaomi-14" } == .restartRequired)
        #expect(effect { $0.createDesktopAlias.toggle() } == .immediate)
        #expect(base.effect(of: base) == .immediate)
        #expect(effect { $0.fpsLimit = 30; $0.cpuCount = 2 } == .restartRequired)
    }

    @Test func persistsAsJSON() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "avo-config-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = VMConfig()
        config.gms = .microG
        config.defaultDPI = 300
        try config.save(to: url)
        #expect(try VMConfig.load(from: url) == config)
    }
}

@Suite struct IdentifierTests {
    @Test func shimBundleIdentifiersAreValid() {
        #expect(AvoIdentifiers.shimBundleIdentifier(for: "com.example.app") == "dev.avo.shim.com.example.app")
        #expect(AvoIdentifiers.shimBundleIdentifier(for: "org.my_app.free") == "dev.avo.shim.org.my-app.free")
        #expect(AvoIdentifiers.package(fromShimBundleIdentifier: "dev.avo.shim.com.example") == "com.example")
        #expect(AvoIdentifiers.package(fromShimBundleIdentifier: "com.other") == nil)
    }

    @Test func prefixMatchesXcodeConfiguration() throws {
        // host/Config/Base.xcconfig must agree with AvoIdentifiers.prefix.
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../")
        let xcconfig = root.appending(path: "Config/Base.xcconfig").standardizedFileURL
        guard let text = try? String(contentsOf: xcconfig, encoding: .utf8) else {
            Issue.record("missing \(xcconfig.path)")
            return
        }
        #expect(text.contains("AVO_BUNDLE_ID_PREFIX = \(AvoIdentifiers.prefix)\n"))
    }

    @Test func pathsUseShortRuntimeDirectory() throws {
        let paths = AvoPaths(home: URL(filePath: "/Users/someone-with-a-long-name"),
                             temporaryDirectory: URL(filePath: "/var/folders/ab/cdefghijklmnopqrstuvwxyz0000gn/T"))
        #expect(paths.shims.path == "/Users/someone-with-a-long-name/Applications/Android Apps")
        #expect(paths.vsockSocket.path.hasSuffix("/T/dev.avo/vsock.sock"))
        try paths.validateSocketPaths()
    }
}
