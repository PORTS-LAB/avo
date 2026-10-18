import AVFoundation
import AvoKit
import CoreMedia
import os

/// Android's sound in a screen recording: an AAC track (48 kHz stereo) of
/// what the engine played, from its ring in shared memory (CaptureAudio.swift
/// in AvoKit). Each block goes at the host time the Mac played it, on the
/// same clock as the frames, so sound and picture stay together; silence
/// fills the track while nothing plays, so a recording of a silent app has
/// a silent track. All of Android's sound is in it, not only this app's:
/// Android mixes its apps into one output.
///
/// Runs on the recorder's queue: it reads the ring every 40 ms once the
/// movie has its first frame (`start`), and `finish` adds the last of it.
final class RecordingAudio: @unchecked Sendable {
    let input: AVAssetWriterInput
    private let reader: AudioTapReader
    private let format: CMAudioFormatDescription
    private let queue: DispatchQueue
    /// The writer refused the sound (on the queue).
    var onFailure: ((any Error)?) -> Void = { _ in }
    private var timeline = AudioTimeline()
    /// Where the track's first frame is: the movie's start (host clock).
    private var origin: CMTime?
    /// The movie's end, once the recording stops: the track goes no further.
    private var end: CMTime?
    /// Sound the writer could not take yet, in order.
    private var pending: [CMSampleBuffer] = []
    private var timer: (any DispatchSourceTimer)?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Recording")

    /// How long after it played the engine's sound is surely in the ring:
    /// the track is padded with silence up to this long before now, and
    /// finishing waits this long for the last of it.
    static let lag: TimeInterval = 0.25
    private static let interval: DispatchTimeInterval = .milliseconds(40)
    /// At most this much sound waits for the writer; older is dropped.
    private static let maxPending = 250

    /// Nil when the ring cannot be read (an engine without it, or one that is gone).
    init?(location: AudioTapLocation, queue: DispatchQueue) {
        guard let reader = AudioTapReader(location: location) else { return nil }
        var description = AudioStreamBasicDescription(mSampleRate: Double(AudioTimeline.rate), mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                      mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                             layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioTimeline.rate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        self.reader = reader
        self.format = format
        self.queue = queue
    }

    /// The movie has its first frame at `origin`: the track starts there,
    /// with the sound played since then (on the queue).
    func start(at origin: CMTime) {
        guard self.origin == nil else { return }
        self.origin = origin
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick(final: false) }
        timer.resume()
        self.timer = timer
    }

    /// The recording stops: the movie ends at `end` (on the queue).
    func ends(at end: CMTime) {
        self.end = end
    }

    /// Adds the last of the sound, up to the movie's end (on the queue,
    /// `lag` after `ends`). The recorder then closes the track.
    func finish() {
        stop()
        guard origin != nil else { return }
        tick(final: true)
        // The writer takes what is left before the track closes.
        for _ in 0..<100 where !pending.isEmpty {
            flush()
            if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        }
        if !pending.isEmpty { logger.error("recording: \(self.pending.count) pieces of sound did not fit in the movie") }
    }

    /// Stops reading (the recording ends without its sound, or with what it has).
    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Writes what the engine played since the last tick, and silence up to
    /// shortly before now; the last time (`final`) up to the movie's end.
    private func tick(final: Bool) {
        guard let origin else { return }
        let start = timeline.written
        var samples: [Int16] = []
        let (blocks, lost) = reader.read()
        if lost { logger.notice("recording: some of Android's sound was lost before it was read") }
        for block in blocks {
            let pcm = AudioPCM.stereo48k(block.samples, channels: block.channels, rate: block.rate)
            let position = Self.position(CMClockMakeHostTimeFromSystemUnits(block.hostTime), from: origin)
            let placement = timeline.place(position: position, frames: pcm.count / 2, runStart: block.runStart)
            samples.append(contentsOf: repeatElement(0, count: placement.silence * 2))
            samples.append(contentsOf: pcm[(placement.skip * 2)..<((placement.skip + placement.count) * 2)])
        }
        let shortlyBefore = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(seconds: Self.lag, preferredTimescale: 1000)
        let horizon = final ? (end ?? shortlyBefore) : CMTimeMinimum(shortlyBefore, end ?? shortlyBefore)
        let limit = Self.position(horizon, from: origin)
        samples.append(contentsOf: repeatElement(0, count: timeline.pad(to: limit) * 2))
        // Nothing after the movie's end.
        if end != nil, timeline.written > limit {
            samples.removeLast(min(samples.count, Int(timeline.written - max(limit, start)) * 2))
        }
        if !samples.isEmpty, let buffer = makeBuffer(samples, at: start, origin: origin) { pending.append(buffer) }
        if pending.count > Self.maxPending {
            logger.error("recording: the movie's writer fell behind; dropping some of Android's sound")
            pending.removeFirst(pending.count - Self.maxPending)
        }
        flush()
    }

    /// Frames at 48 kHz from `origin` to `time`.
    private static func position(_ time: CMTime, from origin: CMTime) -> Int64 {
        Int64((CMTimeGetSeconds(CMTimeSubtract(time, origin)) * Double(AudioTimeline.rate)).rounded())
    }

    private func flush() {
        while let buffer = pending.first, input.isReadyForMoreMediaData {
            guard input.append(buffer) else {
                pending.removeAll()
                stop()
                onFailure(nil)
                return
            }
            pending.removeFirst()
        }
    }

    /// Interleaved stereo frames that start `position` frames into the track.
    private func makeBuffer(_ samples: [Int16], at position: Int64, origin: CMTime) -> CMSampleBuffer? {
        let bytes = samples.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                      offsetIntoDestination: 0, dataLength: bytes) }) == noErr
        else { return nil }
        var buffer: CMSampleBuffer?
        let time = CMTimeAdd(origin, CMTime(value: position, timescale: CMTimeScale(AudioTimeline.rate)))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                   sampleCount: samples.count / 2, presentationTimeStamp: time,
                                                                   packetDescriptions: nil, sampleBufferOut: &buffer) == noErr
        else { return nil }
        return buffer
    }
}
