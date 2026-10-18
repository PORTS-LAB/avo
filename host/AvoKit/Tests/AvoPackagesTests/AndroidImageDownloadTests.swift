import AvoKit
import Foundation
import Testing
@testable import AvoPackages

@Suite struct AndroidImageJobTests {
    let offer = AndroidImageOffer(build: "16373615", branch: "b", target: "t", release: AndroidRelease(version: "17", sdk: 37), date: nil,
                                  artifact: "a.zip", downloadSize: 100, md5: "m")

    /// Applies the events in order; what each one said (taken or ignored).
    func apply(_ job: inout AndroidImageJob, _ events: AndroidImageJob.Event...) -> [Bool] {
        events.map { job.apply($0) }
    }

    @Test func aDownloadGoesThroughItsPhases() {
        var job = AndroidImageJob(kind: .download(offer))
        #expect(job.phase == .preparing)
        #expect(job.isRunning && job.canPause && job.canCancel && !job.canResume)
        let half = DownloadProgress(received: 50, total: 100, bytesPerSecond: 10)
        var taken = apply(&job, .progress(half))
        #expect(taken == [true])
        #expect(job.phase == .downloading(half))
        taken = apply(&job, .verifying(0.5))
        #expect(taken == [true])
        #expect(!job.canPause)
        taken = apply(&job, .unpacking(0.2), .unpacking(0.9), .finishing)
        #expect(taken == [true, true, true])
        #expect(!job.canCancel)
        taken = apply(&job, .finished(path: "/images/android-17"))
        #expect(taken == [true])
        #expect(job.isDone && !job.isRunning)
        // Done is done.
        taken = apply(&job, .cancel, .progress(half), .resume)
        #expect(taken == [false, false, false])
        #expect(job.phase == .finished(path: "/images/android-17"))
    }

    @Test func pauseKeepsProgressAndIgnoresLateReports() {
        var job = AndroidImageJob(kind: .download(offer))
        let some = DownloadProgress(received: 30, total: 100)
        var taken = apply(&job, .progress(some), .pause)
        #expect(taken == [true, true])
        #expect(job.phase == .paused(some))
        #expect(!job.isRunning && job.canResume && job.canCancel && !job.canPause)
        // Reports that were on their way when Pause came.
        taken = apply(&job, .progress(DownloadProgress(received: 40, total: 100)), .failed(message: "cancelled", resumable: true), .verifying(0))
        #expect(taken == [false, false, false])
        #expect(job.phase == .paused(some))
        taken = apply(&job, .resume)
        #expect(taken == [true])
        #expect(job.phase == .preparing)
        taken = apply(&job, .progress(DownloadProgress(received: 60, total: 100)))
        #expect(taken == [true])
        // Paused before any byte arrived.
        var early = AndroidImageJob(kind: .download(offer))
        taken = apply(&early, .pause)
        #expect(taken == [true])
        #expect(early.phase == .paused(nil))
    }

    @Test func aFailedDownloadCanResumeOrBeCancelled() {
        var job = AndroidImageJob(kind: .download(offer))
        var taken = apply(&job, .progress(DownloadProgress(received: 10, total: 100)), .failed(message: "offline", resumable: true))
        #expect(taken == [true, true])
        #expect(job.canResume && job.canCancel && !job.isRunning)
        taken = apply(&job, .resume, .failed(message: "damaged", resumable: false))
        #expect(taken == [true, true])
        #expect(!job.canResume)
        taken = apply(&job, .resume, .cancel, .resume)
        #expect(taken == [false, true, false])
        #expect(job.phase == .cancelled)
        #expect(job.isDone)
    }

    @Test func importsCannotPause() {
        var job = AndroidImageJob(kind: .importing("img"))
        #expect(!job.canPause)
        let taken = apply(&job, .unpacking(0.5), .pause, .cancel)
        #expect(taken == [true, false, true])
        #expect(job.offer == nil)
    }

