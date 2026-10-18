import Foundation
import Testing
@testable import AvoIO

@Suite struct LoopbackListenerTests {
    /// A free loopback port (the listener needs a fixed one).
    private func listen(accept: @escaping @Sendable (Int32) -> Void) throws -> LoopbackListener {
        for _ in 0..<20 {
            if let listener = try? LoopbackListener(port: UInt16.random(in: 40000...60000), label: "test", accept: accept) {
                return listener
            }
        }
        throw IOError.closed
    }

    private func connect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw IOError.errno("connect") }
        return fd
    }

    @Test func splicesAClientToTheOtherSide() async throws {
        // The far side (adbd in Android) is an echo server on a socket pair.
        let listener = try listen { client in
            guard let (near, far) = try? UnixSocket.pair() else { return }
            _ = SocketSplice(client, near, name: "test")
            Thread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(far, &buffer, buffer.count)
                    guard n > 0 else { break }
                    _ = buffer.withUnsafeBytes { write(far, $0.baseAddress, n) }
                }
                close(far)
            }.start()
        }
        defer { listener.close() }

        let fd = try connect(port: listener.port)
        defer { close(fd) }
        let payload = Array((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        // Write on another thread: the echo comes back while we send.
        Thread {
            var offset = 0
            while offset < payload.count {
                let n = payload.withUnsafeBytes { write(fd, $0.baseAddress! + offset, min(65536, payload.count - offset)) }
                guard n > 0 else { return }
                offset += n
            }
            shutdown(fd, SHUT_WR)
        }.start()
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while received.count < payload.count {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            received += buffer[0..<n]
        }
        #expect(received == payload)
    }

    @Test func aTakenPortIsReported() throws {
        let first = try listen { close($0) }
        defer { first.close() }
        #expect(throws: (any Error).self) { try LoopbackListener(port: first.port, label: "test") { close($0) } }
    }
}
