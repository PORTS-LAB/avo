import Compression
import Foundation

/// Random-access byte source for ZIP parsing.
protocol ZipSource: Sendable {
    var size: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> [UInt8]
}

/// A file read with pread(2), safe to share across threads.
final class FileSource: ZipSource {
    let size: UInt64
    private let descriptor: Int32

    convenience init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw PackageError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        try self.init(descriptor: descriptor)
    }

    /// Takes ownership of `descriptor` (closed when the source is released).
    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw PackageError.io(String(cString: strerror(errno)))
        }
        size = UInt64(info.st_size)
    }

    deinit { close(descriptor) }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        guard offset <= size, UInt64(count) <= size - offset else {
            throw PackageError.malformed("read past end of file")
        }
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw PackageError.io(String(cString: strerror(errno)))
            }
            if n == 0 { throw PackageError.malformed("short read") }
            done += n
        }
        return buffer
    }
}

struct MemorySource: ZipSource {
    let bytes: [UInt8]
    var size: UInt64 { UInt64(bytes.count) }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard offset <= size, UInt64(count) <= size - offset else { throw PackageError.malformed("read past end of data") }
        let start = Int(offset)
        return Array(bytes[start..<(start + count)])
    }
}

/// A stored (uncompressed) entry of another archive, read in place.
struct WindowSource: ZipSource {
    let base: any ZipSource
    let start: UInt64
    let size: UInt64

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard offset <= size, UInt64(count) <= size - offset else { throw PackageError.malformed("read past end of entry") }
        return try base.read(at: start + offset, count: count)
    }
}

public struct ZipEntry: Sendable, Hashable {
    public let path: String
    public let method: UInt16
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let isEncrypted: Bool
    let localHeaderOffset: UInt64

    public var isDirectory: Bool { path.hasSuffix("/") }
    public var fileName: String { String(path.split(separator: "/").last ?? "") }
}

/// Read-only ZIP reader with ZIP64 support. Entries are decompressed on demand,
/// so multi-gigabyte XAPK files are never loaded into memory.
public final class ZipArchive: Sendable {
    public let entries: [ZipEntry]
    private let byPath: [String: ZipEntry]
    let source: any ZipSource

    public convenience init(url: URL) throws {
        try self.init(source: FileSource(url: url))
    }

