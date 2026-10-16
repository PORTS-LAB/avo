import Foundation
import SwiftProtobuf

/// Constants shared by every host component that talks to the guest.
public enum AvoProtocol {
    /// Control protocol version spoken by this build (`PROTOCOL_VERSION_CURRENT`).
    public static let version = UInt32(Avo_V1_ProtocolVersion.current.rawValue)

    /// Oldest guest protocol version this host still accepts.
    public static let minimumVersion: UInt32 = 1

    /// Largest Control frame either side may send.
    public static let maxFrameSize = 8 * 1024 * 1024

    /// vsock ports inside the guest.
    public enum Port {
        public static let adb: UInt32 = 5555
        public static let control: UInt32 = 6000
        public static let input: UInt32 = 6001
    }

    /// Hello sent by the host at the start of every Control session.
    public static func hostHello(softwareVersion: String, capabilities: [String] = Capability.host) -> Avo_V1_Hello {
        var hello = Avo_V1_Hello()
        hello.protocolVersion = version
        hello.minProtocolVersion = minimumVersion
        hello.softwareVersion = softwareVersion
        hello.capabilities = capabilities
        return hello
    }

    public enum Capability {
        public static let notifications = "notifications"
        public static let clipboard = "clipboard"
        public static let permissions = "permissions"
        public static let share = "share"
        public static let host = [notifications, clipboard, permissions, share]
    }
}

extension Avo_V1_Envelope {
    /// An envelope stamped with this build's protocol version.
    public init(_ payload: OneOf_Payload, requestID: UInt64 = 0) {
        self.init()
        self.protocolVersion = AvoProtocol.version
        self.requestID = requestID
        self.payload = payload
    }

    /// Short name of the payload for logs ("launch", "appInstalled", …).
    public var payloadName: String {
        guard let payload else { return "empty" }
        let description = String(describing: payload)
        return String(description.prefix { $0 != "(" })
    }
}

// MARK: - Version negotiation

public enum NegotiationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The guest image is older than this host supports.
    case guestTooOld(guest: UInt32, required: UInt32)
    /// This host is older than the guest image supports.
    case hostTooOld(host: UInt32, required: UInt32)

    public var description: String {
        switch self {
        case let .guestTooOld(guest, required):
            "The Android image speaks protocol \(guest) but Avo needs at least \(required). Update the Android image."
        case let .hostTooOld(host, required):
            "Avo speaks protocol \(host) but the Android image needs at least \(required). Update Avo."
        }
    }
}

extension AvoProtocol {
    /// Picks the protocol version for a session: the lower of both versions, as
    /// long as each side still accepts it.
    public static func negotiate(host: Avo_V1_Hello, guest: Avo_V1_Hello) -> Result<UInt32, NegotiationError> {
        let agreed = min(host.protocolVersion, guest.protocolVersion)
        if agreed < host.minProtocolVersion {
            return .failure(.guestTooOld(guest: guest.protocolVersion, required: host.minProtocolVersion))
        }
        if agreed < guest.minProtocolVersion {
            return .failure(.hostTooOld(host: host.protocolVersion, required: guest.minProtocolVersion))
        }
        return .success(agreed)
    }
}
