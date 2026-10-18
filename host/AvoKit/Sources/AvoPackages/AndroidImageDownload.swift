import AvoKit
import CryptoKit
import Foundation

// MARK: - Progress

/// How far a download is.
public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    public var total: Int64
    /// Over the last few seconds; nil until there is enough to tell.
    public var bytesPerSecond: Double?

    public init(received: Int64, total: Int64, bytesPerSecond: Double? = nil) {
        self.received = received
        self.total = total
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double { total > 0 ? min(max(Double(received) / Double(total), 0), 1) : 0 }

    public var secondsLeft: Double? {
        guard let bytesPerSecond, bytesPerSecond > 0, total > received else { return nil }
        return Double(total - received) / bytesPerSecond
    }
}

/// Bytes per second over a sliding window.
public struct TransferRate: Equatable, Sendable {
    public let window: Double
    private var samples: [(time: Double, bytes: Int64)] = []

    public init(window: Double = 5) {
        self.window = window
    }

    public static func == (a: TransferRate, b: TransferRate) -> Bool {
        a.window == b.window && a.samples.map(\.time) == b.samples.map(\.time) && a.samples.map(\.bytes) == b.samples.map(\.bytes)
    }

    /// `bytes` received in total by `time` (seconds, any monotonic clock).
    public mutating func add(bytes: Int64, at time: Double) {
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append((time, bytes))
        while let first = samples.first, time - first.time > window, samples.count > 2 { samples.removeFirst() }
    }

    /// Nil until the samples span a second.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 1 else { return nil }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }

    public mutating func reset() { samples.removeAll() }
}

// MARK: - The job

/// One download or import of an Android image, as the Control Panel shows it.
/// `apply(_:)` is the state machine: events that make no sense in the current
/// phase (a progress report that arrives after Pause) change nothing.
public struct AndroidImageJob: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case download(AndroidImageOffer)
        /// A file or folder on this Mac, by its name.
        case importing(String)
    }

    public enum Phase: Equatable, Sendable {
        /// Asking for the download link, reading the zip's directory, checking disk space.
        case preparing
        case downloading(DownloadProgress)
        /// Stopped by the user; what arrived stays for Resume.
        case paused(DownloadProgress?)
        /// Comparing the download with the API's MD5.
        case verifying(Double)
        /// Unzipping or copying the files, and taking their SHA-256.
        case unpacking(Double)
        /// Writing the manifest and moving the image into place.
        case finishing
        case finished(path: String)
        /// `resumable`: a download that can continue from what arrived.
        case failed(message: String, resumable: Bool)
        case cancelled
    }

    public enum Event: Equatable, Sendable {
        case preparing
        case progress(DownloadProgress)
        case pause
        case resume
        case verifying(Double)
        case unpacking(Double)
        case finishing
        case finished(path: String)
        case failed(message: String, resumable: Bool)
        case cancel
    }

    public let id: UUID
    public let kind: Kind
    public private(set) var phase: Phase

    public init(id: UUID = UUID(), kind: Kind, phase: Phase = .preparing) {
        self.id = id
        self.kind = kind
        self.phase = phase
    }

    /// Applies `event`; false (and no change) when it does not fit the phase.
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        guard let next = Self.next(phase, event) else { return false }
        phase = next
        return true
    }

    static func next(_ phase: Phase, _ event: Event) -> Phase? {
        switch (phase, event) {
        case (.preparing, .preparing): return .preparing
        case (.preparing, .progress(let progress)), (.downloading, .progress(let progress)): return .downloading(progress)
        case (.preparing, .pause): return .paused(nil)
        case (.downloading(let progress), .pause): return .paused(progress)
        case (.paused, .resume): return .preparing
        case (.failed(_, true), .resume): return .preparing
        case (.preparing, .verifying(let fraction)), (.downloading, .verifying(let fraction)), (.verifying, .verifying(let fraction)):
            return .verifying(fraction)
        case (.preparing, .unpacking(let fraction)), (.verifying, .unpacking(let fraction)), (.unpacking, .unpacking(let fraction)):
            return .unpacking(fraction)
        case (.unpacking, .finishing), (.verifying, .finishing): return .finishing
        case (.finishing, .finished(let path)), (.unpacking, .finished(let path)), (.preparing, .finished(let path)):
            return .finished(path: path)
        case (.preparing, .failed(let message, let resumable)), (.downloading, .failed(let message, let resumable)),
             (.verifying, .failed(let message, let resumable)), (.unpacking, .failed(let message, let resumable)),
             (.finishing, .failed(let message, let resumable)):
            return .failed(message: message, resumable: resumable)
        case (.preparing, .cancel), (.downloading, .cancel), (.paused, .cancel), (.verifying, .cancel), (.unpacking, .cancel),
             (.failed, .cancel):
            return .cancelled
        default:
            return nil
        }
    }

    /// Doing something now (not paused, failed or done).
    public var isRunning: Bool {
        switch phase {
        case .preparing, .downloading, .verifying, .unpacking, .finishing: true
        default: false
        }
    }

    public var isDone: Bool {
        switch phase {
        case .finished, .cancelled: true
        default: false
        }
    }

    public var canPause: Bool {
        guard case .download = kind else { return false }
        switch phase {
        case .preparing, .downloading: return true
        default: return false
        }
    }

    public var canResume: Bool {
        switch phase {
        case .paused, .failed(_, true): true
        default: false
        }
    }

    /// Cancel: until the files are being moved into place.
    public var canCancel: Bool {
        switch phase {
        case .preparing, .downloading, .paused, .verifying, .unpacking, .failed: true
        default: false
        }
    }

    public var offer: AndroidImageOffer? {
        if case .download(let offer) = kind { return offer }
        return nil
    }
}

