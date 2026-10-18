import AvoKit
import Foundation

// Which Google apps fit this Android, and where they are: Settings › Google
// Apps lists the MindTheGapps builds for the Android that runs (or starts
// next) instead of asking for a link, and says what to do when the Android
// version and the Google apps on Android's storage no longer match.

/// MindTheGapps publishes each Android version's packages in a GitHub
/// repository of their own, named for the version and the architecture
/// (`MindTheGapps/17.0.0-arm64`); every release there holds one flashable
/// .zip with its `.sha256sum`, and GitHub keeps a SHA-256 digest of each.
/// A package fits only the Android version it names (its build.prop's
/// `version`, the API level, must be Android's: `GoogleAppsPackage.plan`).
public struct GoogleAppsLine: Codable, Hashable, Sendable {
    public static let owner = "MindTheGapps"
    /// Android's major version (`17`).
    public var android: Int
    /// `arm64`, as MindTheGapps' build.prop names it (`ro.bionic.arch`).
    public var arch: String

    public init(android: Int, arch: String = "arm64") {
        self.android = android
        self.arch = arch
    }

    /// The line for `release`; nil for a codename, which has no number to match.
    public init?(release: AndroidRelease, arch: String = "arm64") {
        guard let major = release.major, major > 0 else { return nil }
        self.init(android: major, arch: arch)
    }

    /// The line for an API level (Android 13 and later: the level − 20).
    public init?(sdk: Int, arch: String = "arm64") {
        guard sdk >= 33 else { return nil }
        self.init(android: sdk - 20, arch: arch)
    }

    /// `17.0.0`, the packages' `version_nice`.
    public var version: String { "\(android).0.0" }
    /// `17.0.0-arm64`.
    public var repository: String { "\(version)-\(arch)" }
    /// `MindTheGapps 17.0.0 (arm64)`.
    public var name: String { "MindTheGapps \(version) (\(arch))" }
    /// The releases page, as people find it.
    public var page: URL { URL(string: "https://github.com/\(Self.owner)/\(repository)/releases")! }
    /// The API's list of the newest releases.
    public var listURL: URL {
        URL(string: "https://api.github.com/repos/\(Self.owner)/\(repository)/releases?per_page=\(Self.listLength)")!
    }

    /// Releases asked for at once: a few years of builds.
    static let listLength = 20
}

/// One MindTheGapps build of a line, ready to install from GitHub.
public struct GoogleAppsBuild: Codable, Hashable, Sendable, Identifiable {
    /// The release's tag (`MindTheGapps-17.0.0-arm64-20261006_111038`).
    public var tag: String
    /// The package's file name.
    public var file: String
    public var size: UInt64
    /// When the release was published.
    public var date: Date?
    /// The package's link (`…/releases/download/<tag>/<file>`), which the
    /// daemon's download takes as it is (`GitHubRelease.apiURL`).
    public var link: String

    public var id: String { tag }

    public init(tag: String, file: String, size: UInt64, date: Date?, link: String) {
        self.tag = tag
        self.file = file
        self.size = size
        self.date = date
        self.link = link
    }