    /// Reads through an already-open file (for example one passed over XPC,
    /// which needs no file-system permission of its own). The descriptor is
    /// duplicated; the caller keeps ownership of `descriptor`.
    public convenience init(fileDescriptor descriptor: Int32) throws {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw PackageError.io(String(cString: strerror(errno))) }
        try self.init(source: FileSource(descriptor: copy))
    }

    public convenience init(data: Data) throws {
        try self.init(source: MemorySource(bytes: [UInt8](data)))
    }

    init(source: any ZipSource) throws {
        self.source = source
        let entries = try Self.readCentralDirectory(source)
        self.entries = entries
        var byPath: [String: ZipEntry] = [:]
        for entry in entries where byPath[entry.path] == nil { byPath[entry.path] = entry }
        self.byPath = byPath
    }

    public func entry(_ path: String) -> ZipEntry? { byPath[path] }

    /// Reads a whole entry into memory, refusing entries above `limit` bytes.
    public func data(of entry: ZipEntry, limit: UInt64 = 64 << 20) throws -> Data {
        guard entry.uncompressedSize <= limit else { throw PackageError.entryTooLarge(entry.path, entry.uncompressedSize) }
        var result = Data(capacity: Int(entry.uncompressedSize))
        try stream(entry) { result.append($0) }
        return result
    }

    public func data(at path: String, limit: UInt64 = 64 << 20) throws -> Data {
        guard let entry = entry(path) else { throw PackageError.missingEntry(path) }
        return try data(of: entry, limit: limit)
    }

    /// Decompresses an entry in chunks and verifies its CRC.
    public func stream(_ entry: ZipEntry, chunkSize: Int = 1 << 20, _ body: (Data) throws -> Void) throws {
        guard !entry.isEncrypted else { throw PackageError.encrypted }
        let dataStart = try dataOffset(of: entry)
        var crc = CRC32()
        var produced: UInt64 = 0
        func emit(_ chunk: Data) throws {
            crc.update(chunk)
            produced += UInt64(chunk.count)
            try body(chunk)
        }
        switch entry.method {
        case 0:
            var offset: UInt64 = 0
            while offset < entry.compressedSize {
                let count = Int(min(UInt64(chunkSize), entry.compressedSize - offset))
                try emit(Data(try source.read(at: dataStart + offset, count: count)))
                offset += UInt64(count)
            }
        case 8:
            // Apple's COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), exactly what ZIP stores.
            var pending: [Data] = []
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: chunkSize) { chunk in
                // Copy now: the chunk can share the filter's buffer, which the
                // next chunk of the same write overwrites.
                if let chunk { pending.append(chunk.withUnsafeBytes { Data($0) }) }
            }
            var offset: UInt64 = 0
            while offset < entry.compressedSize {
                let count = Int(min(UInt64(chunkSize), entry.compressedSize - offset))
                try filter.write(Data(try source.read(at: dataStart + offset, count: count)))
                offset += UInt64(count)
                for chunk in pending { try emit(chunk) }
                pending.removeAll(keepingCapacity: true)
            }
            try filter.finalize()
            for chunk in pending { try emit(chunk) }
        default:
            throw PackageError.unsupportedCompression(entry.method)
        }
        guard produced == entry.uncompressedSize, crc.checksum == entry.crc32 else {
            throw PackageError.checksumMismatch(entry.path)
        }
    }

    public func extract(_ entry: ZipEntry, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try stream(entry) { try handle.write(contentsOf: $0) }
    }

    /// Opens a nested archive (an APK inside an XAPK/APKM/APKS). Stored entries
    /// are read in place; compressed ones are inflated to `scratch`.
    public func nestedArchive(_ entry: ZipEntry, scratch: URL) throws -> ZipArchive {
        if entry.method == 0 && !entry.isEncrypted {
            let start = try dataOffset(of: entry)
            return try ZipArchive(source: WindowSource(base: source, start: start, size: entry.uncompressedSize))
        }
        let destination = scratch.appending(path: UUID().uuidString + "-" + entry.fileName)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try extract(entry, to: destination)
        return try ZipArchive(url: destination)
    }

    // MARK: Parsing

    private func dataOffset(of entry: ZipEntry) throws -> UInt64 {
        let header = try source.read(at: entry.localHeaderOffset, count: 30)
        var cursor = ByteCursor(header)
        guard try cursor.u32() == 0x0403_4B50 else { throw PackageError.malformed("bad local header for \(entry.path)") }
        let nameLength = UInt64(try cursor.u16(at: 26))
        let extraLength = UInt64(try cursor.u16(at: 28))
        return entry.localHeaderOffset + 30 + nameLength + extraLength
    }

    private static func readCentralDirectory(_ source: any ZipSource) throws -> [ZipEntry] {
        guard source.size >= 22 else { throw PackageError.notAZipArchive }
        // The end of central directory record sits in the last 64 KiB + 22 bytes.
        let tailLength = Int(min(source.size, 65_557))
        let tailStart = source.size - UInt64(tailLength)
        let tail = try source.read(at: tailStart, count: tailLength)
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail[$0] == 0x50 && tail[$0 + 1] == 0x4B && tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06
        }) else { throw PackageError.notAZipArchive }

        let record = ByteCursor(tail, offset: eocd)
        var entryCount = UInt64(try record.u16(at: eocd + 10))
        var directorySize = UInt64(try record.u32(at: eocd + 12))
        var directoryOffset = UInt64(try record.u32(at: eocd + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: locator immediately precedes the EOCD record.
            let locatorPosition = eocd - 20
            guard locatorPosition >= 0, try record.u32(at: locatorPosition) == 0x0706_4B50 else {
                throw PackageError.malformed("missing ZIP64 locator")
            }
            var locator = ByteCursor(tail, offset: locatorPosition + 8)
            let zip64Offset = try locator.u64()
            var zip64 = ByteCursor(try source.read(at: zip64Offset, count: 56))
            guard try zip64.u32() == 0x0606_4B50 else { throw PackageError.malformed("bad ZIP64 end record") }
            try zip64.skip(20)
            _ = try zip64.u64()          // entries on this disk
            entryCount = try zip64.u64()
            directorySize = try zip64.u64()
            directoryOffset = try zip64.u64()
        }

        guard directoryOffset <= source.size, directorySize <= source.size - directoryOffset,
              directorySize < 512 << 20 else {
            throw PackageError.malformed("central directory out of bounds")
        }
        let directory = try source.read(at: directoryOffset, count: Int(directorySize))
        var cursor = ByteCursor(directory)
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(entryCount, 100_000)))
        for _ in 0..<entryCount {
            guard try cursor.u32() == 0x0201_4B50 else { throw PackageError.malformed("bad central directory entry") }
            try cursor.skip(4)                       // versions
            let flags = try cursor.u16()
            let method = try cursor.u16()
            try cursor.skip(4)                       // time, date
            let crc = try cursor.u32()
            var compressed = UInt64(try cursor.u32())
            var uncompressed = UInt64(try cursor.u32())
            let nameLength = Int(try cursor.u16())
            let extraLength = Int(try cursor.u16())
            let commentLength = Int(try cursor.u16())
            try cursor.skip(8)                       // disk, internal and external attributes
            var localOffset = UInt64(try cursor.u32())
            let nameBytes = try cursor.slice(nameLength)
            let extra = try cursor.slice(extraLength)
            try cursor.skip(commentLength)

            // ZIP64 extended information extra field (0x0001).
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                var fields = ByteCursor(Array(extra))
                while fields.remaining >= 4 {
                    let tag = try fields.u16()
                    let size = Int(try fields.u16())
                    guard tag == 0x0001 else { try fields.skip(size); continue }
                    var zip64 = ByteCursor(Array(try fields.slice(size)))
                    if uncompressed == 0xFFFF_FFFF { uncompressed = try zip64.u64() }
                    if compressed == 0xFFFF_FFFF { compressed = try zip64.u64() }
                    if localOffset == 0xFFFF_FFFF { localOffset = try zip64.u64() }
                    break
                }
            }

            let path = String(decoding: nameBytes, as: UTF8.self)
            entries.append(ZipEntry(path: path, method: method, crc32: crc, compressedSize: compressed,
                                    uncompressedSize: uncompressed, isEncrypted: flags & 1 == 1,
                                    localHeaderOffset: localOffset))
        }
        return entries
    }
}
