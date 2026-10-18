import AvoKit
import Foundation
import Testing
@testable import AvoPackages

/// `GET /repos/MindTheGapps/17.0.0-arm64/releases` as GitHub answered it in
/// October 2026 (bodies, authors and ids left out).
private func recordedReleases() throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: "Fixtures/GoogleApps/releases-17.0.0-arm64.json", withExtension: nil)))
}

private let seventeen = AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0", securityPatch: "2026-06-05")
private let sixteen = AndroidRelease(version: "16", sdk: 36, sdkFull: "36.1", securityPatch: "2026-03-05")

/// One release as the API lists it.
private func release(_ tag: String, published: String? = "2026-01-01T00:00:00Z", draft: Bool = false, prerelease: Bool = false,
                     assets: [(name: String, digest: String?)]) -> String {
    let list = assets.map { asset in
        #"{"name": "\#(asset.name)", "size": 1000, "digest": \#(asset.digest.map { "\"\($0)\"" } ?? "null"), "browser_download_url": "https://github.com/MindTheGapps/17.0.0-arm64/releases/download/\#(tag)/\#(asset.name)"}"#
    }
    return #"{"tag_name": "\#(tag)", "draft": \#(draft), "prerelease": \#(prerelease), "published_at": \#(published.map { "\"\($0)\"" } ?? "null"), "assets": [\#(list.joined(separator: ", "))]}"#
}

private let digest = "sha256:" + String(repeating: "ab", count: 32)

@Suite struct GoogleAppsLineTests {
    @Test func eachAndroidHasItsOwnLine() throws {
        let line16 = try #require(GoogleAppsLine(release: sixteen))
        let line17 = try #require(GoogleAppsLine(release: seventeen))
        #expect(line16.repository == "16.0.0-arm64")
        #expect(line17.repository == "17.0.0-arm64")
        #expect(line17.version == "17.0.0")
        #expect(line17.name == "MindTheGapps 17.0.0 (arm64)")
        #expect(line17.page.absoluteString == "https://github.com/MindTheGapps/17.0.0-arm64/releases")
        #expect(line17.listURL.absoluteString == "https://api.github.com/repos/MindTheGapps/17.0.0-arm64/releases?per_page=20")
        // A quarterly release (API 36.1) is still Android 16's line.
        #expect(GoogleAppsLine(release: AndroidRelease(version: "16", sdk: 36, sdkFull: "36.1")) == line16)
        #expect(GoogleAppsLine(release: AndroidRelease(version: "18", sdk: 38))?.repository == "18.0.0-arm64")
    }

    @Test func aCodenameHasNoLine() {
        #expect(GoogleAppsLine(release: AndroidRelease(version: "Baklava", sdk: 36)) == nil)
    }

    @Test func apiLevelsMapToTheirAndroid() {
        #expect(GoogleAppsLine(sdk: 37) == GoogleAppsLine(android: 17))
        #expect(GoogleAppsLine(sdk: 36) == GoogleAppsLine(android: 16))
        #expect(GoogleAppsLine(sdk: 33) == GoogleAppsLine(android: 13))
        #expect(GoogleAppsLine(sdk: 32) == nil)
    }

    @Test func aPackageForAnotherAndroidNamesTheOneThatFits() {
        let message = GoogleAppsError.wrongAndroidVersion(package: "Android 17.0.0 (SDK 37)", deviceSDK: 36).errorDescription ?? ""
        #expect(message.contains("MindTheGapps 16.0.0 (arm64)"))
        #expect(!message.contains("17.0.0 (arm64)"))
    }
}

@Suite struct GoogleAppsBuildListTests {
    let line = GoogleAppsLine(android: 17)

