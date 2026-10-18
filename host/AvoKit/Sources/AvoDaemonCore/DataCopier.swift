import CryptoKit
import Foundation

/// Copies Android's data to another folder and checks the copy: an APFS
/// clone on the same volume (instant), else a copy that keeps the disks
/// sparse (only the parts Android wrote travel; the rest stays a hole) and
/// reads every copied byte back from the destination drive before Avo uses it.
///
/// The check hashes each nonzero 1 MiB block with its offset, on both sides:
/// a copy that differs anywhere Android wrote, or that is short, fails.
struct DataCopier: Sendable {
    static let block = 1 << 20
    static let chunk = 8 << 20

    struct Item: Sendable {
        var relative: String
        var size: Int64
        /// Where the source has data (block-aligned, increasing, apart).
        var ranges: [Range<Int64>]
        var dataBytes: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    }

    enum Phase: Sendable { case copying, verifying }

    enum Failure: Error, Equatable, LocalizedError {
        case io(String)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .io(let detail): detail
            case .mismatch(let item):
                String(localized: "The copy of \(item) does not match Android’s data. Nothing changed; Android’s data stays where it was.", bundle: .avoKit)
            }
        }
    }

    let source: URL
    let destination: URL
    let items: [Item]
    /// An APFS clone where the volume allows one (tests copy byte by byte).
    var cloning = true
    var isCancelled: @Sendable () -> Bool = { false }
    /// Bytes done and the total of the phase.
    var progress: @Sendable (Phase, Int64, Int64) -> Void = { _, _, _ in }

    /// Plans copying `relative` items (those that exist) from `source`.
    init(source: URL, destination: URL, relative: [String]) throws {
        self.source = source
        self.destination = destination
        var items: [Item] = []
        for name in relative {
            let url = source.appending(path: name)
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else {
                if errno == ENOENT { continue }
                throw Failure.io(Self.describe(errno, url))
            }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Failure.io(Self.describe(errno, url)) }
            let size = Int64(info.st_size)
            items.append(Item(relative: name, size: size, ranges: Self.dataRanges(fd, size: size)))
        }
        self.items = items
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.dataBytes } }

    /// Copies every item, then reads each copy back and compares.
    func run() throws {
        var cloned = Set<String>()
        var digests: [String: SHA256.Digest] = [:]
        var done: Int64 = 0
        let total = totalBytes
        progress(.copying, 0, total)
        for item in items {
            let from = source.appending(path: item.relative)
            let to = destination.appending(path: item.relative)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if cloning, clonefile(from.path, to.path, UInt32(CLONE_NOOWNERCOPY)) == 0 {
                cloned.insert(item.relative)
                done += item.dataBytes
                progress(.copying, done, total)
                continue
            }
            let base = done
            digests[item.relative] = try copy(item, from: from, to: to) { bytes in progress(.copying, base + bytes, total) }
            done += item.dataBytes
        }
        done = 0
        progress(.verifying, 0, total)
        for item in items {
            let copy = destination.appending(path: item.relative)
            var info = stat()
            guard stat(copy.path, &info) == 0, Int64(info.st_size) == item.size else { throw Failure.mismatch(item.relative) }
            if cloned.contains(item.relative) {
                // A clone shares the source's blocks: nothing was copied that could differ.
                done += item.dataBytes
                progress(.verifying, done, total)
                continue
            }
            let base = done
            let digest = try Self.digest(of: copy, ranges: item.ranges, isCancelled: isCancelled) { bytes in
                progress(.verifying, base + bytes, total)
            }
            guard digest == digests[item.relative] else { throw Failure.mismatch(item.relative) }
            done += item.dataBytes
        }
        progress(.verifying, total, total)
    }

    private func copy(_ item: Item, from: URL, to: URL, progress: (Int64) -> Void) throws -> SHA256.Digest {
        let input = open(from.path, O_RDONLY)
        guard input >= 0 else { throw Failure.io(Self.describe(errno, from)) }
        defer { close(input) }
        let output = open(to.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw Failure.io(Self.describe(errno, to)) }
        defer { close(output) }
        // Past the page cache: tens of gigabytes would push out everything else.
        _ = fcntl(input, F_NOCACHE, 1)
        _ = fcntl(output, F_NOCACHE, 1)
        guard ftruncate(output, off_t(item.size)) == 0 else { throw Failure.io(Self.describe(errno, to)) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var copied: Int64 = 0
        for range in item.ranges {
            var offset = range.lowerBound
            while offset < range.upperBound {
                if isCancelled() { throw CancellationError() }
                let length = Int(min(Int64(Self.chunk), range.upperBound - offset))
                let count = try Self.read(input, buffer, length, at: offset, url: from)
                if count == 0 { break }
                // Runs of nonzero blocks are written; zero blocks stay holes.
                var run: (start: Int, end: Int)?
                func flush() throws {
                    guard let current = run else { return }
                    try Self.write(output, UnsafeRawBufferPointer(rebasing: buffer[current.start..<current.end]),
                                   at: offset + Int64(current.start), url: to)
                    run = nil
                }
                var position = 0
                while position < count {
                    let end = min(position + Self.block, count)
                    let slice = UnsafeRawBufferPointer(rebasing: buffer[position..<end])
                    if Self.isZero(slice) {
                        try flush()
                    } else {
                        Self.hash(slice, at: offset + Int64(position), into: &hasher)
                        run = (run?.start ?? position, end)
                    }
                    position = end
                }
                try flush()
                offset += Int64(count)
                copied += Int64(count)
                progress(copied)
            }
        }
        // On the drive itself, not in its cache, before the check reads it back.
        if fcntl(output, F_FULLFSYNC) != 0, fsync(output) != 0 { throw Failure.io(Self.describe(errno, to)) }
        return hasher.finalize()
    }

    /// The hash of `url`'s nonzero blocks within `ranges`, read from the drive.
    static func digest(of url: URL, ranges: [Range<Int64>], isCancelled: () -> Bool = { false },
                       progress: (Int64) -> Void = { _ in }) throws -> SHA256.Digest {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure.io(describe(errno, url)) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var done: Int64 = 0
        for range in ranges {
            var offset = range.lowerBound
            while offset < range.upperBound {
                if isCancelled() { throw CancellationError() }
                let count = try read(fd, buffer, Int(min(Int64(chunk), range.upperBound - offset)), at: offset, url: url)
                if count == 0 { break }
                var position = 0
                while position < count {
                    let end = min(position + block, count)
                    let slice = UnsafeRawBufferPointer(rebasing: buffer[position..<end])
                    if !isZero(slice) { hash(slice, at: offset + Int64(position), into: &hasher) }
                    position = end
                }
                offset += Int64(count)
                done += Int64(count)
                progress(done)
            }
        }
        return hasher.finalize()
    }

    /// Where a file has data, in whole blocks (SEEK_DATA/SEEK_HOLE; the
    /// whole file where the file system cannot say).
    static func dataRanges(_ fd: Int32, size: Int64) -> [Range<Int64>] {
        guard size > 0 else { return [] }
        let block = Int64(Self.block)
        var ranges: [Range<Int64>] = []
        var position: off_t = 0
        while position < size {
            let data = lseek(fd, position, SEEK_DATA)
            if data < 0 {
                if errno == ENXIO { break }
                // No hole support: all of the rest is data.
                ranges.append(position..<size)
                break
            }
            var hole = lseek(fd, data, SEEK_HOLE)
            if hole < 0 || hole > size { hole = size }
            let start = max(Int64(data) / block * block, ranges.last?.upperBound ?? 0)
            let end = min((Int64(hole) + block - 1) / block * block, size)
            if start < end {
                if let last = ranges.last, last.upperBound == start {
                    ranges[ranges.count - 1] = last.lowerBound..<end
                } else {
                    ranges.append(start..<end)
                }
            }
            position = max(hole, data + 1)
        }
        return ranges
    }

    static func hash(_ bytes: UnsafeRawBufferPointer, at offset: Int64, into hasher: inout SHA256) {
        withUnsafeBytes(of: offset.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: bytes)
    }

    static func isZero(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return true }
        // memcmp against itself shifted by one word is all-equal only when
        // every word equals the first; then the first word decides.
        let words = bytes.count / 8
        if words > 0 {
            let first = base.loadUnaligned(as: UInt64.self)
            guard first == 0 else { return false }
            if words > 1, memcmp(base, base + 8, (words - 1) * 8) != 0 { return false }
        }
        for index in (words * 8)..<bytes.count where bytes[index] != 0 { return false }
        return true
    }

    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer, _ length: Int, at offset: Int64, url: URL) throws -> Int {
        var total = 0
        while total < length {
            let count = pread(fd, buffer.baseAddress! + total, length - total, off_t(offset) + off_t(total))
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.io(describe(errno, url))
            }
            if count == 0 { break }
            total += count
        }
        return total
    }

    static func write(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, at offset: Int64, url: URL) throws {
        var total = 0
        while total < bytes.count {
            let count = pwrite(fd, bytes.baseAddress! + total, bytes.count - total, off_t(offset) + off_t(total))
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.io(describe(errno, url))
            }
            total += count
        }
    }

    static func describe(_ code: Int32, _ url: URL) -> String {
        "\(url.path): \(String(cString: strerror(code)))"
    }
}
