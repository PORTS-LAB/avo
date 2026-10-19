import AvoKit
import Foundation

// Android images to download (Setup Assistant, Settings › System › Android
// version): AOSP Cuttlefish builds from Google's public Android Build API,
// the service behind ci.android.com that scripts/fetch-cuttlefish.sh and
// Cuttlefish's own `cvd` tool use. Avo never ships or mirrors an image.

// MARK: - Source

/// Where Avo looks for Android images, in one place: the API, its key, the
/// release branches and the Cuttlefish target avo-vmm boots. Developers can
/// override each part with the Control Panel's defaults (`current(defaults:)`).
public struct AndroidBuildSource: Codable, Equatable, Sendable {
    /// Android Build API v4.
    public var endpoint: URL
    /// The public key the Cuttlefish `cvd` tool ships for public AOSP builds
    /// (google/android-cuttlefish, android_build_api_key.cc); the same one
    /// scripts/fetch-cuttlefish.sh uses.
    public var apiKey: String
    /// Release branches to offer. Each branch's history is searched for
    /// older Android versions too.
    public var branches: [String]
    /// `<product>-<variant>`: the arm64-only Cuttlefish phone. userdebug,
    /// because the daemon's host agent needs root (`su`) in Android.
    public var target: String
    /// Older builds are not offered (spec: AOSP 16 or newer).
    public var minimumSDK: Int
    /// How many of a branch's newest builds are looked at.
    public var historyLimit: Int
    /// Android versions older than `minimumSDK`, offered apart (Older
    /// Versions). Google builds them only as `aosp_cf_arm64_phone`, with
    /// 32-bit parts Apple silicon cannot run, so they may not start. Android
    /// 11 and 12 are left out: their images have no init_boot, which Avo needs.
    public var olderChannels: [Channel]

    /// A branch and the target to take from it.
    public struct Channel: Codable, Equatable, Hashable, Sendable {
        public var branch: String
        public var target: String

        public init(branch: String, target: String) {
            self.branch = branch
            self.target = target
        }
    }

    public init(endpoint: URL, apiKey: String, branches: [String], target: String, minimumSDK: Int = 36, historyLimit: Int = 100,
                olderChannels: [Channel] = []) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.branches = branches
        self.target = target
        self.minimumSDK = minimumSDK
        self.historyLimit = historyLimit
        self.olderChannels = olderChannels
    }

    public static let standard = AndroidBuildSource(
        endpoint: URL(string: "https://androidbuild-pa.googleapis.com/v4")!,
        apiKey: "AIzaSyBIelMvbjtNkpa5O96eqbm_IuSUA5WsO14",
        branches: ["aosp-android-latest-release"],
        target: "aosp_cf_arm64_only_phone-userdebug",
        olderChannels: [
            Channel(branch: "aosp-android14-gsi", target: "aosp_cf_arm64_phone-userdebug"),
            Channel(branch: "aosp-android13-gsi", target: "aosp_cf_arm64_phone-userdebug"),
        ])

    /// The same API and key, for another target.
    public func with(target: String) -> AndroidBuildSource {
        var source = self
        source.target = target
        return source
    }

    /// Defaults keys that change `standard` (`defaults write emu.avo.droid …`):
    /// an https URL, a key, branches (an array, or one string with commas),
    /// a target and the lowest API level offered.
    public enum DefaultsKey {
        public static let endpoint = "AvoBuildAPIEndpoint"
        public static let apiKey = "AvoBuildAPIKey"
        public static let branches = "AvoBuildBranches"
        public static let target = "AvoBuildTarget"
        public static let minimumSDK = "AvoBuildMinimumSDK"
    }

    public static func current(defaults: UserDefaults = .standard) -> AndroidBuildSource {
        var source = standard
        if let text = defaults.string(forKey: DefaultsKey.endpoint), let url = URL(string: text), url.scheme == "https" {
            source.endpoint = url
        }
        if let key = defaults.string(forKey: DefaultsKey.apiKey)?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            source.apiKey = key
        }
        let branches: [String]? = switch defaults.object(forKey: DefaultsKey.branches) {
        case let list as [String]: list
        case let text as String: text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default: nil
        }
        if let branches = branches?.filter({ !$0.isEmpty }), !branches.isEmpty { source.branches = branches }
        if let target = defaults.string(forKey: DefaultsKey.target)?.trimmingCharacters(in: .whitespaces), !target.isEmpty {
            source.target = target
        }
        let minimum = defaults.integer(forKey: DefaultsKey.minimumSDK)
        if minimum > 0 { source.minimumSDK = minimum }
        return source
    }

    /// `aosp_cf_arm64_only_phone`: the target without its variant.
    public var product: String {
        target.range(of: "-", options: .backwards).map { String(target[..<$0.lowerBound]) } ?? target
    }

    /// The zip with the partition images (what fetch-cuttlefish.sh downloads).
    public func imageArtifact(build: String) -> String { "\(product)-img-\(build).zip" }

    /// The build's page on ci.android.com.
    public func webPage(build: String) -> URL? {
        URL(string: "https://ci.android.com/builds/submitted/\(build)/\(target)/latest")
    }
}

