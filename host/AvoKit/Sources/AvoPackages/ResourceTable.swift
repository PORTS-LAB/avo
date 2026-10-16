import Foundation

/// The qualifiers of a resource configuration that matter for labels and icons.
public struct ResourceConfig: Sendable, Hashable, CustomStringConvertible {
    public static let densityAny: UInt16 = 0xFFFE
    public static let densityNone: UInt16 = 0xFFFF

    public var language = ""
    public var region = ""
    public var density: UInt16 = 0
    public var sdkVersion: UInt16 = 0
    /// `uiMode & 0x30`: 0x20 means night.
    public var night = false
    /// Any other qualifier (mcc, orientation, screen size, car mode, …).
    public var hasOtherQualifiers = false

    public var isDefault: Bool { language.isEmpty && region.isEmpty && density == 0 && !night && !hasOtherQualifiers }

    public var description: String {
        var parts: [String] = []
        if !language.isEmpty { parts.append(language + (region.isEmpty ? "" : "-r" + region)) }
        if night { parts.append("night") }
        switch density {
        case 0: break
        case Self.densityAny: parts.append("anydpi")
        case Self.densityNone: parts.append("nodpi")
        default: parts.append("\(density)dpi")
        }
        if sdkVersion > 0 { parts.append("v\(sdkVersion)") }
        if hasOtherQualifiers { parts.append("+other") }
        return parts.isEmpty ? "default" : parts.joined(separator: "-")
    }

    init(bytes: [UInt8], at start: Int) throws(PackageError) {
        let cursor = ByteCursor(bytes)
        let size = Int(try cursor.u32(at: start))
        guard size >= 28, start + size <= bytes.count else { throw .malformed("bad resource config") }
        func u8(_ offset: Int) throws(PackageError) -> UInt8 { offset + 1 <= size ? bytes[start + offset] : 0 }
        func u16(_ offset: Int) throws(PackageError) -> UInt16 { offset + 2 <= size ? try cursor.u16(at: start + offset) : 0 }

        let mcc = try u16(4), mnc = try u16(6)
        let language = (try u8(8), try u8(9))
        let country = (try u8(10), try u8(11))
        if language.0 & 0x80 == 0 && language.0 != 0 {
            self.language = String(decoding: [language.0, language.1], as: UTF8.self)
        } else if language.0 != 0 {
            hasOtherQualifiers = true // packed three-letter language
        }
        if country.0 & 0x80 == 0 && country.0 != 0 {
            region = String(decoding: [country.0, country.1], as: UTF8.self)
        }
        density = try u16(14)
        sdkVersion = try u16(24)
        let uiMode = try u8(29)
        night = uiMode & 0x30 == 0x20
        // mcc, mnc, screen sizes and dp widths, then the single-byte qualifiers
        // (orientation, touchscreen, keyboard, navigation, input flags, screen
        // layout, layout direction, color mode) and the ui mode type.
        var others: [UInt16] = [mcc, mnc]
        for offset in [20, 22, 30, 32, 34] { others.append(try u16(offset)) }
        for offset in [12, 13, 16, 17, 18, 28, 48, 49] { others.append(UInt16(try u8(offset))) }
        others.append(UInt16(uiMode & 0x0F))
        if others.contains(where: { $0 != 0 }) { hasOtherQualifiers = true }
    }

    public init() {}
}

/// A parsed resources.arsc with lazy, per-id value lookup.
public final class ResourceTable {
    private struct TypeChunk {
        let config: ResourceConfig
        let start: Int
        let headerSize: Int
        let entryCount: Int
        let entriesStart: Int
        let flags: UInt8
    }

    private struct Package {
        var types: [UInt8: [TypeChunk]] = [:]
    }

    private let bytes: [UInt8]
    private var globalStrings: StringPool
    private var packages: [UInt8: Package] = [:]

    public init(data: Data) throws {
        bytes = [UInt8](data)
        let cursor = ByteCursor(bytes)
        guard bytes.count >= 12, try cursor.u16(at: 0) == ChunkType.table.rawValue else {
            throw PackageError.malformed("not a resource table")
        }
        let headerSize = Int(try cursor.u16(at: 2))
        let total = min(Int(try cursor.u32(at: 4)), bytes.count)
        globalStrings = .empty

        var position = headerSize
        while position + 8 <= total {
            let type = try cursor.u16(at: position)
            let size = Int(try cursor.u32(at: position + 4))
            guard size >= 8, position + size <= total else { throw PackageError.malformed("bad table chunk") }
            switch ChunkType(rawValue: type) {
            case .stringPool:
                globalStrings = try StringPool(chunk: Array(bytes[position..<(position + size)]))
            case .tablePackage:
                try parsePackage(at: position, size: size)
            default:
                break
            }
            position += size
        }
    }

    private func parsePackage(at start: Int, size: Int) throws {
        let cursor = ByteCursor(bytes)
        let headerSize = Int(try cursor.u16(at: start + 2))
        let id = UInt8(truncatingIfNeeded: try cursor.u32(at: start + 8))
        var package = packages[id] ?? Package()
        var position = start + headerSize
        let end = start + size
        while position + 8 <= end {
            let type = try cursor.u16(at: position)
            let chunkHeader = Int(try cursor.u16(at: position + 2))
            let chunkSize = Int(try cursor.u32(at: position + 4))
            guard chunkSize >= 8, position + chunkSize <= end else { throw PackageError.malformed("bad package chunk") }
            if ChunkType(rawValue: type) == .tableType, chunkSize >= 28 {
                let typeID = bytes[position + 8]
                let flags = bytes[position + 9]
                let entryCount = Int(try cursor.u32(at: position + 12))
                let entriesStart = Int(try cursor.u32(at: position + 16))
                let config = try ResourceConfig(bytes: bytes, at: position + 20)
                package.types[typeID, default: []].append(TypeChunk(
                    config: config, start: position, headerSize: chunkHeader,
                    entryCount: entryCount, entriesStart: entriesStart, flags: flags))
            }
            position += chunkSize
        }
        packages[id] = package
    }

