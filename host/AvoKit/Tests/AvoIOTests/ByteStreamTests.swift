import Foundation
import Testing
@testable import AvoIO

@Suite struct ByteStreamTests {
    @Test func socketPairRoundTrip() async throws {
        let (a, b) = try UnixSocket.pair()
        let left = FileDescriptorStream(fileDescriptor: a)
        let right = FileDescriptorStream(fileDescriptor: b)
        defer { left.close(); right.close() }

        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        async let sent: Void = left.write(payload)
        var reader = StreamReader(right)
        let received = try await reader.read(exactly: payload.count)
        try await sent
        #expect(received == payload)
    }

    @Test func endOfStreamFinishesIncoming() async throws {
        let (a, b) = try UnixSocket.pair()
        let left = FileDescriptorStream(fileDescriptor: a)
        let right = FileDescriptorStream(fileDescriptor: b)
        try await left.write(Data("bye".utf8))
        left.close()
        var collected = Data()
        for try await chunk in right.incoming { collected.append(chunk) }
        #expect(collected == Data("bye".utf8))
        right.close()
    }

    @Test func writingToAClosedPeerThrowsInsteadOfSIGPIPE() async throws {
        let (a, b) = try UnixSocket.pair()
        let left = FileDescriptorStream(fileDescriptor: a)
        close(b)
        await #expect(throws: (any Error).self) {
            for _ in 0..<64 { try await left.write(Data(count: 64 * 1024)) }
        }
        left.close()
    }
}

@Suite struct VsockBridgeTests {
    /// A fake engine that accepts one connection and runs `handler` on it,
    /// on a thread of its own started at once: its blocking accept and reads
    /// must not wait for a turn in the concurrency pool, which other tests
    /// may fill (a runner with few cores), or the handshake times out.
    private func fakeEngine(_ handler: @escaping @Sendable (Int32) throws -> Void) throws -> (path: String, done: Task<Void, any Error>) {
        let path = "/tmp/avo-test-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocket.listen(path: path)
        let (outcome, finished) = AsyncThrowingStream<Void, any Error>.makeStream()
        Thread {
            defer { close(listener); unlink(path) }
            do {
                let client = try UnixSocket.accept(listener)
                defer { close(client) }
                try handler(client)
                finished.finish()
            } catch {
                finished.finish(throwing: error)
            }
        }.start()
        return (path, Task { for try await _ in outcome {} })
    }

    @Test func connectsThroughHybridVsockHandshake() async throws {
        let engine = try fakeEngine { fd in
            let line = try UnixSocket.readLine(fd, deadline: .now + .seconds(5))
            #expect(line == "CONNECT 6000")
            // The guest may speak first: data right after the OK line must not be lost.
            try UnixSocket.writeAll(fd, Array("OK 1073741824\nHELLO".utf8))
            var buffer = [UInt8](repeating: 0, count: 4)
            var got = 0
            while got < 4 {
                let n = read(fd, &buffer[got], 4 - got)
                if n <= 0 { break }
                got += n
            }
            try UnixSocket.writeAll(fd, buffer)
        }
        let stream = try VsockBridge.connect(socketPath: engine.path, port: 6000)
        defer { stream.close() }
        var reader = StreamReader(stream)
        #expect(try await reader.read(exactly: 5) == Data("HELLO".utf8))
        try await stream.write(Data("ping".utf8))
        #expect(try await reader.read(exactly: 4) == Data("ping".utf8))
        try await engine.done.value
    }

    @Test func reportsRefusedPorts() async throws {
        let engine = try fakeEngine { fd in
            _ = try UnixSocket.readLine(fd, deadline: .now + .seconds(5))
            try UnixSocket.writeAll(fd, Array("FAILURE no listener\n".utf8))
        }
        #expect(throws: IOError.handshake("engine replied \"FAILURE no listener\" for port 6001")) {
            try VsockBridge.connect(socketPath: engine.path, port: 6001)
        }
        try await engine.done.value
    }

    @Test func rejectsOverlongSocketPaths() {
        let path = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: IOError.pathTooLong(path)) { try UnixSocket.connect(path: path) }
    }
}