// MARK: - Releases

/// Which Android a build is, from its `build.prop` (catalog) or the AVB
/// properties of its images (an import).
public struct AndroidRelease: Codable, Hashable, Sendable {
    /// `17` (`ro.build.version.release_or_codename`).
    public var version: String
    /// API level (`ro.build.version.sdk`).
    public var sdk: Int
    /// `36.1` for a quarterly release with a minor API level; nil before Android 16.
    public var sdkFull: String?
    /// `2026-06-05`.
    public var securityPatch: String?
    /// Android's own build ID (`CP2A.260605.016`), not the CI build number.
    public var buildTag: String?

    public init(version: String, sdk: Int, sdkFull: String? = nil, securityPatch: String? = nil, buildTag: String? = nil) {
        self.version = version
        self.sdk = sdk
        self.sdkFull = sdkFull
        self.securityPatch = securityPatch
        self.buildTag = buildTag
    }

    /// From `build.prop` text (`key=value` lines).
    public init?(buildProperties text: String) {
        let properties = BuildProperties(text)
        guard let version = properties["ro.build.version.release_or_codename"] ?? properties["ro.build.version.release"],
              let sdk = properties["ro.build.version.sdk"].flatMap({ Int($0) }) else { return nil }
        self.init(version: version, sdk: sdk, sdkFull: properties["ro.build.version.sdk_full"],
                  securityPatch: properties["ro.build.version.security_patch"],
                  buildTag: properties["ro.build.id"] ?? properties["ro.system.build.id"])
    }

    /// `Android 17`.
    public var name: String { "Android \(version)" }

    /// The major version as a number (nil for a codename).
    public var major: Int? { Int(version.split(separator: ".").first ?? "") }

    /// API level for an Android version (13 and later: version + 20), for
    /// images whose properties name only the version.
    public static func sdk(forVersion version: String) -> Int? {
        guard let major = Int(version.split(separator: ".").first ?? ""), major >= 13 else { return nil }
        return major + 20
    }

    /// Whether Android's data from `other` cannot be used by `self`: a lower
    /// API level (or minor level), or the same with an older security patch
    /// (Keystore keys, which unlock Android's data, refuse to go back).
    public func isOlder(than other: AndroidRelease) -> Bool {
        if sdk != other.sdk { return sdk < other.sdk }
        if let mine = sdkFull.flatMap(Self.minor), let theirs = other.sdkFull.flatMap(Self.minor), mine != theirs { return mine < theirs }
        if let mine = securityPatch, let theirs = other.securityPatch, mine != theirs { return mine < theirs }
        return false
    }

    private static func minor(_ full: String) -> Int? {
        let parts = full.split(separator: ".")
        return parts.count == 2 ? Int(parts[1]) : nil
    }
}