    /// Every configuration's value for a resource id (`0xPPTTEEEE`).
    public func values(for id: UInt32) -> [(config: ResourceConfig, value: ResourceValue)] {
        let packageID = UInt8(id >> 24)
        let typeID = UInt8((id >> 16) & 0xFF)
        let entryIndex = Int(id & 0xFFFF)
        guard let chunks = packages[packageID]?.types[typeID] else { return [] }
        var result: [(ResourceConfig, ResourceValue)] = []
        for chunk in chunks {
            if let value = try? entryValue(chunk, index: entryIndex) {
                result.append((chunk.config, value))
            }
        }
        return result
    }

    private func entryValue(_ chunk: TypeChunk, index: Int) throws -> ResourceValue? {
        let cursor = ByteCursor(bytes)
        let table = chunk.start + chunk.headerSize
        var offset: Int?
        if chunk.flags & 0x01 != 0 {
            // Sparse: sorted (index, offset / 4) pairs.
            var low = 0, high = chunk.entryCount - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = Int(try cursor.u16(at: table + mid * 4))
                if entry == index { offset = Int(try cursor.u16(at: table + mid * 4 + 2)) * 4; break }
                if entry < index { low = mid + 1 } else { high = mid - 1 }
            }
        } else {
            guard index < chunk.entryCount else { return nil }
            if chunk.flags & 0x02 != 0 {
                let raw = try cursor.u16(at: table + index * 2)
                offset = raw == 0xFFFF ? nil : Int(raw) * 4
            } else {
                let raw = try cursor.u32(at: table + index * 4)
                offset = raw == 0xFFFF_FFFF ? nil : Int(raw)
            }
        }
        guard let offset else { return nil }
        let entry = chunk.start + chunk.entriesStart + offset
        let sizeOrKey = try cursor.u16(at: entry)
        let flags = try cursor.u16(at: entry + 2)
        if flags & 0x08 != 0 {
            // Compact entry: key(16) flags(16, high byte = data type) data(32).
            return ResourceValue.decode(type: UInt8(flags >> 8), data: try cursor.u32(at: entry + 4), strings: &globalStrings)
        }
        if flags & 0x01 != 0 { return .other(type: 0xFF, data: 0) } // complex (style, array, plural)
        let value = entry + Int(sizeOrKey)
        try cursor.require(8, at: value)
        let dataType = bytes[value + 3]
        return ResourceValue.decode(type: dataType, data: try cursor.u32(at: value + 4), strings: &globalStrings)
    }

    // MARK: Resolution

    /// Follows references until a non-reference value, choosing configurations
    /// with `choose` at each step.
    public func resolve(_ id: UInt32, choose: ([(config: ResourceConfig, value: ResourceValue)]) -> ResourceValue?) -> ResourceValue? {
        var current = id
        for _ in 0..<8 {
            guard let value = choose(values(for: current)) else { return nil }
            guard case .reference(let next) = value, next != 0 else { return value }
            current = next
        }
        return nil
    }

    /// A string resource in the best language for `languages` (falls back to
    /// the default configuration, then English, then anything).
    public func string(_ id: UInt32, languages: [String] = Locale.preferredLanguages) -> String? {
        let wanted = languages.map { String($0.prefix(2)).lowercased() }
        return resolve(id) { candidates in
            let plain = candidates.filter { !$0.config.hasOtherQualifiers && !$0.config.night }
            for language in wanted {
                if let match = plain.first(where: { $0.config.language == language }) { return match.value }
            }
            return (plain.first { $0.config.language.isEmpty } ?? plain.first { $0.config.language == "en" }
                ?? plain.first ?? candidates.first)?.value
        }?.stringValue
    }

    /// A drawable or mipmap: prefers an adaptive (anydpi-v26) definition when
    /// `adaptive` is set, otherwise the highest density bitmap.
    public func drawable(_ id: UInt32, adaptive: Bool = true) -> ResourceValue? {
        resolve(id) { candidates in
            let usable = candidates.filter { !$0.config.night && !$0.config.hasOtherQualifiers }
            let pool = usable.isEmpty ? candidates : usable
            if adaptive, let xml = pool.first(where: {
                $0.config.density == ResourceConfig.densityAny && $0.value.stringValue?.hasSuffix(".xml") == true
            }) { return xml.value }
            let ranked = pool.sorted { lhs, rhs in
                Self.densityRank(lhs.config.density) > Self.densityRank(rhs.config.density)
            }
            if !adaptive, let bitmap = ranked.first(where: { $0.value.stringValue?.hasSuffix(".xml") == false }) {
                return bitmap.value
            }
            return ranked.first?.value
        }
    }

    private static func densityRank(_ density: UInt16) -> Int {
        switch density {
        case ResourceConfig.densityAny: 1
        case ResourceConfig.densityNone: 2
        case 0: 3 // default (mdpi)
        default: Int(density) + 10
        }
    }
}
