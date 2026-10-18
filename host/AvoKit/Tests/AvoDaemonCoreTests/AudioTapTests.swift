import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Android's sound for screen recordings: the engine's `audio playback`
/// event reaches the App Shims, also those that connect later.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AudioTapTests {
    private let location = AudioTapLocation(path: "/tmp/avo test/audio/playback.ring", epoch: 42)

    @Test func theEnginesEventSaysWhereTheRingIs() {
        let delivered = Delivered()
        let bridge = FrameBridge { delivered.add($0) }
        bridge.handle("audio playback 42 /tmp/avo test/audio/playback.ring")
        bridge.handle("audio playback nonsense")
        bridge.handle("sound playback on")
        #expect(delivered.taps == [location])
    }

    @Test func appShimsHearWhereTheRingIs() async throws {
        let harness = try Harness(apps: [])
        defer { harness.cleanUp() }
        let (_, early) = await harness.connect(.shim(package: "org.example.game"))
        let (_, panel) = await harness.connect(.controlPanel)
        await harness.core.engineAudioTap(location)
        let tap: (DaemonEvent) -> Bool = { if case .audioTap = $0 { true } else { false } }
        #expect(await early.wait(for: tap) == .audioTap(location))
        // A shim that connects later is told at once; Control Panels have no use for it.
        let (_, late) = await harness.connect(.shim(package: "org.example.player"))
        #expect(late.events.contains(.audioTap(location)))
        #expect(!panel.events.contains(where: tap))
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveries: [FrameDelivery] = []

        func add(_ delivery: FrameDelivery) { lock.withLock { deliveries.append(delivery) } }

        var taps: [AudioTapLocation] {
            lock.withLock { deliveries.compactMap { if case let .audioTap(location) = $0 { location } else { nil } } }
        }
    }
}