// MARK: - Downloading

/// Streams a URL into a file and continues a partial file where it stopped:
/// `Range: bytes=<size>-` with `If-Range: <ETag>`, so a file that changed on
/// the server starts over (a 200 answer). Cancelling the calling task stops
/// the transfer and keeps what arrived (Pause).
public final class RangeDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// What the server said about the file.
    public struct Result: Sendable, Equatable {
        public var size: Int64
        public var entityTag: String?
    }

    public enum Failure: Error, Equatable {
        /// 403 from a signed link that expired: ask for a new one.
        case expired
        case status(Int)
    }

    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var state: Transfer?

    private struct Transfer {
        var handle: FileHandle
        var offset: Int64
        var received: Int64
        var total: Int64
        var entityTag: String?
        var continuation: CheckedContinuation<Result, any Error>?
        var progress: @Sendable (Int64, Int64) -> Void
        var onResponse: @Sendable (String?) -> Void
        var failure: (any Error)?
    }

    public init(configuration: URLSessionConfiguration = RangeDownloader.defaultConfiguration) {
        self.configuration = configuration
    }

    public static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.httpAdditionalHeaders = ["User-Agent": "Avo"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    /// Downloads `url` into `file`, continuing it when it already has bytes.
    /// `entityTag` is the ETag of those bytes (from the last attempt);
    /// `onResponse` gets the server's, as soon as it answers. `progress`
    /// gets bytes in the file and the full size.
    public func download(_ url: URL, to file: URL, entityTag: String?,
                         onResponse: @escaping @Sendable (String?) -> Void = { _ in },
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Result {
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw AndroidImageError.io(String(localized: "Can’t create \(file.lastPathComponent).", bundle: .avoKit))
            }
        }
        let handle = try FileHandle(forUpdating: file)
        let offset = Int64(try handle.seekToEnd())
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let entityTag { request.setValue(entityTag, forHTTPHeaderField: "If-Range") }
        }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    state = Transfer(handle: handle, offset: offset, received: offset, total: 0, entityTag: entityTag,
                                     continuation: continuation, progress: progress, onResponse: onResponse)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(AndroidImageError.network("no HTTP response"))
            completionHandler(.cancel)
            return
        }
        let tag = http.value(forHTTPHeaderField: "ETag")
        let allowed: Bool = lock.withLock {
            guard var transfer = state else { return false }
            switch http.statusCode {
            case 206:
                // `bytes <start>-<end>/<total>` must continue where the file ends.
                guard let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")), range.start == transfer.offset else {
                    transfer.failure = AndroidImageError.api(status: 206, message: "unexpected Content-Range")
                    state = transfer
                    return false
                }
                transfer.total = range.total
            case 200:
                // Everything from the start: the server ignored the range, or the file changed.
                do {
                    try transfer.handle.truncate(atOffset: 0)
                } catch {
                    transfer.failure = AndroidImageError.io(error.localizedDescription)
                    state = transfer
                    return false
                }
                transfer.offset = 0
                transfer.received = 0
                transfer.total = http.expectedContentLength > 0 ? http.expectedContentLength : 0
            case 403:
                transfer.failure = Failure.expired
                state = transfer
                return false
            default:
                transfer.failure = Failure.status(http.statusCode)
                state = transfer
                return false
            }
            transfer.entityTag = tag ?? transfer.entityTag
            state = transfer
            return true
        }
        if allowed, let (onResponse, progress, received, total) = lock.withLock({
            state.map { ($0.onResponse, $0.progress, $0.received, $0.total) }
        }) {
            onResponse(tag)
            progress(received, total)
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: (@Sendable (Int64, Int64) -> Void, Int64, Int64)? = lock.withLock {
            guard var transfer = state, transfer.failure == nil else { return nil }
            do {
                try transfer.handle.write(contentsOf: data)
            } catch {
                transfer.failure = AndroidImageError.io(error.localizedDescription)
                state = transfer
                return nil
            }
            transfer.received += Int64(data.count)
            state = transfer
            return (transfer.progress, transfer.received, max(transfer.total, transfer.received))
        }
        guard let (progress, received, total) = report else {
            dataTask.cancel()
            return
        }
        progress(received, total)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (transfer, continuation) = lock.withLock { () -> (Transfer?, CheckedContinuation<Result, any Error>?) in
            let transfer = state
            state = nil
            return (transfer, transfer?.continuation)
        }
        guard let transfer, let continuation else { return }
        try? transfer.handle.synchronize()
        try? transfer.handle.close()
        if let failure = transfer.failure {
            continuation.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: AndroidImageError.network(error.localizedDescription))
            }
        } else if transfer.total > 0, transfer.received != transfer.total {
            continuation.resume(throwing: AndroidImageError.network(String(localized: "The download ended early.", bundle: .avoKit)))
        } else {
            continuation.resume(returning: Result(size: transfer.received, entityTag: transfer.entityTag))
        }
    }

    private func fail(_ error: any Error) {
        lock.withLock {
            guard var transfer = state else { return }
            transfer.failure = error
            state = transfer
        }
    }

    /// `bytes 100-199/1000` → (100, 1000).
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]), let start = parts[0].split(separator: "-").first.flatMap({ Int64($0) })
        else { return nil }
        return (start, total)
    }
}

extension Checksum {
    /// MD5 of a file as lowercase hex (what the Android Build API lists),
    /// with `progress` from 0 to 1.
    public static func md5(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = max(Double((try? handle.seekToEnd()) ?? 0), 1)
        try handle.seek(toOffset: 0)
        var hasher = Insecure.MD5()
        var done = 0.0
        var lastReport = 0.0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            done += Double(chunk.count)
            if done / size - lastReport >= 0.01 {
                lastReport = done / size
                progress?(lastReport)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
