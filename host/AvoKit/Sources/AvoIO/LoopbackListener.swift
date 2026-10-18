import Foundation
import os

/// A TCP listener on the Mac's loopback addresses only (127.0.0.1 and ::1),
/// so nothing outside this Mac can connect.
public final class LoopbackListener: @unchecked Sendable {
    public let port: UInt16
    private let sources: [any DispatchSourceRead]

    /// Listens on `port` and calls `accept` with each connected socket (in
    /// blocking mode; the handler owns it). Throws when the port is taken.
    public init(port: UInt16, label: String, accept: @escaping @Sendable (Int32) -> Void) throws {
        self.port = port
        let queue = DispatchQueue(label: label)
        var sockets: [Int32] = []
        do {
            sockets.append(try Self.bind(family: AF_INET, port: port))
            // IPv6 is optional: some Macs turn it off.
            if let v6 = try? Self.bind(family: AF_INET6, port: port) { sockets.append(v6) }
        } catch {
            sockets.forEach { Darwin.close($0) }
            throw error
        }
        sources = sockets.map { listener in
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            source.setEventHandler {
                while true {
                    let fd = Darwin.accept(listener, nil, nil)
                    guard fd >= 0 else { return } // EAGAIN: no more pending connections
                    // Accepted sockets inherit O_NONBLOCK on Darwin.
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                    FileDescriptorStream.disableSIGPIPE(fd)
                    accept(fd)
                }
            }
            source.setCancelHandler { Darwin.close(listener) }
            source.resume()
            return source
        }
    }

    deinit { close() }

    /// Stops listening; connections already accepted are not affected.
    public func close() {
        for source in sources where !source.isCancelled { source.cancel() }
    }

    private static func bind(family: Int32, port: UInt16) throws -> Int32 {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IOError.errno("socket") }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound: Int32
        if family == AF_INET6 {
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let error = IOError.errno("bind port \(port)")
            Darwin.close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }
}

/// Copies bytes both ways between two connected sockets until both
/// directions end, then closes them. Blocking reads and writes on two
/// threads give natural backpressure (an `adb push` of a large file never
/// piles up in memory).
public final class SocketSplice: @unchecked Sendable {
    private let a: Int32
    private let b: Int32
    private let state = OSAllocatedUnfairLock(initialState: (finished: 0, closed: false))

    /// Takes ownership of both sockets.
    public init(_ a: Int32, _ b: Int32, name: String) {
        self.a = a
        self.b = b
        FileDescriptorStream.disableSIGPIPE(a)
        FileDescriptorStream.disableSIGPIPE(b)
        for (from, to) in [(a, b), (b, a)] {
            let thread = Thread { [self] in pump(from: from, to: to) }
            thread.name = name
            thread.start()
        }
    }

    /// Both directions ended and the sockets are closed.
    public var isFinished: Bool { state.withLock { $0.closed } }

    /// Ends both directions (the pump threads then close the sockets).
    public func cancel() {
        state.withLock { state in
            guard !state.closed else { return }
            shutdown(a, SHUT_RDWR)
            shutdown(b, SHUT_RDWR)
        }
    }

    private func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        copying: while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(from, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { Darwin.write(to, $0.baseAddress! + offset, count - offset) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { break copying }
                offset += written
            }
        }
        // Pass the end of the stream on; the other direction may still run.
        shutdown(to, SHUT_WR)
        shutdown(from, SHUT_RD)
        state.withLock { state in
            state.finished += 1
            if state.finished == 2 {
                state.closed = true
                Darwin.close(a)
                Darwin.close(b)
            }
        }
    }
}
