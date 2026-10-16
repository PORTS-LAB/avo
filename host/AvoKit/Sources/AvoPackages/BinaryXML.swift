import Foundation

// Android binary resource formats (frameworks/base/libs/androidfw/include/androidfw/ResourceTypes.h).

enum ChunkType: UInt16 {
    case stringPool = 0x0001
    case table = 0x0002
    case xml = 0x0003
    case xmlStartNamespace = 0x0100
    case xmlEndNamespace = 0x0101
    case xmlStartElement = 0x0102
    case xmlEndElement = 0x0103
    case xmlCData = 0x0104
    case xmlResourceMap = 0x0180
    case tablePackage = 0x0200
    case tableType = 0x0201
    case tableTypeSpec = 0x0202
    case tableLibrary = 0x0203
    case tableOverlayable = 0x0204
    case tableOverlayablePolicy = 0x0205
    case tableStagedAlias = 0x0206
}

/// ResStringPool: UTF-8 or UTF-16 strings referenced by index.
struct StringPool {
    private var strings: [String?]
    private let bytes: [UInt8]
    private let offsets: [UInt32]
    private let stringsStart: Int
    private let utf8: Bool

    static let empty = StringPool()

    private init() {
        strings = []
        bytes = []
        offsets = []
        stringsStart = 0
        utf8 = true
    }

    /// `bytes` is the whole chunk, starting at its header.
    init(chunk bytes: [UInt8]) throws(PackageError) {
        let cursor = ByteCursor(bytes)
        let headerSize = Int(try cursor.u16(at: 2))
        let count = Int(try cursor.u32(at: 8))
        let flags = try cursor.u32(at: 16)
        let stringsStart = Int(try cursor.u32(at: 20))
        guard count < 1 << 22 else { throw .malformed("string pool too large") }
        var offsets: [UInt32] = []
        offsets.reserveCapacity(count)
        var reader = ByteCursor(bytes, offset: headerSize)
        for _ in 0..<count { offsets.append(try reader.u32()) }
        self.bytes = bytes
        self.offsets = offsets
        self.stringsStart = stringsStart
        self.utf8 = flags & (1 << 8) != 0
        self.strings = Array(repeating: nil, count: count)
    }

    var count: Int { offsets.count }

    /// Decodes lazily; resources.arsc pools can hold hundreds of thousands of strings.
    mutating func string(_ index: UInt32) -> String? {
        let i = Int(index)
        guard i < offsets.count else { return nil }
        if let cached = strings[i] { return cached }
        let decoded = try? decode(at: stringsStart + Int(offsets[i]))
        strings[i] = decoded
        return decoded
    }

    private func decode(at position: Int) throws(PackageError) -> String {
        var cursor = ByteCursor(bytes, offset: position)
        if utf8 {
            _ = try lengthUTF8(&cursor)           // UTF-16 length, unused
            let length = try lengthUTF8(&cursor)
            return String(decoding: try cursor.slice(length), as: UTF8.self)
        } else {
            var length = Int(try cursor.u16())
            if length & 0x8000 != 0 { length = (length & 0x7FFF) << 16 | Int(try cursor.u16()) }
            var units: [UInt16] = []
            units.reserveCapacity(length)
            for _ in 0..<length { units.append(try cursor.u16()) }
            return String(decoding: units, as: UTF16.self)
        }
    }

    private func lengthUTF8(_ cursor: inout ByteCursor) throws(PackageError) -> Int {
        let first = Int(try cursor.u8())
        return first & 0x80 != 0 ? (first & 0x7F) << 8 | Int(try cursor.u8()) : first
    }
}

/// A typed resource value (Res_value).
public enum ResourceValue: Sendable, Equatable {
    case null
    case reference(UInt32)
    case attribute(UInt32)
    case string(String)
    case float(Float)
    case dimension(UInt32)
    case fraction(UInt32)
    case int(Int32)
    case bool(Bool)
    case color(UInt32)
    case other(type: UInt8, data: UInt32)

    static func decode(type: UInt8, data: UInt32, strings: inout StringPool) -> ResourceValue {
        switch type {
        case 0x00: .null
        case 0x01, 0x07: .reference(data)
        case 0x02, 0x08: .attribute(data)
        case 0x03: strings.string(data).map(ResourceValue.string) ?? .null
        case 0x04: .float(Float(bitPattern: data))
        case 0x05: .dimension(data)
        case 0x06: .fraction(data)
        case 0x10, 0x11: .int(Int32(bitPattern: data))
        case 0x12: .bool(data != 0)
        case 0x1C, 0x1D, 0x1E, 0x1F: .color(data)
        default: .other(type: type, data: data)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .bool(let b): String(b)
        case .float(let f): String(f)
        default: nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): Int64(i)
        case .string(let s): Int64(s)
        default: nil
        }
    }
}

