import AvoKit
import Foundation

// What a Cuttlefish image folder holds, and how Avo tells a usable one from
// anything else before it copies or boots it ("Use an Image on This Mac…").

/// The files of an AOSP Cuttlefish image (`<product>-img-<build>.zip`, or
/// the `img` folder scripts/fetch-cuttlefish.sh unzips it to).
public enum CuttlefishImageFiles {
    /// What avo-vmm reads: kernel and generic ramdisk, vendor ramdisk and
    /// bootconfig, the dynamic partitions and the top-level vbmeta.
    public static let required = ["boot.img", "init_boot.img", "vendor_boot.img", "super.img", "vbmeta.img"]
    /// Used when present (chained vbmeta images), plus files the build
    /// carries that avo-vmm ignores (kept so a folder stays the same image).
    public static let optional = ["vbmeta_system.img", "vbmeta_system_dlkm.img", "vbmeta_vendor_dlkm.img", "userdata.img",
                                  "android-info.txt", "fastboot-info.txt", "cuttlefish_example_custom.img"]

    public static var all: [String] { required + optional }

    /// Whether `directory` has every required file.
    public static func isImage(_ directory: URL) -> Bool {
        required.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }
}

/// What the files say about the build, read from small parts of them: the
/// AVB properties in vbmeta images and the boot image headers.
public struct CuttlefishImageIdentity: Equatable, Sendable {
    public var release: AndroidRelease
    /// The CI build number (the fingerprint's incremental).
    public var build: String
    /// `generic/aosp_cf_arm64_only_phone/vsoc_arm64_only:17/CP2A.260605.016/16373615:userdebug/test-keys`.
    public var fingerprint: String
    /// `aosp_cf_arm64_only_phone`, `vsoc_arm64_only`, `userdebug`.
    public var product: String
    public var device: String
    public var variant: String

    /// From the AVB properties of `vbmeta.img` and `vbmeta_system.img`, with
    /// the boot image's `os_version` when they name no security patch.
    public static func read(vbmeta: [Data], bootHeader: Data?) throws -> CuttlefishImageIdentity {
        var properties: [String: String] = [:]
        for image in vbmeta {
            for (key, value) in (try? AVBProperties.parse(image)) ?? [] where properties[key] == nil { properties[key] = value }
        }
        // The device's own fingerprints name the product and device; the
        // system's is the generic system image's.
        let fingerprints = ["vendor", "product", "odm", "system_ext", "vendor_boot", "system"]
            .compactMap { properties["com.android.build.\($0).fingerprint"] }
        guard let fingerprint = fingerprints.compactMap(Fingerprint.init).first(where: { $0.device.hasPrefix("vsoc") })
                ?? fingerprints.compactMap(Fingerprint.init).first else {
            throw AndroidImageError.notAnImage(String(localized: "Its vbmeta images don’t say which Android build it is.", bundle: .avoKit))
        }
        let boot = bootHeader.flatMap(BootImageHeader.init)
        let patch = properties["com.android.build.system.security_patch"] ?? properties["com.android.build.vendor.security_patch"]
            ?? boot?.securityPatch.map { "\($0)-01" }
        guard let sdk = AndroidRelease.sdk(forVersion: fingerprint.release) else {
            throw AndroidImageError.notAnImage(String(localized: "Avo doesn’t know Android \(fingerprint.release).", bundle: .avoKit))
        }
        let release = AndroidRelease(version: fingerprint.release, sdk: sdk, securityPatch: patch, buildTag: fingerprint.buildTag)
        return CuttlefishImageIdentity(release: release, build: fingerprint.incremental, fingerprint: fingerprint.text,
                                       product: fingerprint.product, device: fingerprint.device, variant: fingerprint.variant)
    }

    /// Why Avo cannot boot this build, if it cannot.
    public func problem(minimumSDK: Int) -> String? {
        if !device.contains("arm64") {
            return String(localized: "It’s an image for \(device), not for Apple silicon. Use an arm64 Cuttlefish image (\(AndroidBuildSource.standard.product)).",
                          bundle: .avoKit)
        }
        if !device.hasPrefix("vsoc") {
            return String(localized: "It’s not an AOSP Cuttlefish image (the device is \(device)).", bundle: .avoKit)
        }
        if variant != "userdebug" && variant != "eng" {
            return String(localized: "It’s a \(variant) build. Avo needs a userdebug build, which lets it set Android up as root.", bundle: .avoKit)
        }
        if release.sdk < minimumSDK {
            // API 33 is Android 13, 36 is Android 16.
            return String(localized: "It’s \(release.name), and Avo needs Android \(minimumSDK - 20) or newer.", bundle: .avoKit)
        }
        return nil
    }

    /// `brand/product/device:release/id/incremental:type/tags`.
    struct Fingerprint {
        let text: String
        let product: String
        let device: String
        let release: String
        let buildTag: String
        let incremental: String
        let variant: String

        init?(_ text: String) {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6 else { return nil }
            let deviceRelease = parts[2].split(separator: ":", maxSplits: 1).map(String.init)
            let incrementalType = parts[4].split(separator: ":", maxSplits: 1).map(String.init)
            guard deviceRelease.count == 2, incrementalType.count == 2, !incrementalType[0].isEmpty else { return nil }
            self.text = text
            product = parts[1]
            device = deviceRelease[0]
            release = deviceRelease[1]
            buildTag = parts[3]
            incremental = incrementalType[0]
            variant = incrementalType[1]
        }
    }
}