/// `build.prop`: `key=value` lines, comments starting with `#`.
public struct BuildProperties: Equatable, Sendable {
    public let values: [String: String]

    public init(_ text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals])
            // The first definition wins, as in Android's property loader.
            if values[key] == nil { values[key] = String(trimmed[trimmed.index(after: equals)...]) }
        }
        self.values = values
    }

    public subscript(key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
}

// MARK: - Offers

/// A build Avo can download: the newest successful one of its Android version.
public struct AndroidImageOffer: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The CI build number (`16373615`).
    public var build: String
    public var branch: String
    public var target: String
    public var release: AndroidRelease
    /// When the build started on ci.android.com.
    public var date: Date?
    /// The image zip and what the API says about it.
    public var artifact: String
    public var downloadSize: Int64
    public var md5: String

    public init(build: String, branch: String, target: String, release: AndroidRelease, date: Date?, artifact: String,
                downloadSize: Int64, md5: String) {
        self.build = build
        self.branch = branch
        self.target = target
        self.release = release
        self.date = date
        self.artifact = artifact
        self.downloadSize = downloadSize
        self.md5 = md5
    }

    public var id: String { "\(target)/\(build)" }

    /// Newest Android first; within one, the newest build.
    public static func newestFirst(_ a: AndroidImageOffer, _ b: AndroidImageOffer) -> Bool {
        if a.release != b.release {
            if a.release.isOlder(than: b.release) { return false }
            if b.release.isOlder(than: a.release) { return true }
        }
        if let x = Int(a.build), let y = Int(b.build), x != y { return x > y }
        return (a.date ?? .distantPast) > (b.date ?? .distantPast)
    }
}

// MARK: - Errors

public enum AndroidImageError: Error, Equatable, Sendable, LocalizedError {
    /// The request did not get through (offline, DNS, TLS…).
    case network(String)
    /// The API answered with an error.
    case api(status: Int, message: String?)
    /// None of the branches has a build of the target.
    case noBuilds(String)
    /// The build has no image zip.
    case artifactMissing(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    /// The download does not match the MD5 the API gave.
    case checksumMismatch(String)
    /// Not an image Avo can boot, and why.
    case notAnImage(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            String(localized: "Avo couldn’t reach Google’s Android build servers: \(detail)", bundle: .avoKit)
        case let .api(status, message?):
            String(localized: "Google’s Android build servers refused the request (HTTP \(status)): \(message)", bundle: .avoKit)
        case let .api(status, nil):
            String(localized: "Google’s Android build servers refused the request (HTTP \(status)).", bundle: .avoKit)
        case .noBuilds(let target):
            String(localized: "There are no Android builds of \(target) to download right now.", bundle: .avoKit)
        case .artifactMissing(let build):
            String(localized: "Build \(build) has no Android image to download.", bundle: .avoKit)
        case let .notEnoughSpace(needed, available):
            String(localized: "There isn’t enough free disk space. Android needs \(Self.bytes(needed)), and \(Self.bytes(available)) is free.",
                   bundle: .avoKit)
        case .checksumMismatch(let name):
            String(localized: "The download of \(name) is damaged (its checksum doesn’t match). Download it again.", bundle: .avoKit)
        case .notAnImage(let reason):
            reason
        case .io(let detail):
            String(localized: "The Android image could not be saved: \(detail)", bundle: .avoKit)
        }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

// MARK: - HTTP

/// What the catalog and downloads send requests through; tests replace it.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// At most `limit` bytes of the body (a range a server might ignore).
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    public func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        return (data.prefix(limit), response)
    }
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public static let shared = URLSessionTransport(session: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "Avo"]
        return URLSession(configuration: configuration)
    }())

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AndroidImageError.network("no HTTP response") }
        return (data, http)
    }

    /// Stops reading after `limit` bytes, so a server that answers a range
    /// request with the whole gigabyte file is not read to the end.
    public func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AndroidImageError.network("no HTTP response") }
        var data = Data()
        data.reserveCapacity(min(limit, 1 << 20))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return (data, http)
    }
}