    /// The builds among `releases` Avo can install, newest first: published
    /// (no drafts or pre-releases), with a .zip package (the line's
    /// architecture when there are several) and a SHA-256 to check it
    /// against (GitHub's digest or the release's `.sha256sum`), as the
    /// daemon's download requires.
    public static func builds(from releases: [GitHubRelease], line: GoogleAppsLine) -> [GoogleAppsBuild] {
        let builds = releases.compactMap { release -> GoogleAppsBuild? in
            guard !release.draft, !release.prerelease else { return nil }
            let zips = release.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
            let package = zips.count == 1 ? zips.first : zips.first { $0.name.lowercased().contains(line.arch.lowercased()) }
            guard let package, package.size > 0, package.sha256 != nil || release.checksumAsset(for: package) != nil else { return nil }
            return GoogleAppsBuild(tag: release.tagName, file: package.name, size: package.size, date: release.publishedAt,
                                   link: package.browserDownloadURL.absoluteString)
        }
        return builds.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: return x > y
            // GitHub's own order (newest first) otherwise.
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// The builds of each line, from GitHub's API, with the last answer kept in
/// `AvoPaths.googleAppsReleases`: shown at once, and instead of GitHub's
/// answer while GitHub can't be reached or refuses this network (it allows
/// 60 requests an hour without an account). A listing younger than
/// `maxAge` is used as it is; an older one is asked for again with its
/// ETag, and GitHub's "not modified" does not count against that limit.
public struct GoogleAppsCatalog: Sendable {
    /// Why GitHub gave no new list.
    public enum Problem: Equatable, Sendable {
        /// GitHub could not be reached (offline, a timeout); the system's words.
        case unreachable(String)
        /// GitHub refuses this network for now, until about `until`.
        case rateLimited(until: Date?)
        /// Another HTTP status.
        case status(Int)
        /// The answer was not a release list.
        case unreadable
    }

    /// What GitHub said about a line, and when.
    public struct Listing: Codable, Equatable, Sendable {
        public var line: GoogleAppsLine
        /// Newest first; empty when the line has no build Avo can install.
        public var builds: [GoogleAppsBuild]
        /// GitHub has no repository for the line: MindTheGapps has no
        /// package for this Android (yet).
        public var missing: Bool
        /// When GitHub last answered.
        public var checked: Date
        var etag: String?

        public init(line: GoogleAppsLine, builds: [GoogleAppsBuild], missing: Bool = false, checked: Date, etag: String? = nil) {
            self.line = line
            self.builds = builds
            self.missing = missing
            self.checked = checked
            self.etag = etag
        }

        /// The one to install.
        public var recommended: GoogleAppsBuild? { builds.first }
        public var older: [GoogleAppsBuild] { Array(builds.dropFirst()) }
    }

    public struct Result: Equatable, Sendable {
        public var line: GoogleAppsLine
        /// GitHub's answer now, else the last one (nil when there never was one).
        public var listing: Listing?
        /// Why GitHub did not answer now.
        public var problem: Problem?

        public init(line: GoogleAppsLine, listing: Listing?, problem: Problem? = nil) {
            self.line = line
            self.listing = listing
            self.problem = problem
        }
    }

    public let transport: any HTTPTransport
    /// Where listings are kept (nil: nowhere).
    public let directory: URL?
    /// A listing younger than this is used without asking GitHub.
    public var maxAge: TimeInterval = 30 * 60

    public init(transport: any HTTPTransport = URLSessionTransport.shared, directory: URL? = AvoPaths().googleAppsReleases) {
        self.transport = transport
        self.directory = directory
    }

    /// The last listing of `line`, if any.
    public func cached(_ line: GoogleAppsLine) -> Listing? {
        guard let file = file(for: line), let data = try? Data(contentsOf: file),
              let listing = try? JSONDecoder.avoImages.decode(Listing.self, from: data), listing.line == line else { return nil }
        return listing
    }

    /// The builds of `line`: the kept listing while it is young (unless
    /// `force`), else GitHub's answer, else the kept listing with the reason.
    public func builds(for line: GoogleAppsLine, force: Bool = false, now: Date = Date()) async -> Result {
        let kept = cached(line)
        if !force, let kept, now.timeIntervalSince(kept.checked) >= 0, now.timeIntervalSince(kept.checked) < maxAge {
            return Result(line: line, listing: kept)
        }
        var request = URLRequest(url: line.listURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etag = kept?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            return Result(line: line, listing: kept, problem: .unreachable(error.localizedDescription))
        }
        switch response.statusCode {
        case 304:
            guard var kept else { return Result(line: line, listing: nil, problem: .unreadable) }
            kept.checked = now
            save(kept)
            return Result(line: line, listing: kept)
        case 200:
            guard let releases = try? GitHubRelease.parseList(data) else { return Result(line: line, listing: kept, problem: .unreadable) }
            let listing = Listing(line: line, builds: GoogleAppsBuild.builds(from: releases, line: line), checked: now,
                                  etag: response.value(forHTTPHeaderField: "ETag"))
            save(listing)
            return Result(line: line, listing: listing)
        case 404:
            let listing = Listing(line: line, builds: [], missing: true, checked: now)
            save(listing)
            return Result(line: line, listing: listing)
        default:
            return Result(line: line, listing: kept, problem: Self.problem(response, now: now))
        }
    }

    /// A refusal: GitHub's rate limit (403 or 429 with no requests left, or
    /// a `Retry-After`), else the status.
    static func problem(_ response: HTTPURLResponse, now: Date) -> Problem {
        let status = response.statusCode
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        guard status == 429 || (status == 403 && (remaining == 0 || retryAfter != nil)) else { return .status(status) }
        if let retryAfter { return .rateLimited(until: now.addingTimeInterval(retryAfter)) }
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        return .rateLimited(until: reset.map { Date(timeIntervalSince1970: $0) })
    }

    private func file(for line: GoogleAppsLine) -> URL? {
        directory?.appending(path: "\(line.repository).json")
    }

    private func save(_ listing: Listing) {
        guard let file = file(for: listing.line), let data = try? JSONEncoder.avoImages.encode(listing) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - The Google apps on Android's storage

/// `google-apps.json` beside Android's data disk: Google apps went into
/// Android's system partitions on this Android. Their overlay lives on the
/// data disk, so the record travels with Android's data
/// (`AvoPaths.portableDataItems`) and goes when the data is erased. Another
/// Android version does not mount that overlay (verified boot is on again
/// for it, `AndroidImageStore.prepareStart`), so its Google apps stop
/// working; a new install over them could not be undone, so Reset Android
/// comes first.
public struct GoogleAppsRecord: Codable, Equatable, Sendable {
    /// The Android they were installed on (nil when not known).
    public var android: AndroidRelease?
    public var date: Date

    public init(android: AndroidRelease?, date: Date = Date()) {
        self.android = android
        self.date = date
    }

    static func url(_ paths: AvoPaths) -> URL { paths.data.appending(path: "google-apps.json") }

    /// Nil without a data disk (erased, or never made).
    public static func load(_ paths: AvoPaths) -> GoogleAppsRecord? {
        guard FileManager.default.fileExists(atPath: paths.dataDisk.path) else { return nil }
        return (try? Data(contentsOf: url(paths))).flatMap { try? JSONDecoder.avoImages.decode(GoogleAppsRecord.self, from: $0) }
    }

    public func save(_ paths: AvoPaths) throws {
        try JSONEncoder.avoImages.encode(self).write(to: Self.url(paths), options: .atomic)
    }

    public static func remove(_ paths: AvoPaths) {
        try? FileManager.default.removeItem(at: url(paths))
    }
}

/// What Settings › Google Apps can offer, from what Avo knows about Android
/// and the Google apps on its storage.
public enum GoogleAppsSituation: Equatable, Sendable {
    /// There is no Android to install them on.
    case noAndroid
    /// Android runs and has not said yet whether it lists Google Play.
    case checking
    /// None installed: the package line of this Android fits.
    case canInstall(AndroidRelease)
    /// Installed on this Android (nil when not known).
    case installed(AndroidRelease?)
    /// Installed and working, but `next` starts at the next restart and
    /// they stop working then.
    case stopsWorkingAtRestart(installed: AndroidRelease?, next: AndroidRelease)
    /// None installed, and `next` starts at the next restart: install for
    /// it once it runs (the install restarts Android, which would switch
    /// versions halfway).
    case restartFirst(running: AndroidRelease, next: AndroidRelease)
    /// Google apps from another Android (or an older install) are on
    /// Android's storage but don't work on `android`: Reset Android first.
    case leftOver(installed: AndroidRelease?, android: AndroidRelease)

    /// The Android a new install is for.
    public var installTarget: AndroidRelease? {
        if case .canInstall(let release) = self { return release }
        return nil
    }

    /// - running: the Android running now (nil while it is stopped).
    /// - next: the Android it starts with next (the chosen image).
    /// - record: `GoogleAppsRecord`.
    /// - listed: Android lists Google Play (nil when not known).
    /// - modeInstalled: Settings › Google services says they are installed.
    public static func decide(running: AndroidRelease?, next: AndroidRelease?, record: GoogleAppsRecord?,
                              listed: Bool?, modeInstalled: Bool) -> GoogleAppsSituation {
        let switching = { (from: AndroidRelease) -> AndroidRelease? in
            guard let next, next.version != from.version else { return nil }
            return next
        }
        if let running {
            switch listed {
            case nil:
                return .checking
            case true?:
                if let next = switching(running) { return .stopsWorkingAtRestart(installed: record?.android ?? running, next: next) }
                return .installed(running)
            case false?:
                if record != nil || modeInstalled { return .leftOver(installed: record?.android, android: running) }
                if let next = switching(running) { return .restartFirst(running: running, next: next) }
                return .canInstall(running)
            }
        }
        guard let next else { return record != nil || modeInstalled ? .installed(record?.android) : .noAndroid }
        if let record {
            if let installed = record.android, installed.version != next.version { return .leftOver(installed: installed, android: next) }
            return .installed(record.android ?? next)
        }
        return modeInstalled ? .installed(nil) : .canInstall(next)
    }
}
