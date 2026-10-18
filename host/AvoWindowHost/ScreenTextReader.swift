import AppKit
import AvoKit
import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage
import Vision

/// Reads the text in one frame for Translate Screen: Vision finds the lines
/// (in any script it knows, telling the language by itself),
/// ScreenTextLayout groups them into blocks, and each block gets the colors
/// around and under it and the language it is written in. It all runs off
/// the main thread, one frame at a time.
enum ScreenTextReader {
    struct Block: Sendable {
        var text: String
        /// Frame pixels, origin at the top left.
        var rect: CGRect
        var lineHeight: Double
        var alignment: ScreenTextLayout.Alignment
        /// How far a longer translation may widen it to the right, in frame pixels.
        var room: Double
        var background: ScreenTextLayout.RGB
        var foreground: ScreenTextLayout.RGB
        /// NaturalLanguage code of the language it is in ("ja", "zh-Hant"); nil when unknown.
        var language: String?
    }

    struct Reading: Sendable {
        var frameSize: CGSize
        var blocks: [Block]
    }

    private static let queue = DispatchQueue(label: "dev.avo.screen-text", qos: .userInitiated)
    /// Samples have a queue of their own: they never wait for a read.
    private static let sampleQueue = DispatchQueue(label: "dev.avo.screen-sample", qos: .userInitiated)