// MARK: - API

/// The Android Build API's answers, only what Avo reads.
public enum AndroidBuildAPI {
    public struct Build: Decodable, Equatable, Sendable {
        public struct Target: Decodable, Equatable, Sendable {
            public let name: String
        }

        public let buildId: String
        public let branch: String
        public let target: Target?
        public let successful: Bool?
        public let creationTimestamp: Date?
        public let completionTimestamp: Date?

        public init(buildId: String, branch: String, target: String?, successful: Bool? = true,
                    creationTimestamp: Date? = nil, completionTimestamp: Date? = nil) {
            self.buildId = buildId
            self.branch = branch
            self.target = target.map(Target.init(name:))
            self.successful = successful
            self.creationTimestamp = creationTimestamp
            self.completionTimestamp = completionTimestamp
        }
    }

    public struct BuildList: Decodable, Sendable {
        public let builds: [Build]
        public let nextPageToken: String?

        enum CodingKeys: String, CodingKey { case builds, nextPageToken }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A branch without builds of the target answers `{}`.
            builds = try container.decodeIfPresent([Build].self, forKey: .builds) ?? []
            nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        }
    }

    public struct Artifact: Decodable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public let md5: String?

        enum CodingKeys: String, CodingKey { case name, size, md5 }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            // int64 fields are JSON strings in Google's APIs.
            if let text = try? container.decode(String.self, forKey: .size), let value = Int64(text) {
                size = value
            } else {
                size = try container.decode(Int64.self, forKey: .size)
            }
            md5 = try container.decodeIfPresent(String.self, forKey: .md5)?.lowercased()
        }
    }

    public struct ArtifactList: Decodable, Sendable {
        public let artifacts: [Artifact]

        enum CodingKeys: String, CodingKey { case artifacts }

        public init(from decoder: any Decoder) throws {
            artifacts = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Artifact].self, forKey: .artifacts) ?? []
        }
    }

    public struct SignedURL: Decodable, Sendable {
        public let signedUrl: URL
    }

    /// `{"error": {"code": 400, "message": "…"}}`.
    struct Failure: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = timestamp(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a timestamp: \(text)"))
        }
        return try decoder.decode(type, from: data)
    }

    /// `2026-09-17T15:53:08.934Z`, with or without the fraction.
    static func timestamp(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
    }

    /// The API's own message from an error answer.
    static func failureMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(Failure.self, from: data))?.error.message
    }
}

/// Requests to the Android Build API for one source.
public struct AndroidBuildClient: Sendable {
    public let source: AndroidBuildSource
    let transport: any HTTPTransport

    public init(source: AndroidBuildSource, transport: any HTTPTransport = URLSessionTransport.shared) {
        self.source = source
        self.transport = transport
    }

    /// The same API, key and transport, for another target (an offer's).
    public func with(target: String) -> AndroidBuildClient {
        target == source.target ? self : AndroidBuildClient(source: source.with(target: target), transport: transport)
    }

    /// Successful builds of the target on `branch`, newest first.
    public func builds(branch: String, limit: Int) async throws -> [AndroidBuildAPI.Build] {
        let query: [(String, String)] = [
            ("branches", branch), ("targets", source.target), ("buildType", "submitted"),
            ("buildAttemptStatus", "complete"), ("successful", "true"), ("pageSize", "\(min(max(limit, 1), 100))"),
            ("fields", "builds(buildId,branch,creationTimestamp,completionTimestamp,successful,target(name)),nextPageToken"),
        ]
        let list = try AndroidBuildAPI.decode(AndroidBuildAPI.BuildList.self, from: try await get(["builds"], query: query))
        return list.builds
            .filter { $0.successful != false && ($0.target?.name ?? source.target) == source.target }
            .sorted { (Int($0.buildId) ?? 0) > (Int($1.buildId) ?? 0) }
    }