    @Test func readsMindTheGappsReleases() throws {
        let releases = try GitHubRelease.parseList(recordedReleases())
        #expect(releases.count == 4)
        #expect(releases[0].publishedAt == Date(timeIntervalSince1970: 1_791_285_182))
        #expect(!releases[0].draft && !releases[0].prerelease)

        let builds = GoogleAppsBuild.builds(from: releases, line: line)
        #expect(builds.map(\.tag) == [
            "MindTheGapps-17.0.0-arm64-20261006_111038", "MindTheGapps-17.0.0-arm64-20260915_222140",
            "MindTheGapps-17.0.0-arm64-20260828_065753", "MindTheGapps-17.0.0-arm64-20260630_115006",
        ])
        let newest = try #require(builds.first)
        #expect(newest.file == "MindTheGapps-17.0.0-arm64-20261006_111038.zip")
        #expect(newest.size == 544_284_432)
        #expect(newest.link == "https://github.com/MindTheGapps/17.0.0-arm64/releases/download/MindTheGapps-17.0.0-arm64-20261006_111038/MindTheGapps-17.0.0-arm64-20261006_111038.zip")
        // The link the daemon downloads names that release and that file.
        let api = try GitHubRelease.apiURL(for: newest.link)
        #expect(api.url.absoluteString == "https://api.github.com/repos/MindTheGapps/17.0.0-arm64/releases/tags/MindTheGapps-17.0.0-arm64-20261006_111038")
        #expect(api.asset == newest.file)
    }

    @Test func leavesOutWhatCannotBeInstalled() throws {
        let list = "[" + [
            release("draft", published: nil, draft: true, assets: [("a.zip", digest)]),
            release("pre", prerelease: true, assets: [("b.zip", digest)]),
            release("unchecked", assets: [("c.zip", nil)]),
            release("no-zip", assets: [("release.x509.pem", digest)]),
            release("sums", published: "2026-02-01T00:00:00Z", assets: [("d.zip", nil), ("d.zip.sha256sum", nil)]),
            release("two", published: "2026-03-01T00:00:00Z", assets: [("e-x86_64.zip", digest), ("e-arm64.zip", digest)]),
        ].joined(separator: ", ") + "]"
        let builds = GoogleAppsBuild.builds(from: try GitHubRelease.parseList(Data(list.utf8)), line: line)
        // Newest first; a .sha256sum is as good as GitHub's digest; the line's architecture of two.
        #expect(builds.map(\.tag) == ["two", "sums"])
        #expect(builds.first?.file == "e-arm64.zip")
    }

    @Test func aReleaseWithoutTheNewFieldsStillReads() throws {
        let release = try GitHubRelease.parse(Data(#"{"tag_name": "T1", "assets": []}"#.utf8))
        #expect(release.tagName == "T1")
        #expect(release.publishedAt == nil)
        #expect(!release.draft && !release.prerelease)
    }
}

/// GitHub's answers, one per request, and the requests.
private final class FakeGitHub: HTTPTransport, @unchecked Sendable {
    enum Answer {
        case http(Int, [String: String], Data)
        case offline
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = lock.withLock {
            requests.append(request)
            return answers.isEmpty ? Answer.offline : answers.removeFirst()
        }
        switch answer {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case let .http(status, headers, data):
            return (data, HTTPURLResponse(url: try #require(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
    }
}

@Suite struct GoogleAppsCatalogTests {
    let line = GoogleAppsLine(android: 17)
    let start = Date(timeIntervalSince1970: 1_792_000_000)

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "avo-gapps-releases-\(UUID().uuidString)")
    }

    @Test func listsAndKeepsTheBuilds() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let github = FakeGitHub([.http(200, ["ETag": "\"v1\""], try recordedReleases())])
        let catalog = GoogleAppsCatalog(transport: github, directory: folder)
        let result = await catalog.builds(for: line, now: start)
        #expect(result.problem == nil)
        #expect(result.listing?.builds.count == 4)
        #expect(result.listing?.recommended?.tag == "MindTheGapps-17.0.0-arm64-20261006_111038")
        #expect(result.listing?.older.count == 3)
        #expect(github.requests.first?.url == line.listURL)
        #expect(github.requests.first?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        // Kept: shown at once next time.
        #expect(catalog.cached(line)?.builds == result.listing?.builds)
        #expect(catalog.cached(GoogleAppsLine(android: 16)) == nil)
    }

    @Test func aYoungListingNeedsNoRequest() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let github = FakeGitHub([.http(200, [:], try recordedReleases())])
        let catalog = GoogleAppsCatalog(transport: github, directory: folder)
        _ = await catalog.builds(for: line, now: start)
        let again = await catalog.builds(for: line, now: start.addingTimeInterval(60))
        #expect(again.listing?.builds.count == 4)
        #expect(github.requests.count == 1)
    }

    @Test func anOldListingIsAskedForWithItsETag() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let github = FakeGitHub([.http(200, ["ETag": "\"v1\""], try recordedReleases()), .http(304, [:], Data())])
        let catalog = GoogleAppsCatalog(transport: github, directory: folder)
        _ = await catalog.builds(for: line, now: start)
        let later = start.addingTimeInterval(catalog.maxAge + 1)
        let result = await catalog.builds(for: line, now: later)
        #expect(github.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(result.problem == nil)
        #expect(result.listing?.builds.count == 4)
        #expect(result.listing?.checked == later)
    }

    @Test func offlineShowsTheLastListing() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let github = FakeGitHub([.http(200, [:], try recordedReleases()), .offline])
        let catalog = GoogleAppsCatalog(transport: github, directory: folder)
        _ = await catalog.builds(for: line, now: start)
        let result = await catalog.builds(for: line, force: true, now: start.addingTimeInterval(5))
        guard case .unreachable? = result.problem else {
            Issue.record("expected unreachable, got \(String(describing: result.problem))")
            return
        }
        #expect(result.listing?.builds.count == 4)
        #expect(result.listing?.checked == start)
    }

    @Test func offlineWithNothingKept() async {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = await GoogleAppsCatalog(transport: FakeGitHub([.offline]), directory: folder).builds(for: line, now: start)
        #expect(result.listing == nil)
        #expect(result.problem != nil)
    }

    @Test func rateLimitedShowsTheLastListingAndWhenToTryAgain() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let limited: [String: String] = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1792003600"]
        let github = FakeGitHub([.http(200, [:], try recordedReleases()), .http(403, limited, Data(#"{"message": "API rate limit exceeded"}"#.utf8))])
        let catalog = GoogleAppsCatalog(transport: github, directory: folder)
        _ = await catalog.builds(for: line, now: start)
        let result = await catalog.builds(for: line, force: true, now: start)
        #expect(result.problem == .rateLimited(until: Date(timeIntervalSince1970: 1_792_003_600)))
        #expect(result.listing?.builds.count == 4)
    }

    @Test func noRepositoryMeansNoPackageForThisAndroidYet() async {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let eighteen = GoogleAppsLine(android: 18)
        let catalog = GoogleAppsCatalog(transport: FakeGitHub([.http(404, [:], Data(#"{"message": "Not Found"}"#.utf8))]), directory: folder)
        let result = await catalog.builds(for: eighteen, now: start)
        #expect(result.problem == nil)
        #expect(result.listing?.missing == true)
        #expect(result.listing?.builds.isEmpty == true)
        // Also while offline later.
        #expect(catalog.cached(eighteen)?.missing == true)
    }

    @Test func refusalsAreTold() throws {
        func response(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: GoogleAppsLine(android: 17).listURL, statusCode: status, httpVersion: nil, headerFields: headers))
        }
        #expect(GoogleAppsCatalog.problem(try response(403, [:]), now: start) == .status(403))
        #expect(GoogleAppsCatalog.problem(try response(500, [:]), now: start) == .status(500))
        #expect(GoogleAppsCatalog.problem(try response(429, [:]), now: start) == .rateLimited(until: nil))
        #expect(GoogleAppsCatalog.problem(try response(403, ["Retry-After": "60"]), now: start) == .rateLimited(until: start.addingTimeInterval(60)))
        #expect(GoogleAppsCatalog.problem(try response(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1792000900"]), now: start)
            == .rateLimited(until: Date(timeIntervalSince1970: 1_792_000_900)))
    }
}

@Suite struct GoogleAppsSituationTests {
    @Test func installsForTheAndroidThatRuns() {
        #expect(GoogleAppsSituation.decide(running: sixteen, next: sixteen, record: nil, listed: false, modeInstalled: false) == .canInstall(sixteen))
        #expect(GoogleAppsSituation.decide(running: sixteen, next: sixteen, record: nil, listed: false, modeInstalled: false).installTarget == sixteen)
        // Stopped: for the one it starts with next.
        #expect(GoogleAppsSituation.decide(running: nil, next: seventeen, record: nil, listed: nil, modeInstalled: false) == .canInstall(seventeen))
        #expect(GoogleAppsSituation.decide(running: nil, next: nil, record: nil, listed: nil, modeInstalled: false) == .noAndroid)
        #expect(GoogleAppsSituation.decide(running: sixteen, next: sixteen, record: nil, listed: nil, modeInstalled: false) == .checking)
    }

    @Test func anotherVersionChosenWaitsForTheRestart() {
        #expect(GoogleAppsSituation.decide(running: sixteen, next: seventeen, record: nil, listed: false, modeInstalled: false)
            == .restartFirst(running: sixteen, next: seventeen))
        #expect(GoogleAppsSituation.decide(running: sixteen, next: seventeen, record: nil, listed: false, modeInstalled: false).installTarget == nil)
    }

    @Test func installedGoogleAppsFollowTheirAndroid() {
        let record = GoogleAppsRecord(android: sixteen)
        #expect(GoogleAppsSituation.decide(running: sixteen, next: sixteen, record: record, listed: true, modeInstalled: true) == .installed(sixteen))
        // Another build of the same version keeps them.
        let newerBuild = AndroidRelease(version: "16", sdk: 36, sdkFull: "36.1", securityPatch: "2026-09-05")
        #expect(GoogleAppsSituation.decide(running: newerBuild, next: newerBuild, record: record, listed: true, modeInstalled: true) == .installed(newerBuild))
        #expect(GoogleAppsSituation.decide(running: nil, next: newerBuild, record: record, listed: nil, modeInstalled: true) == .installed(sixteen))
        // Android 17 chosen: they stop working at the restart…
        #expect(GoogleAppsSituation.decide(running: sixteen, next: seventeen, record: record, listed: true, modeInstalled: false)
            == .stopsWorkingAtRestart(installed: sixteen, next: seventeen))
        // …and are left over after it, also while Android is stopped.
        #expect(GoogleAppsSituation.decide(running: seventeen, next: seventeen, record: record, listed: false, modeInstalled: false)
            == .leftOver(installed: sixteen, android: seventeen))
        #expect(GoogleAppsSituation.decide(running: nil, next: seventeen, record: record, listed: nil, modeInstalled: false)
            == .leftOver(installed: sixteen, android: seventeen))
    }

    @Test func backOnTheirVersionWithoutThemIsLeftOverToo() {
        // 16 → 17 → 16: verified boot came back on, so the overlay stays unused.
        #expect(GoogleAppsSituation.decide(running: sixteen, next: sixteen, record: GoogleAppsRecord(android: sixteen), listed: false, modeInstalled: false)
            == .leftOver(installed: sixteen, android: sixteen))
        #expect(GoogleAppsSituation.decide(running: sixteen, next: sixteen, record: nil, listed: false, modeInstalled: true)
            == .leftOver(installed: nil, android: sixteen))
    }
}

@Suite struct GoogleAppsRecordTests {
    @Test func belongsToAndroidsData() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "avo-gapps-record-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AvoPaths(home: home)
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
        try GoogleAppsRecord(android: sixteen, date: Date(timeIntervalSince1970: 1_790_000_000)).save(paths)
        // No data disk: nothing is installed, whatever the file says.
        #expect(GoogleAppsRecord.load(paths) == nil)
        try Data().write(to: paths.dataDisk)
        #expect(GoogleAppsRecord.load(paths) == GoogleAppsRecord(android: sixteen, date: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(AvoPaths.portableDataItems.contains("google-apps.json"))
        GoogleAppsRecord.remove(paths)
        #expect(GoogleAppsRecord.load(paths) == nil)
    }
}
