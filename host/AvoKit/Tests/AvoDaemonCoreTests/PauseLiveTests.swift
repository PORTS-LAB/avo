import AvoADB
import AvoIO
import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct EngineUsageTests {
    /// What the menu bar shows of the engine, read here of this process.
    @Test func cpuAndMemoryOfAProcess() throws {
        let usage = try #require(VMMEngine.usage(of: getpid()))
        #expect(usage.cpu > .zero)
        #expect(usage.resident > 1 << 20)
        #expect(VMMEngine.usage(of: -1) == nil)
    }
}

/// Against a running avo-vmm with Android booted, from its directory (the
/// sockets are relative there): AVO_LIVE_TEST_VM=<dir with runtime/>.
/// Pauses Android through the engine as VMMEngine does, and puts its
/// clock right with HostAgent afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AVO_LIVE_TEST_VM"] != nil), .serialized)
struct PauseLiveTests {
    func hostMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    @Test(.timeLimit(.minutes(5))) func aPausedAndroidStandsStillAndItsClockIsPutRight() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AVO_LIVE_TEST_VM"])
        #expect(FileManager.default.changeCurrentDirectoryPath(directory))
        let control = EngineControl(socketPath: "runtime/control.sock")
        let key = try ADBKey.generate()
        let agent = HostAgent(engine: control, frames: FrameBridge { _ in }, adbKey: key) { port in
            try VsockBridge.connect(socketPath: "runtime/vsock.sock", port: port)
        }
        try await agent.prepare(deadline: .now + .seconds(180))
        // Our own adb, to read Android's clock.
        let adb = ADBConnection(transport: try VsockBridge.connect(socketPath: "runtime/vsock.sock", port: HostAgent.adbPort),
                                key: key, keyComment: "avo-live-test")
        _ = try await adb.connect(timeout: .seconds(20))
        func lag() async throws -> Int64 {
            let guest = try #require(Int64(try await adb.shell("date +%s%3N").output.trimmingCharacters(in: .whitespacesAndNewlines)))
            return hostMillis() - guest
        }
        let before = try await lag()
        #expect(abs(before) < 1500, "Android follows the Mac's clock: \(before) ms")

        await agent.setPaused(true)
        try await control.send("pause")
        let pausedAt = ContinuousClock.now
        // A command for a paused Android waits for it.
        let waiting = Task { try await adb.shell("echo answered").output }
        try await Task.sleep(for: .seconds(5))
        try await control.send("pause") // twice is fine
        try await control.send("resume")
        let pausedFor = ContinuousClock.now - pausedAt
        await agent.setPaused(false)
        #expect(try await waiting.value.contains("answered"))

        let behind = try await lag()
        #expect(abs(behind - before - Int64(pausedFor / .milliseconds(1))) < 1500, "the clock stood still: \(behind) ms behind")
        await agent.clockResumed(after: pausedFor)
        let after = try await lag()
        #expect(abs(after) < 1500, "put right: \(after) ms")
        print("live pause: lag before \(before) ms, after the pause \(behind) ms, put right \(after) ms (paused \(pausedFor))")
        await adb.close()
        await agent.shutdown() // powers the test VM off
    }
}
