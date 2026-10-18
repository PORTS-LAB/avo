import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// Android's display rate: one per boot, the frame rate cap above 60
/// (FrameRates), whatever the Mac's screens; a cap that needs another rate
/// waits for a restart.
@Suite(.serialized, .timeLimit(.minutes(1))) struct RefreshRateTests {
    @Test func androidBootsAtTheCapsRateAndPlugsEveryDisplayAtIt() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")],
                                  configure: { $0.fpsLimit = 120 })
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, events) = await harness.connect(.shim(package: "org.fdroid.fdroid"))
        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: "org.fdroid.fdroid", width: 824, height: 1784, dpi: 320),
                                                         client: shim)
        #expect(await events.wait { $0 == .displayReady(displayID: display) } != nil)
        let launch = try #require(harness.engine.launches.first)
        #expect(launch.displayRate == 120)
        #expect(VMMEngine.arguments(images: URL(filePath: "/img"), launch: launch).suffix(2) == ["--refresh-rate", "120"])
        let launches = await harness.agent.requests { if case .launch(let l) = $0 { l } else { nil } }
        #expect(launches.first?.refreshRate == 120)
        #expect(await !harness.core.configurationSnapshot().pendingRestart)
    }

    /// A 75 Hz monitor's own rate: Android runs in step with it.
    @Test func aScreensOwnRateIsADisplayRate() async throws {
        let harness = try Harness(apps: [], configure: { $0.fpsLimit = 75 })
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let launch = try #require(harness.engine.launches.first)
        #expect(launch.displayRate == 75)
        #expect(VMMEngine.arguments(images: URL(filePath: "/img"), launch: launch).suffix(2) == ["--refresh-rate", "75"])

        let (shim, _) = await harness.connect(.shim(package: "com.x"))
        // 60 is no render rate of 75 Hz (Android would make 37.5 of it): a restart.
        #expect(try await harness.core.setFrameRateLimit(60, client: shim).effect == .restartRequired)
        #expect(await harness.core.configurationSnapshot().pendingRestart)
        #expect(try await harness.core.setFrameRateLimit(75, client: shim).effect == .immediate)
        #expect(await !harness.core.configurationSnapshot().pendingRestart)
        // Neither a cap Android cannot run at.
        let tooFast = try await harness.core.setFrameRateLimit(144, client: shim)
        #expect(tooFast.issues.contains { $0.field == "fpsLimit" && $0.severity == .error })
        #expect(await harness.core.config.fpsLimit == 75)
    }

    @Test func sixtyStaysTheDefaultAndAHigherCapWaitsForARestart() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        let launch = try #require(harness.engine.launches.first)
        #expect(launch.displayRate == 60)
        #expect(!VMMEngine.arguments(images: URL(filePath: "/img"), launch: launch).contains("--refresh-rate"))

        // No screen of the Mac needs to show it (none here).
        let (shim, _) = await harness.connect(.shim(package: "com.x"))
        let faster = try await harness.core.setFrameRateLimit(120, client: shim)
        #expect(faster.effect == .restartRequired)
        #expect(await harness.core.configurationSnapshot().pendingRestart)
        // Half of 60 is a render rate of the running displays: at once.
        let slower = try await harness.core.setFrameRateLimit(30, client: shim)
        #expect(slower.effect == .immediate)
        #expect(await !harness.core.configurationSnapshot().pendingRestart)
    }

    @Test func refreshRateFlagsOnlyAbove60() {
        #expect(VMMEngine.refreshRateFlags(60).isEmpty)
        #expect(VMMEngine.refreshRateFlags(90) == ["--refresh-rate", "90"])
        #expect(VMMEngine.refreshRateFlags(75) == ["--refresh-rate", "75"])
    }
}