/// An element of a binary XML document (AndroidManifest.xml, adaptive icons, vectors).
public struct BinaryXMLElement: Sendable {
    public struct Attribute: Sendable {
        public let namespace: String?
        public let name: String
        /// Framework attribute id (e.g. 0x0101021c for android:versionName). Obfuscated
        /// packages may strip names, so lookups prefer this.
        public let resourceID: UInt32?
        public let value: ResourceValue
    }

    public let name: String
    public let attributes: [Attribute]
    public var children: [BinaryXMLElement]

    public func attribute(_ name: String, id: UInt32? = nil) -> ResourceValue? {
        if let id, let match = attributes.first(where: { $0.resourceID == id }) { return match.value }
        return attributes.first { $0.name == name }?.value
    }

    public func children(named name: String) -> [BinaryXMLElement] {
        children.filter { $0.name == name }
    }

    public func first(_ name: String) -> BinaryXMLElement? {
        children.first { $0.name == name }
    }

    /// Depth-first search through all descendants.
    public func descendants(named name: String) -> [BinaryXMLElement] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(named: name) }
    }
}

/// Framework attribute resource ids used when reading manifests and drawables.
public enum AndroidAttribute {
    public static let label: UInt32 = 0x0101_0001
    public static let icon: UInt32 = 0x0101_0002
    public static let name: UInt32 = 0x0101_0003
    public static let versionCode: UInt32 = 0x0101_021B
    public static let versionName: UInt32 = 0x0101_021C
    public static let minSdkVersion: UInt32 = 0x0101_020C
    public static let targetSdkVersion: UInt32 = 0x0101_0270
    public static let roundIcon: UInt32 = 0x0101_052C
    public static let drawable: UInt32 = 0x0101_0199
    public static let isFeatureSplit: UInt32 = 0x0101_055B
    public static let versionCodeMajor: UInt32 = 0x0101_057B
}

public enum BinaryXML {
    /// Parses a compiled XML document and returns its root element.
    public static func parse(_ data: Data) throws -> BinaryXMLElement {
        let bytes = [UInt8](data)
        let cursor = ByteCursor(bytes)
        guard bytes.count >= 8, try cursor.u16(at: 0) == ChunkType.xml.rawValue else {
            throw PackageError.malformed("not a binary XML document")
        }
        let headerSize = Int(try cursor.u16(at: 2))
        let total = min(Int(try cursor.u32(at: 4)), bytes.count)

        var strings = StringPool.empty
        var resourceMap: [UInt32] = []
        var stack: [BinaryXMLElement] = []
        var root: BinaryXMLElement?

        var position = headerSize
        while position + 8 <= total {
            let type = try cursor.u16(at: position)
            let chunkHeader = Int(try cursor.u16(at: position + 2))
            let size = Int(try cursor.u32(at: position + 4))
            guard size >= 8, position + size <= total else { throw PackageError.malformed("bad XML chunk size") }
            let chunk = Array(bytes[position..<(position + size)])

            switch ChunkType(rawValue: type) {
            case .stringPool:
                strings = try StringPool(chunk: chunk)
            case .xmlResourceMap:
                var map = ByteCursor(chunk, offset: chunkHeader)
                while map.remaining >= 4 { resourceMap.append(try map.u32()) }
            case .xmlStartElement:
                var body = ByteCursor(chunk, offset: chunkHeader)
                _ = try body.u32()                                  // namespace
                let name = strings.string(try body.u32()) ?? ""
                let attributeStart = Int(try body.u16())
                let attributeSize = Int(try body.u16())
                let attributeCount = Int(try body.u16())
                var attributes: [BinaryXMLElement.Attribute] = []
                for i in 0..<attributeCount {
                    var attribute = ByteCursor(chunk, offset: chunkHeader + attributeStart + i * attributeSize)
                    let namespaceIndex = try attribute.u32()
                    let nameIndex = try attribute.u32()
                    let rawIndex = try attribute.u32()
                    _ = try attribute.u16()                         // size
                    _ = try attribute.u8()                          // res0
                    let dataType = try attribute.u8()
                    let data = try attribute.u32()
                    var value = ResourceValue.decode(type: dataType, data: data, strings: &strings)
                    if value == .null, rawIndex != 0xFFFF_FFFF, let raw = strings.string(rawIndex) { value = .string(raw) }
                    let namespace = namespaceIndex == 0xFFFF_FFFF ? nil : strings.string(namespaceIndex)
                    attributes.append(.init(
                        namespace: namespace,
                        name: strings.string(nameIndex) ?? "",
                        resourceID: Int(nameIndex) < resourceMap.count ? resourceMap[Int(nameIndex)] : nil,
                        value: value))
                }
                stack.append(BinaryXMLElement(name: name, attributes: attributes, children: []))
            case .xmlEndElement:
                guard let element = stack.popLast() else { throw PackageError.malformed("unbalanced XML") }
                if stack.isEmpty {
                    root = root ?? element
                } else {
                    stack[stack.count - 1].children.append(element)
                }
            default:
                break
            }
            position += size
        }
        guard let root else { throw PackageError.malformed("empty XML document") }
        return root
    }
}
