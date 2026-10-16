import Foundation

/// Bounds-checked little-endian reader over a byte buffer.
struct ByteCursor {
    let bytes: [UInt8]
    var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    func require(_ count: Int, at position: Int? = nil) throws(PackageError) {
        let start = position ?? offset
        guard start >= 0, count >= 0, start <= bytes.count - count else {
            throw .malformed("unexpected end of data at \(start) (+\(count))")
        }
    }

    mutating func u8() throws(PackageError) -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws(PackageError) -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws(PackageError) -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    mutating func u64() throws(PackageError) -> UInt64 {
        let low = UInt64(try u32())
        return low | UInt64(try u32()) << 32
    }

    mutating func skip(_ count: Int) throws(PackageError) {
        try require(count)
        offset += count
    }

    mutating func slice(_ count: Int) throws(PackageError) -> ArraySlice<UInt8> {
        try require(count)
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    func u16(at position: Int) throws(PackageError) -> UInt16 {
        try require(2, at: position)
        return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
    }

    func u32(at position: Int) throws(PackageError) -> UInt32 {
        try require(4, at: position)
        return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
            | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
    }
}

/// CRC-32 (IEEE 802.3), as used by ZIP.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    private(set) var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var crc = value
        Self.table.withUnsafeBufferPointer { table in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        value = crc
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    var checksum: UInt32 { value ^ 0xFFFF_FFFF }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.checksum
    }
}