/// Properties in an Android Verified Boot vbmeta image (`avbtool
/// --prop`): what the build put there, such as
/// `com.android.build.system.fingerprint`.
public enum AVBProperties {
    /// `key, value` pairs in the order they appear. Reads only the header
    /// and the descriptors, so the first 64 KiB of an image are plenty.
    public static func parse(_ data: Data) throws -> [(String, String)] {
        let bytes = [UInt8](data)
        func u64(_ offset: Int) throws -> UInt64 {
            guard offset >= 0, offset + 8 <= bytes.count else { throw AndroidImageError.notAnImage("vbmeta: truncated") }
            return bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard bytes.count >= 256, bytes[0..<4].elementsEqual("AVB0".utf8) else {
            throw AndroidImageError.notAnImage("vbmeta: not an AVB image")
        }
        let authentication = try u64(12)
        let descriptorsOffset = try u64(96)
        let descriptorsSize = try u64(104)
        guard authentication < 1 << 20, descriptorsOffset < 1 << 20, descriptorsSize < 1 << 20 else {
            throw AndroidImageError.notAnImage("vbmeta: descriptors out of range")
        }
        let start = 256 + Int(authentication) + Int(descriptorsOffset)
        let end = start + Int(descriptorsSize)
        guard end <= bytes.count else { throw AndroidImageError.notAnImage("vbmeta: truncated") }
        var result: [(String, String)] = []
        var position = start
        while position + 16 <= end {
            let tag = try u64(position)
            let following = try u64(position + 8)
            guard following <= UInt64(end - position - 16) else { break }
            if tag == 0 {
                // Property: key and value lengths, then both NUL-terminated.
                let keyLength = Int(try u64(position + 16))
                let valueLength = Int(try u64(position + 24))
                let keyStart = position + 32
                let valueStart = keyStart + keyLength + 1
                guard keyLength < 1 << 16, valueLength < 1 << 16, valueStart + valueLength <= end else { break }
                let key = String(decoding: bytes[keyStart..<keyStart + keyLength], as: UTF8.self)
                let value = String(decoding: bytes[valueStart..<valueStart + valueLength], as: UTF8.self)
                result.append((key, value))
            }
            position += 16 + Int(following)
        }
        return result
    }
}

/// The header of a boot or init_boot image (v3/v4): the Android version and
/// security patch level packed into `os_version`.
public struct BootImageHeader: Equatable, Sendable {
    public let headerVersion: UInt32
    /// `17.0.0`.
    public let osVersion: String?
    /// `2026-06`.
    public let securityPatch: String?

    public init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(64))
        guard bytes.count >= 44, bytes[0..<8].elementsEqual("ANDROID!".utf8) else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        headerVersion = u32(40)
        // v0–v2 keep os_version after the header version.
        let packed: UInt32 = headerVersion >= 3 ? u32(16) : bytes.count >= 48 ? u32(44) : 0
        guard packed != 0 else {
            osVersion = nil
            securityPatch = nil
            return
        }
        let a = packed >> 25, b = (packed >> 18) & 0x7F, c = (packed >> 11) & 0x7F
        let year = ((packed >> 4) & 0x7F) + 2000, month = packed & 0xF
        osVersion = "\(a).\(b).\(c)"
        securityPatch = month == 0 ? nil : String(format: "%04d-%02d", year, month)
    }
}

/// Checks on single files, from their first bytes.
enum ImageFileMagic {
    /// Whether the file at `url` looks like what its name says.
    static func check(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
        switch url.lastPathComponent {
        case "boot.img", "init_boot.img":
            return head.starts(with: Array("ANDROID!".utf8))
        case "vendor_boot.img":
            return head.starts(with: Array("VNDRBOOT".utf8))
        case "vbmeta.img", "vbmeta_system.img", "vbmeta_system_dlkm.img", "vbmeta_vendor_dlkm.img":
            return head.starts(with: Array("AVB0".utf8))
        case "super.img":
            // An Android sparse image (what the zip has), or a raw one, whose
            // logical-partition geometry sits at 4 KiB.
            if head.starts(with: [0x3A, 0xFF, 0x26, 0xED]) { return true }
            guard (try? handle.seek(toOffset: 4096)) != nil else { return false }
            return [UInt8]((try? handle.read(upToCount: 4)) ?? Data()) == Array("gDla".utf8)
        default:
            return true
        }
    }
}

extension ZipArchive {
    /// The entries of an archive from its last bytes (at least its central
    /// directory and end records), as an HTTP range request returns them:
    /// what a download will unpack to, before downloading it.
    public static func entries(tail: Data, archiveSize: UInt64) throws -> [ZipEntry] {
        guard UInt64(tail.count) <= archiveSize else { throw PackageError.malformed("more bytes than the archive has") }
        // The end record is looked for in the last 64 KiB: what was not
        // downloaded of them reads as zeros, which never look like one.
        let wanted = Int(min(archiveSize, 65_557))
        let bytes = tail.count < wanted ? [UInt8](repeating: 0, count: wanted - tail.count) + [UInt8](tail) : [UInt8](tail)
        return try ZipArchive(source: TailSource(bytes: bytes, size: archiveSize, known: UInt64(tail.count))).entries
    }
}

/// The end of a file whose start is not here.
private struct TailSource: ZipSource {
    let bytes: [UInt8]
    let size: UInt64
    /// Bytes at the end that were downloaded (the rest of `bytes` is padding).
    let known: UInt64

    var start: UInt64 { size - UInt64(bytes.count) }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard offset >= start, offset <= size, UInt64(count) <= size - offset else {
            throw PackageError.malformed("the central directory is not in the downloaded part")
        }
        // Padding only serves the search for the end record.
        if count != bytes.count, offset < size - known {
            throw PackageError.malformed("the central directory is not in the downloaded part")
        }
        let from = Int(offset - start)
        return Array(bytes[from..<from + count])
    }
}
