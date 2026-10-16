import Foundation
import Testing
@testable import AvoProtocol

@Suite struct InputWireTests {
    static let samples: [InputRecord] = [
        .touch(TouchEvent(displayID: 2, action: .down, pointers: [TouchPointer(id: 0, x: 10.5, y: 20.25)])),
        .touch(TouchEvent(displayID: 2, action: .pointerDown, actionIndex: 1, pointers: [
            TouchPointer(id: 0, x: 10, y: 20), TouchPointer(id: 4, x: 300, y: 400, pressure: 0.5),
        ])),
        .key(KeyEvent(displayID: 5, action: .down, keyCode: 111, metaState: 0x1000, repeatCount: 2, scanCode: 1)),
        .scroll(ScrollEvent(displayID: 1, x: 100, y: 200, horizontal: -0.5, vertical: 2, buttons: 0)),
        .text(displayID: 1, "Halo, dunia! 🥑"),
        .mouse(MouseEvent(displayID: 3, action: .buttonPress, x: 1, y: 2, buttons: 2, actionButton: 2)),
        .gamepad(GamepadState(pad: 1, buttons: 0b1011, axes: [0.1, -0.2, 0.3, -0.4, 1, 0, -1, 1])),
        .ping(token: 0xDEAD_BEEF_CAFE),
    ]

    @Test(arguments: samples) func roundTrips(record: InputRecord) throws {
        let bytes = try InputWire.encode(record)
        let decoded = try #require(try InputWire.decode(bytes[...]))
        #expect(decoded.consumed == bytes.count)
        #expect(decoded.record == record)
        // Length field matches the actual record size.
        #expect(Int(bytes[2]) | Int(bytes[3]) << 8 == bytes.count)
    }

    @Test func documentedSizes() throws {
        #expect(try InputWire.encode(Self.samples[0]).count == 16 + 16)
        #expect(try InputWire.encode(Self.samples[1]).count == 16 + 32)
        #expect(try InputWire.encode(Self.samples[2]).count == 28)
        #expect(try InputWire.encode(Self.samples[3]).count == 28)
        #expect(try InputWire.encode(Self.samples[5]).count == 28)
        #expect(try InputWire.encode(Self.samples[6]).count == 48)
        #expect(try InputWire.encode(Self.samples[7]).count == 16)
    }

    @Test func touchLayoutIsLittleEndian() throws {
        let bytes = try InputWire.encode(.touch(TouchEvent(displayID: 0x0102_0304, action: .move,
                                                          pointers: [TouchPointer(id: 9, x: 1, y: 2, pressure: 1)])))
        #expect(bytes[0] == 0x01)
        #expect(Array(bytes[4..<8]) == [0x04, 0x03, 0x02, 0x01])
        #expect(bytes[8] == TouchAction.move.rawValue)
        #expect(bytes[10] == 1)
        #expect(Array(bytes[16..<20]) == [9, 0, 0, 0])
        #expect(Array(bytes[20..<24]) == [0x00, 0x00, 0x80, 0x3F]) // 1.0f
    }

    @Test func streamDecoderHandlesSplitsAndSkipsUnknownTypes() throws {
        var stream: [UInt8] = []
        for record in Self.samples { stream += try InputWire.encode(record) }
        // An unknown record type (0x42) with a 12-byte body must be skipped.
        let unknown: [UInt8] = [0x42, 0, 12, 0, 0, 0, 0, 0, 1, 2, 3, 4]
        stream.insert(contentsOf: unknown, at: 0)

        var decoder = InputRecordDecoder()
        var out: [InputRecord] = []
        for byte in stream {
            decoder.append([byte])
            while let record = try decoder.next() { out.append(record) }
        }
        #expect(out == Self.samples)
    }

    @Test func rejectsTooManyPointers() {
        let pointers = (0..<17).map { TouchPointer(id: UInt32($0), x: 0, y: 0) }
        #expect(throws: InputWireError.tooManyPointers(17)) {
            try InputWire.encode(.touch(TouchEvent(displayID: 1, action: .move, pointers: pointers)))
        }
    }

    @Test func rejectsOversizedText() {
        let text = String(repeating: "a", count: InputWire.maxTextBytes + 1)
        #expect(throws: InputWireError.textTooLong(InputWire.maxTextBytes + 1)) {
            try InputWire.encode(.text(displayID: 1, text))
        }
    }

    @Test func rejectsCorruptLength() {
        let bytes: [UInt8] = [0x01, 0, 4, 0, 0, 0, 0, 0]
        #expect(throws: InputWireError.recordTooShort(type: 1, length: 4)) { try InputWire.decode(bytes[...]) }
    }

    /// proto/testdata/input-v1.bin is decoded by the Bridge Agent's Java test
    /// (guest/bridge-agent/test/InputRecordsTest.java), so both sides agree on
    /// the layout. Set AVO_UPDATE_GOLDEN=1 to rewrite it after a deliberate change.
    @Test func goldenFileMatchesEncoding() throws {
        var bytes: [UInt8] = []
        for record in Self.samples { bytes += try InputWire.encode(record) }
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../proto/testdata/input-v1.bin").standardizedFileURL
        if ProcessInfo.processInfo.environment["AVO_UPDATE_GOLDEN"] == "1" || !FileManager.default.fileExists(atPath: url.path) {
            try Data(bytes).write(to: url)
        }
        #expect(try Data(contentsOf: url) == Data(bytes))
    }

    @Test func preambleNegotiation() throws {
        let preamble = InputWire.preamble()
        #expect(preamble == [0x41, 0x56, 0x4F, 0x49, 1, 0, 0, 0])
        #expect(try InputWire.negotiate(peerPreamble: InputWire.preamble(version: 7)) == 1)
        #expect(throws: InputWireError.badPreamble) { try InputWire.negotiate(peerPreamble: [1, 2, 3, 4, 1, 0, 0, 0]) }
    }
}

extension InputRecord: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case .touch(let e): "touch(\(e.action), \(e.pointers.count) pointers)"
        case .key(let e): "key(\(e.keyCode))"
        case .scroll: "scroll"
        case .text(_, let s): "text(\(s))"
        case .mouse(let e): "mouse(\(e.action))"
        case .gamepad: "gamepad"
        case .ping: "ping"
        }
    }
}