    /// One artifact's size and MD5, nil when the build does not have it.
    public func artifact(_ name: String, build: String) async throws -> AndroidBuildAPI.Artifact? {
        let query = [("pageSize", "10"), ("nameRegexp", "^" + NSRegularExpression.escapedPattern(for: name) + "$")]
        let data = try await get(["builds", build, source.target, "attempts", "latest", "artifacts"], query: query)
        return try AndroidBuildAPI.decode(AndroidBuildAPI.ArtifactList.self, from: data).artifacts.first { $0.name == name }
    }

    /// A short-lived link to the artifact on Google Cloud Storage (minutes):
    /// asked again before every request, also to continue a download.
    public func signedURL(_ name: String, build: String) async throws -> URL {
        let data = try await get(["builds", build, source.target, "attempts", "latest", "artifacts", name, "url"], query: [])
        return try AndroidBuildAPI.decode(AndroidBuildAPI.SignedURL.self, from: data).signedUrl
    }

    /// The build's Android version, from its `build.prop` artifact (6 KB).
    public func release(build: String) async throws -> AndroidRelease? {
        let url = try await signedURL("build.prop", build: build)
        let (data, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { return nil }
            throw AndroidImageError.api(status: response.statusCode, message: AndroidBuildAPI.failureMessage(data))
        }
        return AndroidRelease(buildProperties: String(decoding: data, as: UTF8.self))
    }

    /// `bytes=<range>` of a signed URL (the end of a zip, for its directory).
    public func range(_ url: URL, _ range: ClosedRange<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let wanted = Int(range.upperBound - range.lowerBound + 1)
        let (data, response) = try await send(request, limit: wanted)
        switch response.statusCode {
        case 206: return data
        // A server that ignores Range sends the file from its start.
        case 200 where range.lowerBound == 0: return data
        default:
            throw AndroidImageError.api(status: response.statusCode, message: AndroidBuildAPI.failureMessage(data))
        }
    }

    func get(_ path: [String], query: [(String, String)]) async throws -> Data {
        var url = source.endpoint
        for part in path { url.append(path: part) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        var request = URLRequest(url: components.url!)
        request.setValue(source.apiKey, forHTTPHeaderField: "X-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw AndroidImageError.api(status: response.statusCode, message: AndroidBuildAPI.failureMessage(data))
        }
        return data
    }

    func send(_ request: URLRequest, limit: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            if let limit { return try await transport.data(for: request, limit: limit) }
            return try await transport.data(for: request)
        } catch let error as AndroidImageError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AndroidImageError.network(error.localizedDescription)
        }
    }

    /// Percent-encodes everything but RFC 3986's unreserved characters.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

// MARK: - Catalog

/// The builds Avo offers: for every Android version in the source's branches
/// (at or above `minimumSDK`), its newest successful build with an image zip.
public struct AndroidImageCatalog: Sendable {
    public let client: AndroidBuildClient
    /// Android versions of builds seen before (they never change), so a
    /// listing usually needs only the builds list and one artifact per
    /// offer; and the last listing, shown while a new one loads.
    let cacheFile: URL?

    public init(source: AndroidBuildSource = .current(), transport: any HTTPTransport = URLSessionTransport.shared,
                cacheFile: URL? = AndroidImageStore(paths: AvoPaths()).catalogCache) {
        client = AndroidBuildClient(source: source, transport: transport)
        self.cacheFile = cacheFile
    }

    public var source: AndroidBuildSource { client.source }

    var listingFile: URL? { cacheFile.map { $0.deletingLastPathComponent().appending(path: "offers.json") } }

    struct Listing: Codable {
        var source: AndroidBuildSource
        var date: Date
        var offers: [AndroidImageOffer]
    }

    /// The last listing of this source, and when it was made.
    public func lastOffers() -> (offers: [AndroidImageOffer], date: Date)? {
        guard let file = listingFile, let data = try? Data(contentsOf: file),
              let listing = try? JSONDecoder().decode(Listing.self, from: data), listing.source == source else { return nil }
        return (listing.offers, listing.date)
    }