    @Test func outOfOrderEventsChangeNothing() {
        var job = AndroidImageJob(kind: .download(offer))
        var taken = apply(&job, .resume, .finishing)
        #expect(taken == [false, false])
        #expect(job.phase == .preparing)
        var other = AndroidImageJob(kind: .download(offer))
        taken = apply(&other, .unpacking(0.1), .progress(DownloadProgress(received: 1, total: 2)), .verifying(0.3), .pause)
        #expect(taken == [true, false, false, false])
        #expect(other.phase == .unpacking(0.1))
        #expect(other.offer == offer)
    }
}

@Suite struct TransferRateTests {
    @Test func measuresOverTheWindow() throws {
        var rate = TransferRate(window: 5)
        rate.add(bytes: 0, at: 0)
        #expect(rate.bytesPerSecond == nil)
        rate.add(bytes: 500, at: 0.5)
        #expect(rate.bytesPerSecond == nil)
        rate.add(bytes: 2000, at: 2)
        #expect(try #require(rate.bytesPerSecond) == 1000)
        // Old samples leave the window: the rate follows the last seconds.
        rate.add(bytes: 2000, at: 7)
        rate.add(bytes: 2000, at: 9)
        #expect(try #require(rate.bytesPerSecond) == 0)
        // Starting over (a download restarted from zero).
        rate.add(bytes: 10, at: 10)
        #expect(rate.bytesPerSecond == nil)
    }

    @Test func progressKnowsTheTimeLeft() {
        let progress = DownloadProgress(received: 250, total: 1000, bytesPerSecond: 50)
        #expect(progress.fraction == 0.25)
        #expect(progress.secondsLeft == 15)
        #expect(DownloadProgress(received: 1000, total: 1000, bytesPerSecond: 50).secondsLeft == nil)
        #expect(DownloadProgress(received: 0, total: 0).fraction == 0)
    }
}

@Suite struct RangeDownloaderTests {
    let payload = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    func downloader() -> RangeDownloader { RangeDownloader(configuration: RangeFileServer.configuration) }

    @Test func downloadsAWholeFile() async throws {
        let folder = try scratchFolder("download")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = RangeFileServer.serve(.init(data: payload, entityTag: "\"v1\""))
        let file = folder.appending(path: "image.zip.partial")
        let tags = EventTags()
        let result = try await downloader().download(url, to: file, entityTag: nil, onResponse: { tags.add($0) }) { _, _ in }
        #expect(result == RangeDownloader.Result(size: Int64(payload.count), entityTag: "\"v1\""))
        #expect(try Data(contentsOf: file) == payload)
        #expect(tags.all == ["\"v1\""])
        #expect(RangeFileServer.requests(for: url).first?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test func continuesWhereThePartialFileEnds() async throws {
        let folder = try scratchFolder("download")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = RangeFileServer.serve(.init(data: payload, entityTag: "\"v1\""))
        let file = folder.appending(path: "image.zip.partial")
        try payload.prefix(200_000).write(to: file)
        let seen = Counter()
        let result = try await downloader().download(url, to: file, entityTag: "\"v1\"") { received, total in
            seen.add()
            #expect(received >= 200_000 && total == 600_000)
        }
        #expect(result.size == 600_000)
        #expect(try Data(contentsOf: file) == payload)
        let request = try #require(RangeFileServer.requests(for: url).last)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=200000-")
        #expect(request.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
        #expect(seen.value > 1)
    }

