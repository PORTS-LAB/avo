import AvoKit
import CryptoKit
import Foundation
import Testing
@testable import AvoPackages

// Fakes for the Android image tests: recorded Android Build API answers,
// a file server that speaks HTTP ranges, and small synthetic Cuttlefish
// images (real headers and AVB properties, tiny partitions).

func androidBuildFixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "Fixtures/AndroidBuild/\(name)", withExtension: nil)))
}

/// One folder for this test process's scratch folders, removed when it exits.
private let scratchRoot: URL = {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "avo-image-tests-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    atexit { try? FileManager.default.removeItem(at: scratchRoot) }
    return root
}()

func scratchFolder(_ label: String = "images") throws -> URL {
    let url = scratchRoot.appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// AvoPaths inside a scratch folder, as if it were the home folder.
func scratchPaths() throws -> AvoPaths {
    AvoPaths(home: try scratchFolder("home"), temporaryDirectory: try scratchFolder("tmp"))
}

func md5Hex(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// MARK: - The Android Build API

/// Answers like the Android Build API, from the recorded fixtures and the
/// recorded version history of aosp-android-latest-release (every build's
/// build.prop, shortened to the version fields).
final class FixtureBuildAPI: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var history: [String: [String: String]]
    var buildsList: Data
    /// Builds whose image zip is missing (a partial upload).
    var withoutImage: Set<String> = []
    /// Image zips (synthetic images) by build, and where RangeFileServer serves them.
    private(set) var zips: [String: Data] = [:]
    private var zipURLs: [String: URL] = [:]

    /// Offers `zip` as `build`'s image; returns its RangeFileServer URL.
    @discardableResult
    func serve(_ zip: Data, build: String, file: (inout RangeFileServer.File) -> Void = { _ in }) -> URL {
        var served = RangeFileServer.File(data: zip, entityTag: "\"\(md5Hex(zip))\"")
        file(&served)
        let url = RangeFileServer.serve(served, name: "aosp_cf_arm64_only_phone-img-\(build).zip")
        lock.withLock {
            zips[build] = zip
            zipURLs[build] = url
        }
        return url
    }
    static let storage = "https://storage.example.test"

    init() throws {
        history = try JSONDecoder().decode([String: [String: String]].self, from: androidBuildFixture("build-properties-history.json"))
        buildsList = try androidBuildFixture("builds-aosp-android-latest-release.json")
    }

    var propertyFetches: Int { lock.withLock { requests.filter { $0.url?.lastPathComponent == "build.prop" }.count } }
    var apiRequests: Int { lock.withLock { requests.filter { $0.url?.host() == "androidbuild-pa.googleapis.com" }.count } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let url = try #require(request.url)
        func answer(_ status: Int, _ data: Data, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        if let build = lock.withLock({ zipURLs.first { $0.value.host() == url.host() }?.key }), let zip = zips[build] {
            // The image zip, through the transport: the range with its directory.
            if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
                let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                let start = Int(bounds[0])!, end = bounds.count > 1 && !bounds[1].isEmpty ? Int(bounds[1])! : zip.count - 1
                return answer(206, zip.subdata(in: start..<min(end + 1, zip.count)),
                              headers: ["Content-Range": "bytes \(start)-\(end)/\(zip.count)"])
            }
            return answer(200, zip)
        }
        if url.host() == URL(string: Self.storage)!.host() {
            // storage.example.test/<build>/build.prop
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, parts[1] == "build.prop", let values = history[parts[0]] else { return answer(404, Data()) }
            return answer(200, Data(values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n").utf8))
        }
        #expect(request.value(forHTTPHeaderField: "X-goog-api-key") == AndroidBuildSource.standard.apiKey)
        let path = url.path()
        if path.hasSuffix("/v4/builds") {
            return answer(200, buildsList)
        }
        // /v4/builds/<build>/<target>/attempts/latest/artifacts[/<name>/url]
        let parts = url.pathComponents.filter { $0 != "/" }
        let build = parts[2]
        if parts.last == "url" {
            let name = parts[parts.count - 2]
            if name.hasSuffix(".zip"), let served = lock.withLock({ zipURLs[build] }) {
                return answer(200, Data(#"{"signedUrl": "\#(served.absoluteString)"}"#.utf8))
            }
            return answer(200, Data(#"{"signedUrl": "\#(Self.storage)/\#(build)/\#(name)?Expires=1&Signature=x"}"#.utf8))
        }
        if parts.last == "artifacts" {
            let regexp = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "nameRegexp" }?.value ?? ""
            guard !withoutImage.contains(build) else { return answer(200, Data("{}".utf8)) }
            let name = "aosp_cf_arm64_only_phone-img-\(build).zip"
            #expect(regexp == "^" + NSRegularExpression.escapedPattern(for: name) + "$")
            if let zip = zips[build] {
                return answer(200, Data(#"{"artifacts": [{"name": "\#(name)", "size": "\#(zip.count)", "md5": "\#(md5Hex(zip))"}]}"#.utf8))
            }
            if let recorded = Bundle.module.url(forResource: "Fixtures/AndroidBuild/artifacts-img-\(build).json", withExtension: nil)
                .flatMap({ try? Data(contentsOf: $0) }) {
                return answer(200, recorded)
            }
            return answer(200, Data(#"{"artifacts": [{"name": "\#(name)", "size": "1000000000", "md5": "0123456789abcdef0123456789abcdef"}]}"#.utf8))
        }
        return answer(404, Data(#"{"error": {"code": 404, "message": "Not found"}}"#.utf8))
    }
}

// MARK: - A file server with ranges

/// Serves registered files over `https://<host>/<name>` to URLSessions
/// configured with it, honouring `Range` and `If-Range`, in small chunks.
final class RangeFileServer: URLProtocol, @unchecked Sendable {
    struct File {
        var data: Data
        var entityTag: String
        /// Answer 403 (an expired signed link) this many times first.
        var expiredAnswers = 0
        /// Answer 200 with everything, whatever the range.
        var ignoresRange = false
        /// Pause between chunks, so a test can stop a transfer halfway.
        var chunkDelay: TimeInterval = 0
        var chunkSize = 64 << 10
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [String: File] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]
    private let stopped = CancelFlag()

    /// Registers a file and returns its URL.
    static func serve(_ file: File, name: String = "image.zip") -> URL {
        let host = "files-\(UUID().uuidString.lowercased()).test"
        lock.withLock { files[host] = file }
        return URL(string: "https://\(host)/\(name)")!
    }

    static func requests(for url: URL) -> [URLRequest] { lock.withLock { log[url.host() ?? ""] ?? [] } }

    static func update(_ url: URL, _ change: (inout File) -> Void) {
        lock.withLock {
            guard var file = files[url.host() ?? ""] else { return }
            change(&file)
            files[url.host() ?? ""] = file
        }
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeFileServer.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { files[request.url?.host() ?? ""] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let host = request.url?.host() ?? ""
        let (file, expired): (File?, Bool) = Self.lock.withLock {
            Self.log[host, default: []].append(request)
            guard var file = Self.files[host] else { return (nil, false) }
            guard file.expiredAnswers > 0 else { return (file, false) }
            file.expiredAnswers -= 1
            Self.files[host] = file
            return (file, true)
        }
        guard let file, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        if expired {
            send(HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!, body: Data(), file: file)
            return
        }
        var start = 0
        var status = 200
        if !file.ignoresRange, let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="),
           request.value(forHTTPHeaderField: "If-Range").map({ $0 == file.entityTag }) ?? true {
            start = Int(range.dropFirst(6).split(separator: "-").first ?? "0") ?? 0
            status = 206
        }
        guard start <= file.data.count else {
            send(HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!, body: Data(), file: file)
            return
        }
        var headers = ["ETag": file.entityTag, "Content-Length": "\(file.data.count - start)"]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(file.data.count - 1)/\(file.data.count)" }
        send(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
             body: file.data.subdata(in: start..<file.data.count), file: file)
    }

    private func send(_ response: HTTPURLResponse, body: Data, file: File) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let stopped = self.stopped
        DispatchQueue.global().async { [weak self] in
            var offset = 0
            while offset < body.count {
                if stopped.isSet { return }
                let end = min(offset + file.chunkSize, body.count)
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
                if file.chunkDelay > 0 { Thread.sleep(forTimeInterval: file.chunkDelay) }
            }
            guard let self, !stopped.isSet else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.set()
    }
}

// MARK: - Synthetic Cuttlefish images

/// A tiny Cuttlefish image whose headers and AVB properties are real.
struct SyntheticImage {
    var version = "17"
    var build = "16373615"
    var buildTag = "CP2A.260605.016"
    var device = "vsoc_arm64_only"
    var product = "aosp_cf_arm64_only_phone"
    var variant = "userdebug"
    var securityPatch = "2026-06-05"
    /// Partition bytes (super.img gets a sparse header first).
    var payload = 4096

    var fingerprint: String { "generic/\(product)/\(device):\(version)/\(buildTag)/\(build):\(variant)/test-keys" }

    /// File name → contents.
    var files: [String: Data] {
        let seed = build.utf8.reduce(0) { $0 &+ Int($1) }
        let filler = Data((0..<payload).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) })
        return [
            "boot.img": Self.bootImage(version: version, patch: String(securityPatch.prefix(7))) + filler,
            "init_boot.img": Self.bootImage(version: version, patch: String(securityPatch.prefix(7))) + filler,
            "vendor_boot.img": Data("VNDRBOOT".utf8) + Data(count: 56) + filler,
            "super.img": Data([0x3A, 0xFF, 0x26, 0xED, 1, 0, 0, 0]) + filler + filler,
            "vbmeta.img": Self.vbmeta([
                ("com.android.build.vendor.os_version", version),
                ("com.android.build.vendor.fingerprint", fingerprint),
                ("com.android.build.vendor.security_patch", securityPatch),
            ]),
            "vbmeta_system.img": Self.vbmeta([
                ("com.android.build.system.os_version", version),
                ("com.android.build.system.fingerprint", "Android/generic_system/generic:\(version)/\(buildTag)/\(build):\(variant)/test-keys"),
                ("com.android.build.system.security_patch", securityPatch),
            ]),
            "android-info.txt": Data("config=phone\n".utf8),
        ]
    }

    /// Writes the files into `folder` (created).
    @discardableResult
    func write(to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: folder.appending(path: name)) }
        return folder
    }

    /// The image zip (stored entries).
    func zip(extra: [(String, Data)] = []) -> Data {
        makeStoredZip(files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } + extra)
    }

    /// A boot image v4 header with `os_version`.
    static func bootImage(version: String, patch: String) -> Data {
        var header = Data("ANDROID!".utf8)
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let parts = patch.split(separator: "-").compactMap { UInt32($0) }
        let major = UInt32(version) ?? 0
        let packed = (major << 25) | ((parts[0] - 2000) << 4) | parts[1]
        header += u32(0) + u32(0) + u32(packed) + u32(1580) + Data(count: 16) + u32(4)
        return header + Data(count: 4096 - header.count)
    }

    /// A vbmeta image with property descriptors (no signature).
    static func vbmeta(_ properties: [(String, String)]) -> Data {
        func u64(_ value: Int) -> Data { withUnsafeBytes(of: UInt64(value).bigEndian) { Data($0) } }
        var descriptors = Data()
        for (key, value) in properties {
            var body = u64(key.utf8.count) + u64(value.utf8.count) + Data(key.utf8) + Data([0]) + Data(value.utf8) + Data([0])
            body += Data(count: (8 - body.count % 8) % 8)
            descriptors += u64(0) + u64(body.count) + body
        }
        var header = Data("AVB0".utf8) + Data(count: 4) + Data(count: 4)
        header += u64(0) + u64(descriptors.count)            // authentication, auxiliary block sizes
        header += Data(count: 96 - header.count)
        header += u64(0) + u64(descriptors.count)            // descriptors offset and size
        header += Data(count: 256 - header.count)
        let image = header + descriptors
        return image + Data(count: 4096 - image.count % 4096)
    }
}

/// A ZIP with stored entries.
func makeStoredZip(_ entries: [(String, Data)]) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    var body = Data()
    var directory = Data()
    for (name, content) in entries {
        var crc = CRC32()
        crc.update(content)
        let nameBytes = Data(name.utf8)
        let offset = UInt32(body.count)
        var common = le(UInt16(20)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0))
        common += le(crc.checksum) + le(UInt32(content.count)) + le(UInt32(content.count))
        common += le(UInt16(nameBytes.count)) + le(UInt16(0))
        body += le(UInt32(0x0403_4B50)) + common + nameBytes + content
        directory += le(UInt32(0x0201_4B50)) + le(UInt16(20)) + common
        directory += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)) + le(offset) + nameBytes
    }
    var end = le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0))
    end += le(UInt16(entries.count)) + le(UInt16(entries.count)) + le(UInt32(directory.count)) + le(UInt32(body.count)) + le(UInt16(0))
    return body + directory + end
}

/// Collects job events from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AndroidImageJob.Event] = []

    func add(_ event: AndroidImageJob.Event) { lock.withLock { events.append(event) } }
    var all: [AndroidImageJob.Event] { lock.withLock { events } }
}