    /// Reads `image`. `languages` (NaturalLanguage codes) are the ones a
    /// block may be in: those that can be translated.
    static func read(_ image: CGImage, languages: [String]) async -> Reading {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: readNow(image, languages: languages))
            }
        }
    }

    /// Vision loads its text models on the first read (the first time on
    /// this Mac, it builds them: most of a minute). Done once in the
    /// background as the app's window opens, Translate Screen then starts at
    /// once instead of "Preparing text recognition".
    static func warmUp() {
        queue.async(qos: .utility) {
            _ = sharedModels
            guard let image = warmUpImage() else { return }
            _ = lines(in: image)
        }
    }

    /// A little dark text on white, for the warm-up read.
    private static func warmUpImage() -> CGImage? {
        let width = 360, height = 72
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: "Avo 123 Play", attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        context.textPosition = CGPoint(x: 14, y: 22)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }

    /// `image` as a ScreenSample, to tell where a later frame differs (a
    /// millisecond or two for a phone's frame).
    static func sample(of image: CGImage) async -> ScreenSample {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                continuation.resume(returning: sampleNow(image))
            }
        }
    }

    private static func readNow(_ image: CGImage, languages: [String]) -> Reading {
        _ = sharedModels
        let blocks = ScreenTextLayout.blocks(lines(in: image))
        let texts = blocks.map(\.text)
        let languages = languagesOf(texts, among: languages)
        let read = blocks.indices.map { index in
            let block = blocks[index]
            let colors = colors(in: image, around: block.rect, lineHeight: block.lineHeight)
            return Block(text: texts[index], rect: block.rect, lineHeight: block.lineHeight, alignment: block.alignment,
                         room: ScreenTextLayout.room(after: index, in: blocks, frameWidth: Double(image.width)),
                         background: colors.background, foreground: colors.text, language: languages[index])
        }
        return Reading(frameSize: CGSize(width: image.width, height: image.height), blocks: read)
    }

    // MARK: Vision's models

    /// Vision builds its text recognition models for each app the first time
    /// it reads text there, which takes most of a minute, and keeps them in
    /// ~/Library/Caches/<the app's bundle identifier>/com.apple.e5rt.e5bundlecache.
    /// Every App Shim is an app of its own, so each one waited that long on
    /// its first Translate Screen. They share one cache instead, in the
    /// Window Host's caches: the first app builds the models once for all.
    /// An app that built its own before keeps them (the first such app's
    /// become the shared ones). Done once, before the first read.
    private static let sharedModels: Void = {
        let files = FileManager.default
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        guard !owner.isEmpty, owner != AvoIdentifiers.windowHost else { return }
        let name = "com.apple.e5rt.e5bundlecache"
        let own = caches.appending(path: owner, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
        let shared = caches.appending(path: AvoIdentifiers.windowHost, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        // Already shared.
        if (try? files.destinationOfSymbolicLink(atPath: own.path)) != nil { return }
        do {
            try files.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: own.path) {
                guard !files.fileExists(atPath: shared.path) else { return }
                try files.moveItem(at: own, to: shared)
            } else if !files.fileExists(atPath: shared.path) {
                try files.createDirectory(at: shared, withIntermediateDirectories: true)
            }
            try files.createSymbolicLink(at: own, withDestinationURL: shared)
        } catch {
            // Vision then builds the models for this app, as before.
        }
    }()

    // MARK: Text

    private static func lines(in image: CGImage) -> [ScreenTextLayout.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Vision skips text under 1/32 of the image's height by default:
        // most of an app's text on a tall phone display. 12 pixels is 6 points on Retina.
        request.minimumTextHeight = Float(min(1, 12 / Double(max(image.height, 1))))
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            // Vision's lowest confidence is mostly texture read as letters.
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
                  ScreenTextLayout.hasLetters(candidate.string) else { return nil }
            // Vision's boxes are normalized with the origin at the bottom left.
            let box = observation.boundingBox
            return ScreenTextLayout.Line(text: candidate.string,
                                         rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                                      width: box.width * width, height: box.height * height))
        }
    }

    /// The language of each text: its own when it says enough to tell, the
    /// screen's otherwise ("OK" and "設定" alone could be many languages).
    private static func languagesOf(_ texts: [String], among codes: [String]) -> [String?] {
        let constraints = codes.map(NLLanguage.init(rawValue:))
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(texts.joined(separator: "\n"))
        let dominant = recognizer.dominantLanguage
        return texts.map { text in
            guard text.count(where: \.isLetter) >= 4 else { return dominant?.rawValue }
            recognizer.reset()
            recognizer.languageConstraints = constraints
            if let dominant { recognizer.languageHints = [dominant: 0.6] }
            recognizer.processString(text)
            guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
                  probability >= 0.5 else { return dominant?.rawValue }
            return language.rawValue
        }
    }

    // MARK: Pixels

    /// The frame scaled down to ScreenSample's grid, each cell the average
    /// of the pixels it covers, so a changed word still changes a cell or two.
    private static func sampleNow(_ image: CGImage) -> ScreenSample {
        let (columns, rows) = ScreenSample.grid(width: image.width, height: image.height)
        var cells = [UInt8](repeating: 0, count: columns * rows)
        cells.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Medium is Core Graphics' box filter: each cell the true average
            // (high resamples, and can miss a small change between its taps).
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }
        return ScreenSample(width: image.width, height: image.height, columns: columns, rows: rows, cells: cells)
    }

    /// The colors around `rect` (the plate's) and in it (the text's), from
    /// the block scaled down to 24 pixels high with a margin of background.
    private static func colors(in image: CGImage, around rect: CGRect,
                               lineHeight: Double) -> (background: ScreenTextLayout.RGB, text: ScreenTextLayout.RGB) {
        let margin = max(2, lineHeight * 0.2)
        let area = rect.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard area.width >= 3, area.height >= 3, let crop = image.cropping(to: area),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return ScreenTextLayout.plateColors(edge: [], inside: []) }
        let height = 24
        let width = max(4, min(192, Int((Double(height) * area.width / area.height).rounded())))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return ScreenTextLayout.plateColors(edge: [], inside: []) }
        var edge: [ScreenTextLayout.RGB] = [], inside: [ScreenTextLayout.RGB] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let color = ScreenTextLayout.RGB(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255,
                                                 blue: Double(bytes[offset + 2]) / 255)
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { edge.append(color) } else { inside.append(color) }
            }
        }
        return ScreenTextLayout.plateColors(edge: edge, inside: inside)
    }
}