    @Test func startsOverWhenTheFileChanged() async throws {
        let folder = try scratchFolder("download")
        defer { try? FileManager.default.removeItem(at: folder) }
        // The server's file is now "v2": If-Range fails, everything comes again.
        let url = RangeFileServer.serve(.init(data: payload, entityTag: "\"v2\""))
        let file = folder.appending(path: "image.zip.partial")
        try Data(repeating: 0xEE, count: 100_000).write(to: file)
        let result = try await downloader().download(url, to: file, entityTag: "\"v1\"") { _, _ in }
        #expect(result.entityTag == "\"v2\"")
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test func startsOverWhenTheServerIgnoresRanges() async throws {
        let folder = try scratchFolder("download")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = RangeFileServer.serve(.init(data: payload, entityTag: "\"v1\"", ignoresRange: true))
        let file = folder.appending(path: "image.zip.partial")
        try payload.prefix(1000).write(to: file)
        _ = try await downloader().download(url, to: file, entityTag: "\"v1\"") { _, _ in }
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test func anExpiredLinkSaysSo() async throws {
        let folder = try scratchFolder("download")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = RangeFileServer.serve(.init(data: payload, entityTag: "\"v1\"", expiredAnswers: 1))
        let file = folder.appending(path: "image.zip.partial")
        await #expect(throws: RangeDownloader.Failure.expired) {
            try await downloader().download(url, to: file, entityTag: nil) { _, _ in }
        }
        // The next request (a new link) works.
        _ = try await downloader().download(url, to: file, entityTag: nil) { _, _ in }
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test func cancellingKeepsWhatArrived() async throws {
        let folder = try scratchFolder("download")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = RangeFileServer.serve(.init(data: payload, entityTag: "\"v1\"", chunkDelay: 0.02, chunkSize: 20_000))
        let file = folder.appending(path: "image.zip.partial")
        let halfway = CancelFlag()
        let task = Task {
            try await downloader().download(url, to: file, entityTag: nil) { received, _ in
                if received >= 100_000 { halfway.set() }
            }
        }
        while !halfway.isSet { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let kept = try Data(contentsOf: file)
        #expect(kept.count >= 100_000 && kept.count < payload.count)
        #expect(kept == payload.prefix(kept.count))
        // Resume.
        _ = try await downloader().download(url, to: file, entityTag: "\"v1\"") { _, _ in }
        #expect(try Data(contentsOf: file) == payload)
        #expect(RangeFileServer.requests(for: url).last?.value(forHTTPHeaderField: "Range") == "bytes=\(kept.count)-")
    }

    @Test func aRangeReadStopsAtItsLimitWhenTheServerIgnoresRanges() async throws {
        let url = RangeFileServer.serve(.init(data: payload, entityTag: "\"v1\"", ignoresRange: true))
        let transport = URLSessionTransport(session: URLSession(configuration: RangeFileServer.configuration))
        var request = URLRequest(url: url)
        request.setValue("bytes=0-999", forHTTPHeaderField: "Range")
        let (data, response) = try await transport.data(for: request, limit: 1000)
        #expect(response.statusCode == 200)
        #expect(data == payload.prefix(1000))
        // The client keeps the start of the file for a range from 0, and refuses a 200 for any other range.
        let client = AndroidBuildClient(source: .standard, transport: transport)
        #expect(try await client.range(url, 0...499) == payload.prefix(500))
        await #expect(throws: AndroidImageError.self) { try await client.range(url, 1000...1999) }
        // A server that honours ranges.
        let ranged = RangeFileServer.serve(.init(data: payload, entityTag: "\"v1\""))
        #expect(try await client.range(ranged, 1000...1999) == payload.subdata(in: 1000..<600_000).prefix(1000))
    }

    @Test func readsContentRange() {
        #expect(RangeDownloader.contentRange("bytes 100-199/1000")! == (100, 1000))
        #expect(RangeDownloader.contentRange("bytes */1000") == nil)
        #expect(RangeDownloader.contentRange(nil) == nil)
    }

    @Test func md5OfAFile() throws {
        let folder = try scratchFolder("md5")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "f")
        try payload.write(to: file)
        let fractions = FractionLog()
        #expect(try Checksum.md5(of: file) { fractions.add($0) } == md5Hex(payload))
        #expect((fractions.all.last ?? 0) > 0.98)
    }
}

final class EventTags: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [String?] = []
    func add(_ tag: String?) { lock.withLock { tags.append(tag) } }
    var all: [String?] { lock.withLock { tags } }
}

final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}
