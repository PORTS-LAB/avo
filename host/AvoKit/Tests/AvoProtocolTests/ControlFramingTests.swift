import Foundation
import SwiftProtobuf
import Testing
@testable import AvoProtocol

@Suite struct ControlFramingTests {
    private func launch(_ package: String, display: UInt32) -> Avo_V1_Envelope {
        var launch = Avo_V1_Launch()
        launch.package = package
        launch.displayID = display
        launch.width = 1080
        launch.height = 2340
        launch.dpi = 440
        return Avo_V1_Envelope(.launch(launch), requestID: 7)
    }

    @Test func roundTripsAcrossArbitraryChunkBoundaries() throws {
        let envelopes = [
            Avo_V1_Envelope(.hello(AvoProtocol.hostHello(softwareVersion: "avo-host test"))),
            launch("com.example.notes", display: 3),
            launch(String(repeating: "x", count: 300), display: 4), // multi-byte varint
        ]
        var stream = Data()
        for envelope in envelopes { stream.append(try ControlFraming.encode(envelope)) }

        for chunkSize in [1, 2, 3, 7, 64, stream.count] {
            var decoder = ControlFrameDecoder()
            var decoded: [Avo_V1_Envelope] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decoder.append(stream[offset..<end])
                offset = end
                while let envelope = try decoder.next() { decoded.append(envelope) }
            }
            #expect(decoded == envelopes, "chunk size \(chunkSize)")
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func matchesProtobufDelimitedEncoding() throws {
        // The guest uses Java's writeDelimitedTo/parseDelimitedFrom; SwiftProtobuf's
        // BinaryDelimited is the reference for that format.
        let envelope = launch("com.example.notes", display: 9)
        let output = OutputStream.toMemory()
        output.open()
        try BinaryDelimited.serialize(message: envelope, to: output)
        output.close()
        let reference = output.property(forKey: .dataWrittenToMemoryStreamKey) as! Data
        #expect(try ControlFraming.encode(envelope) == reference)
    }

    @Test func stampsProtocolVersionAndRequestID() {
        let envelope = launch("a.b", display: 1)
        #expect(envelope.protocolVersion == AvoProtocol.version)
        #expect(envelope.requestID == 7)
        #expect(envelope.payloadName == "launch")
    }

    @Test func rejectsOversizedFrames() {
        var decoder = ControlFrameDecoder()
        // varint for 16 MiB
        decoder.append([0x80, 0x80, 0x80, 0x08])
        #expect(throws: ControlFramingError.frameTooLarge(16 * 1024 * 1024)) { try decoder.next() }
    }

    @Test func rejectsRunawayVarint() {
        var decoder = ControlFrameDecoder()
        decoder.append([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: ControlFramingError.malformedLength) { try decoder.next() }
    }

    @Test func reportsGarbageBody() {
        var decoder = ControlFrameDecoder()
        decoder.append([0x02, 0xFF, 0xFF])
        #expect(throws: ControlFramingError.self) { try decoder.next() }
    }
}

@Suite struct NegotiationTests {
    private func hello(_ version: UInt32, min: UInt32) -> Avo_V1_Hello {
        var hello = Avo_V1_Hello()
        hello.protocolVersion = version
        hello.minProtocolVersion = min
        return hello
    }

    @Test func agreesOnLowerVersion() {
        #expect(AvoProtocol.negotiate(host: hello(3, min: 1), guest: hello(2, min: 1)) == .success(2))
        #expect(AvoProtocol.negotiate(host: hello(1, min: 1), guest: hello(4, min: 1)) == .success(1))
    }

    @Test func rejectsGuestOlderThanHostMinimum() {
        #expect(AvoProtocol.negotiate(host: hello(5, min: 3), guest: hello(2, min: 1))
            == .failure(.guestTooOld(guest: 2, required: 3)))
    }

    @Test func rejectsHostOlderThanGuestMinimum() {
        #expect(AvoProtocol.negotiate(host: hello(2, min: 1), guest: hello(6, min: 4))
            == .failure(.hostTooOld(host: 2, required: 4)))
    }

    @Test func currentVersionMatchesProtoEnum() {
        #expect(AvoProtocol.version == 1)
        #expect(AvoProtocol.minimumVersion <= AvoProtocol.version)
    }
}
