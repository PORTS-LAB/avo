import AvoKit
import Foundation
import IOSurface
import Testing
@testable import AvoDaemonCore

/// Android's frames from the engine's shared memory (frames.rs) on their way
/// to the App Shims.
@Suite(.timeLimit(.minutes(1))) struct FrameBridgeTests {
    /// A consumer that falls behind skips frames, never a swapchain (the
    /// window would go on drawing the old one) nor anything else.
    @Test func aBusyConsumerSkipsOnlyPresents() async {
        let queue = FrameDeliveryQueue()
        queue.push(.surfaces(displayID: 1, []))
        for sequence in 1...300 { queue.push(.present(displayID: 1, surfaceIndex: sequence % 3, sequence: UInt64(sequence))) }
        queue.push(.firstFrame(displayID: 1))
        queue.push(.present(displayID: 2, surfaceIndex: 0, sequence: 7))
        queue.push(.present(displayID: 1, surfaceIndex: 1, sequence: 301))
        // A new layout numbers its frames from 1 again.
        queue.push(.surfaces(displayID: 1, []))
        queue.push(.present(displayID: 1, surfaceIndex: 0, sequence: 1))
        queue.push(.present(displayID: 1, surfaceIndex: 1, sequence: 2))
        queue.push(.microphone)
        var seen: [String] = []
        for _ in 0..<8 { seen.append(Self.describe(await queue.next())) }
        #expect(seen == ["surfaces 1 0", "present 1 0 300", "first 1", "present 2 0 7", "present 1 1 301",
                         "surfaces 1 0", "present 1 1 2", "microphone"])
    }

    @Test func theConsumerWaitsAndStops() async throws {
        let queue = FrameDeliveryQueue()
        let waiting = Task { await queue.next() }
        try await Task.sleep(for: .milliseconds(50))
        queue.push(.microphone)
        #expect(Self.describe(await waiting.value) == "microphone")
        // Cancelling the consumer of the engine's stream (as VMMEngine makes it) ends it.
        let stream = AsyncStream(unfolding: { await queue.next() }, onCancel: { queue.finish() })
        let consumer = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await consumer.value
        queue.push(.microphone)
        #expect(await queue.next() == nil)
    }

    /// Each frame event copies the newest frame; an event whose frame is
    /// already behind a newer one is skipped, as the newer one's follows.
    @Test func copiesOnlyTheNewestFrame() throws {
        let file = try EngineFrames()
        defer {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        let delivered = Delivered()
        let bridge = FrameBridge { delivered.add($0) }
        bridge.assign(scanout: 0, to: 9)
        bridge.handle("frames 0 1 2 2 8 0 \(file.url.path)")
        try file.publish(1)
        bridge.handle("frame 0 1")
        try file.publish(2)
        try file.publish(3)
        bridge.handle("frame 0 2")
        bridge.handle("frame 0 3")
        #expect(delivered.descriptions == ["surfaces 9 3", "present 9 0 1", "first 9", "present 9 1 3"])
        let surfaces = try #require(delivered.surfaces)
        #expect(Self.pixels(surfaces[0]) == [UInt8](repeating: 1, count: 16))
        #expect(Self.pixels(surfaces[1]) == [UInt8](repeating: 3, count: 16))
    }

    /// A window nobody sees gets no copies after its first frame; shown
    /// again, it gets the newest frame at once, not one from before.
    @Test func hiddenWindowsGetNoCopiesUntilTheyShowAgain() throws {
        let file = try EngineFrames()
        defer {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        let delivered = Delivered()
        let bridge = FrameBridge { delivered.add($0) }
        bridge.assign(scanout: 0, to: 9)
        bridge.setVisible(9, visible: false)
        bridge.handle("frames 0 1 2 2 8 0 \(file.url.path)")
        try file.publish(1)
        bridge.handle("frame 0 1")
        try file.publish(2)
        bridge.handle("frame 0 2")
        try file.publish(3)
        bridge.handle("frame 0 3")
        #expect(delivered.descriptions == ["surfaces 9 3", "present 9 0 1", "first 9"])
        bridge.setVisible(9, visible: true)
        #expect(delivered.descriptions.last == "present 9 1 3")
        let surfaces = try #require(delivered.surfaces)
        #expect(Self.pixels(surfaces[1]) == [UInt8](repeating: 3, count: 16))
        // Visible again: every frame.
        try file.publish(4)
        bridge.handle("frame 0 4")
        #expect(delivered.descriptions.last == "present 9 2 4")
        // Shown twice copies nothing more; a new window on the scanout starts visible.
        bridge.setVisible(9, visible: true)
        #expect(delivered.descriptions.count == 5)
        bridge.setVisible(9, visible: false)
        bridge.assign(scanout: 0, to: 10)
        try file.publish(5)
        bridge.handle("frame 0 5")
        try file.publish(6)
        bridge.handle("frame 0 6")
        #expect(delivered.descriptions.suffix(2) == ["first 10", "present 10 1 6"])
    }

    // MARK: Helpers

    private static func describe(_ delivery: FrameDelivery?) -> String {
        guard let delivery else { return "end" }
        if case let .surfaces(id, surfaces) = delivery { return "surfaces \(id) \(surfaces.count)" }
        if case let .present(id, index, sequence) = delivery { return "present \(id) \(index) \(sequence)" }
        if case let .firstFrame(id) = delivery { return "first \(id)" }
        return "\(delivery)"
    }

    /// The 2×2 frame in `surface`, row by row.
    private static func pixels(_ surface: IOSurface) -> [UInt8] {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        return (0..<2).flatMap { y in (0..<8).map { base[y * surface.bytesPerRow + $0] } }
    }

    /// A frames file as avo-vmm writes it, for a 2×2 BGRA layout.
    private struct EngineFrames {
        static let bufferSize = 4096
        let url: URL
        let handle: FileHandle

        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "avo-frames-\(UUID().uuidString).frames")
            var file = Data(count: 4096 + 3 * Self.bufferSize)
            func put(_ value: UInt32, at offset: Int) {
                withUnsafeBytes(of: value.littleEndian) { file.replaceSubrange(offset..<offset + 4, with: $0) }
            }
            file.replaceSubrange(0..<4, with: Array("AVOF".utf8))
            for (offset, value) in [(4, 1), (8, 1), (12, 2), (16, 2), (20, 8), (24, 0), (28, 3), (32, 4096), (36, Self.bufferSize)] {
                put(UInt32(value), at: offset)
            }
            try file.write(to: url)
            handle = try FileHandle(forWritingTo: url)
        }

        /// Frame `sequence`, every byte of it that number, published as frames.rs does.
        func publish(_ sequence: UInt64) throws {
            let buffer = Int(sequence % 3)
            try handle.seek(toOffset: UInt64(4096 + buffer * Self.bufferSize))
            try handle.write(contentsOf: Data(repeating: UInt8(sequence), count: 16))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: withUnsafeBytes(of: UInt32(buffer).littleEndian) { Data($0) })
            try handle.seek(toOffset: 48)
            try handle.write(contentsOf: withUnsafeBytes(of: sequence.littleEndian) { Data($0) })
        }
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveries: [FrameDelivery] = []

        func add(_ delivery: FrameDelivery) { lock.withLock { deliveries.append(delivery) } }

        var descriptions: [String] { lock.withLock { deliveries.map { FrameBridgeTests.describe($0) } } }

        var surfaces: [IOSurface]? {
            lock.withLock { deliveries.lazy.compactMap { if case let .surfaces(_, surfaces) = $0 { surfaces } else { nil } }.first }
        }
    }
}
