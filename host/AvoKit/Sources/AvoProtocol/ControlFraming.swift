import Foundation
import SwiftProtobuf

public enum ControlFramingError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case malformedLength
    case malformedEnvelope(String)
}

/// Length-delimited encoding of Control channel envelopes (varint length + bytes).
public enum ControlFraming {
    public static func encode(_ envelope: Avo_V1_Envelope) throws -> Data {
        let body: Data = try envelope.serializedData()
        guard body.count <= AvoProtocol.maxFrameSize else {
            throw ControlFramingError.frameTooLarge(body.count)
        }
        var frame = Data(capacity: body.count + 5)
        var length = UInt64(body.count)
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length != 0 { byte |= 0x80 }
            frame.append(byte)
        } while length != 0
        frame.append(body)
        return frame
    }
}

/// Incremental decoder for a Control channel byte stream.
///
/// Feed bytes as they arrive with `append(_:)`, then drain complete envelopes
/// with `next()` until it returns `nil`.
public struct ControlFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public var bufferedByteCount: Int { buffer.count - start }

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    public mutating func next() throws(ControlFramingError) -> Avo_V1_Envelope? {
        var length = 0
        var shift = 0
        var index = start
        while true {
            guard index < buffer.count else { return nil }
            let byte = buffer[index]
            index += 1
            length |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            // 8 MiB fits in four varint bytes; anything longer is garbage.
            guard shift < 28 else { throw .malformedLength }
        }
        guard length <= AvoProtocol.maxFrameSize else { throw .frameTooLarge(length) }
        guard buffer.count - index >= length else { return nil }

        let body = Data(buffer[index..<(index + length)])
        start = index + length
        compactIfNeeded()
        do {
            return try Avo_V1_Envelope(serializedBytes: body)
        } catch {
            throw .malformedEnvelope(String(describing: error))
        }
    }

    private mutating func compactIfNeeded() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1024 && start > buffer.count / 2 {
            buffer.removeFirst(start)
            start = 0
        }
    }
}