    public func offers() async throws -> [AndroidImageOffer] {
        try await offers(minimumSDK: source.minimumSDK, saveListing: true)
    }

    /// The source's branches, from `minimumSDK` up; `saveListing` keeps it
    /// for the next time the picker opens (the source's own listing only).
    func offers(minimumSDK: Int, saveListing: Bool) async throws -> [AndroidImageOffer] {
        let cache = ReleaseCache(file: cacheFile, target: source.target)
        let client = self.client
        let source = self.source
        var offers: [AndroidImageOffer] = []
        var sawBuilds = false
        for branch in source.branches {
            let builds = try await client.builds(branch: branch, limit: source.historyLimit)
            sawBuilds = sawBuilds || !builds.isEmpty
            let groups = try await Self.newestPerVersion(builds, minimumSDK: minimumSDK) { build in
                if let known = await cache.release(build.buildId) { return known }
                let release = try await client.release(build: build.buildId)
                if let release { await cache.store(release, for: build.buildId) }
                return release
            }
            offers += try await withThrowingTaskGroup(of: (Int, AndroidImageOffer?).self) { tasks in
                for (position, group) in groups.enumerated() {
                    tasks.addTask {
                        // The newest build of a version without an image zip
                        // (a partial upload): the next one of the same version.
                        for build in group.builds.prefix(3) {
                            let name = source.imageArtifact(build: build.buildId)
                            guard let artifact = try await client.artifact(name, build: build.buildId), let md5 = artifact.md5 else { continue }
                            return (position, AndroidImageOffer(build: build.buildId, branch: branch, target: source.target, release: group.release,
                                                                date: build.creationTimestamp ?? build.completionTimestamp, artifact: name,
                                                                downloadSize: artifact.size, md5: md5))
                        }
                        return (position, nil)
                    }
                }
                var found: [(Int, AndroidImageOffer?)] = []
                for try await result in tasks { found.append(result) }
                return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
        }
        await cache.save()
        guard sawBuilds else { throw AndroidImageError.noBuilds(source.target) }
        let arranged = Self.arrange(offers)
        // Dates as numbers: exactly what was listed (ISO 8601 drops the milliseconds).
        if saveListing, let file = listingFile, let data = try? JSONEncoder().encode(Listing(source: source, date: Date(), offers: arranged)) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return arranged
    }

    /// Older Android versions, below `minimumSDK`: those still in the
    /// source's own branches (64-bit only, like the current ones), then the
    /// newest build of each of `olderChannels`; newest Android first, one per
    /// version. A branch or channel that cannot be read is left out.
    public func olderOffers() async throws -> [AndroidImageOffer] {
        let source = self.source
        let base = client
        let own = ((try? await offers(minimumSDK: Self.oldestSDK, saveListing: false)) ?? []).filter { $0.release.sdk < source.minimumSDK }
        let offers = own + (await withTaskGroup(of: AndroidImageOffer?.self) { tasks in
            for channel in source.olderChannels {
                tasks.addTask {
                    let client = base.with(target: channel.target)
                    guard let builds = try? await client.builds(branch: channel.branch, limit: 3) else { return nil }
                    for build in builds {
                        guard let release = try? await client.release(build: build.buildId), release.sdk < source.minimumSDK else { continue }
                        let name = client.source.imageArtifact(build: build.buildId)
                        guard let artifact = try? await client.artifact(name, build: build.buildId), let md5 = artifact.md5 else { continue }
                        return AndroidImageOffer(build: build.buildId, branch: channel.branch, target: channel.target, release: release,
                                                 date: build.creationTimestamp ?? build.completionTimestamp, artifact: name,
                                                 downloadSize: artifact.size, md5: md5)
                    }
                    return nil
                }
            }
            var found: [AndroidImageOffer] = []
            for await offer in tasks { if let offer { found.append(offer) } }
            return found
        })
        try Task.checkCancellation()
        return Self.arrange(offers)
    }

    /// Android 13: older images have no init_boot, which Avo needs.
    public static let oldestSDK = 33

    /// Newest Android first, one offer per Android version (the newest
    /// build when several branches have it).
    public static func arrange(_ offers: [AndroidImageOffer]) -> [AndroidImageOffer] {
        var seen = Set<String>()
        return offers.sorted(by: AndroidImageOffer.newestFirst).filter { seen.insert($0.release.version).inserted }
    }

    /// One Android version's builds, newest first.
    public struct VersionGroup: Sendable {
        public let release: AndroidRelease
        public let builds: [AndroidBuildAPI.Build]
    }

    /// Splits `builds` (newest first) into runs of one Android version,
    /// asking `release(of:)` about as few builds as it can, several at a
    /// time: within a branch the version only goes up, so it looks at evenly
    /// spaced builds, then only between two that differ, until each run's
    /// first build is known. Versions below `minimumSDK` are not looked
    /// into. Builds whose version is unknown are skipped.
    public static func newestPerVersion(_ builds: [AndroidBuildAPI.Build], minimumSDK: Int, width: Int = 6,
                                        release: @escaping @Sendable (AndroidBuildAPI.Build) async throws -> AndroidRelease?)
        async throws -> [VersionGroup] {
        let count = builds.count
        guard count > 0 else { return [] }
        var asked: [Int: AndroidRelease?] = [:]
        func ask(_ indices: [Int]) async throws {
            let wanted = Set(indices).filter { asked[$0] == nil }
            let answers = try await withThrowingTaskGroup(of: (Int, AndroidRelease?).self) { tasks in
                for index in wanted { tasks.addTask { (index, try await release(builds[index])) } }
                var answers: [(Int, AndroidRelease?)] = []
                for try await answer in tasks { answers.append(answer) }
                return answers
            }
            for (index, value) in answers { asked[index] = .some(value) }
        }
        func known() -> [(index: Int, release: AndroidRelease)] {
            asked.compactMap { index, value in value.map { (index, $0) } }.sorted { $0.index < $1.index }
        }

        try await ask(Array(stride(from: 0, to: count, by: max(1, count / width))) + [count - 1])
        while true {
            var questions: [Int] = []
            let points = known()
            for (newer, older) in zip(points, points.dropFirst())
            where newer.release.version != older.release.version && newer.release.sdk >= minimumSDK {
                let between = (newer.index + 1..<older.index).filter { asked[$0] == nil }
                guard !between.isEmpty else { continue }
                questions += between.count <= width ? between : (1...width).map { between[$0 * between.count / (width + 1)] }
            }
            guard !questions.isEmpty else { break }
            try await ask(questions)
        }

        // Each run starts at the first known build of its version.
        var starts: [(index: Int, release: AndroidRelease)] = []
        for point in known() where point.release.version != starts.last?.release.version { starts.append(point) }
        var groups: [VersionGroup] = []
        for (position, start) in starts.enumerated() {
            guard start.release.sdk >= minimumSDK else { break }
            let end = position + 1 < starts.count ? starts[position + 1].index : count
            groups.append(VersionGroup(release: start.release, builds: Array(builds[start.index..<end])))
        }
        return groups
    }
}

/// `build → Android release`, kept on disk between listings.
actor ReleaseCache {
    private let file: URL?
    private let target: String
    private var entries: [String: [String: AndroidRelease]]
    private var changed = false

    init(file: URL?, target: String) {
        self.file = file
        self.target = target
        entries = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [String: AndroidRelease]].self, from: $0) } ?? [:]
    }

    func release(_ build: String) -> AndroidRelease? { entries[target]?[build] }

    func store(_ release: AndroidRelease, for build: String) {
        entries[target, default: [:]][build] = release
        changed = true
    }

    func save() {
        guard changed, let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        changed = false
    }
}
