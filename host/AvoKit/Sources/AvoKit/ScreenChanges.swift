import CoreGraphics
import Foundation

/// A frame scaled down to a grid of gray cells, each the average of the
/// pixels it covers (Translate Screen). Two samples tell where the screen
/// changed: the plates over text that moved or went away must go at once,
/// and the screen is read again where it changed once it holds still.
public struct ScreenSample: Equatable, Sendable {
    /// The frame's size in pixels.
    public let width: Int
    public let height: Int
    public let columns: Int
    public let rows: Int
    /// Gray levels, row by row from the top.
    public let cells: [UInt8]

    public init(width: Int, height: Int, columns: Int, rows: Int, cells: [UInt8]) {
        precondition(columns > 0 && rows > 0 && cells.count == columns * rows, "cells must fill the grid")
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.cells = cells
    }

    /// The grid for a frame: cells of about `cell` pixels square (a line of
    /// small text spans two or three rows), at most `limit` along a side.
    public static func grid(width: Int, height: Int, cell: Int = 16, limit: Int = 160) -> (columns: Int, rows: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let size = max(Double(cell), Double(max(width, height)) / Double(limit))
        return (max(1, Int((Double(width) / size).rounded(.up))), max(1, Int((Double(height) / size).rounded(.up))))
    }

    /// Where `other` differs from this sample: the cells whose gray changed
    /// by more than `tolerance`. Nil when the frames differ in size (Android
    /// re-plugged its display or turned): then all of it changed.
    public func changes(to other: ScreenSample, tolerance: Int = 3) -> ScreenChanges? {
        guard width == other.width, height == other.height, columns == other.columns, rows == other.rows else { return nil }
        // Buffers, not arrays: this runs ten times a second, in debug builds too.
        var count = 0
        let changed = [Bool](unsafeUninitializedCapacity: cells.count) { changed, initialized in
            cells.withUnsafeBufferPointer { a in
                other.cells.withUnsafeBufferPointer { b in
                    for index in 0..<a.count {
                        let differs = abs(Int(a[index]) - Int(b[index])) > tolerance
                        changed[index] = differs
                        if differs { count += 1 }
                    }
                }
            }
            initialized = cells.count
        }
        return ScreenChanges(width: width, height: height, columns: columns, rows: rows, changed: changed, count: count)
    }

    /// The same picture: same size, and no cell differs by more than `tolerance`.
    public func matches(_ other: ScreenSample, tolerance: Int = 1) -> Bool {
        changes(to: other, tolerance: tolerance)?.isEmpty == true
    }
}

/// The cells of a `ScreenSample` grid that changed between two frames.
public struct ScreenChanges: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let columns: Int
    public let rows: Int
    public let changed: [Bool]
    /// How many cells changed.
    public let count: Int

    public init(width: Int, height: Int, columns: Int, rows: Int, changed: [Bool]) {
        self.init(width: width, height: height, columns: columns, rows: rows, changed: changed,
                  count: changed.count(where: { $0 }))
    }

    init(width: Int, height: Int, columns: Int, rows: Int, changed: [Bool], count: Int) {
        precondition(columns > 0 && rows > 0 && changed.count == columns * rows, "changed must fill the grid")
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.changed = changed
        self.count = count
    }

    public var isEmpty: Bool { count == 0 }

    /// The part of the frame that changed, from 0 to 1.
    public var fraction: Double { Double(count) / Double(changed.count) }

    /// The cells under `rect` (frame pixels, origin at the top left): how
    /// many there are, and how many of them changed.
    public func cells(under rect: CGRect) -> (changed: Int, total: Int) {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let area = rect.intersection(frame)
        guard !area.isNull, area.width > 0, area.height > 0 else { return (0, 0) }
        let cellWidth = Double(width) / Double(columns), cellHeight = Double(height) / Double(rows)
        let first = (column: Int(Double(area.minX) / cellWidth), row: Int(Double(area.minY) / cellHeight))
        let last = (column: min(columns - 1, Int((Double(area.maxX) / cellWidth).rounded(.up)) - 1),
                    row: min(rows - 1, Int((Double(area.maxY) / cellHeight).rounded(.up)) - 1))
        guard last.column >= first.column, last.row >= first.row else { return (0, 0) }
        var count = 0
        for row in first.row...last.row {
            for column in first.column...last.column where changed[row * columns + column] { count += 1 }
        }
        return (count, (last.column - first.column + 1) * (last.row - first.row + 1))
    }

    /// Whether a plate over `rect` no longer covers what it was made for: a
    /// fifth or more of the cells under it changed (the text scrolled, went
    /// away or was covered), not just a blinking cursor at its end.
    public func spoils(_ rect: CGRect) -> Bool {
        let (changed, total) = cells(under: rect)
        return changed > 0 && changed * 5 >= total
    }

    /// Whether nothing changed under `rect`.
    public func leavesAlone(_ rect: CGRect) -> Bool {
        cells(under: rect).changed == 0
    }

    /// For each rect of text read now (`new`), the one read before (`old`,
    /// on the frame these changes start from) that is the same text: about
    /// the same box, with nothing changed under either. Vision reads the same
    /// pixels a little differently each time (a garbled emoji, a box a pixel
    /// off); keeping what was read before keeps a translation from changing
    /// when something elsewhere on the screen did.
    public func carriedOver(new: [CGRect], old: [CGRect]) -> [Int?] {
        new.map { rect in
            guard leavesAlone(rect) else { return nil }
            return old.indices.first { index in
                let before = old[index]
                let overlap = before.intersection(rect)
                guard !overlap.isNull else { return false }
                let union = before.union(rect)
                return overlap.width * overlap.height >= 0.7 * union.width * union.height && leavesAlone(before)
            }
        }
    }

    /// These changes without the cells that `moving` changed: the part that
    /// has stopped changing.
    public func subtracting(_ moving: ScreenChanges) -> ScreenChanges {
        guard moving.columns == columns, moving.rows == rows else { return self }
        var count = 0
        let settled = [Bool](unsafeUninitializedCapacity: changed.count) { settled, initialized in
            changed.withUnsafeBufferPointer { changed in
                moving.changed.withUnsafeBufferPointer { moving in
                    for index in 0..<changed.count {
                        let still = changed[index] && !moving[index]
                        settled[index] = still
                        if still { count += 1 }
                    }
                }
            }
            initialized = changed.count
        }
        return ScreenChanges(width: width, height: height, columns: columns, rows: rows, changed: settled, count: count)
    }
}

/// When live translation reads the screen again. It looks at the frame on
/// screen several times a second; a frame that differs from the one the
/// plates were read from spoils the plates over what changed (they go at
/// once), and once the change holds still (the scroll or the transition
/// ended) that frame is read. A small change (a clock, a counter, a cursor,
/// a little animation) is read at most every `smallChangeInterval` seconds,
/// and less often while such reads find no new text. Something that never
/// stops moving (a video, an animated banner) does not hold up the rest of
/// the screen: after `restlessLooks` looks in a row it no longer counts as
/// movement.
public struct ScreenWatch: Sendable {
    /// More than this part of the screen changing between two looks is
    /// movement (a scroll, a transition); less (a spinner, a cursor) is not.
    public static let stillness = 0.02
    /// A change to less than this part of the screen (a few words) is a small one.
    public static let smallChange = 0.01
    public static let smallChangeInterval: Double = 1.5
    /// The longest wait for a small change, after reads that found nothing new.
    public static let longestSmallChangeInterval: Double = 12
    /// Looks in a row a cell may change before it counts as an animation.
    public static let restlessLooks = 20

    /// The frame the plates on screen were read from: nil before the first read.
    public private(set) var shown: ScreenSample?
    /// The frame looked at last.
    public private(set) var latest: ScreenSample?
    /// A read is in progress.
    public private(set) var reading = false
    private var lastRead = -Double.infinity
    /// How long a small change waits now.
    public private(set) var smallInterval = smallChangeInterval
    /// The read in progress is for a small change.
    private var smallRead = false
    /// For each cell, how many looks in a row it changed.
    private var restless: [Int] = []
    private var anyRestless = false

    public init() {}

    public struct Step: Equatable, Sendable {
        /// The change from the plates' frame to this one; nil when nothing
        /// was read yet or the frame changed size (no plate fits any more).
        public var sinceShown: ScreenChanges?
        /// The screen is moving: it is read once it settles.
        public var moving: Bool
        /// Read this frame now.
        public var read: Bool
        /// Something waits to be read (the screen is moving, a read is in
        /// progress or a small change waits its turn): look again even if no
        /// new frame comes. False: until a new frame comes there is nothing to do.
        public var pending: Bool
    }

    /// Looks at the frame on screen at `time` (seconds).
    public mutating func look(at sample: ScreenSample, time: Double) -> Step {
        let previous = latest
        latest = sample
        // The first look counts as still: the screen is read right away.
        var moving = false
        var motion: ScreenChanges?
        if let previous {
            motion = previous.changes(to: sample)
            if let motion {
                if restless.count != motion.changed.count { restless = Array(repeating: 0, count: motion.changed.count) }
                var count = 0
                if !motion.isEmpty || anyRestless {
                    var counting = 0
                    motion.changed.withUnsafeBufferPointer { changed in
                        restless.withUnsafeMutableBufferPointer { restless in
                            for index in 0..<changed.count {
                                guard changed[index] else {
                                    restless[index] = 0
                                    continue
                                }
                                restless[index] += 1
                                counting += 1
                                if restless[index] < Self.restlessLooks { count += 1 }
                            }
                        }
                    }
                    anyRestless = counting > 0
                }
                moving = Double(count) / Double(motion.changed.count) > Self.stillness
            } else {
                // A new size: Android re-plugged its display or turned.
                restless = []
                anyRestless = false
                moving = true
            }
        }
        let sinceShown = shown.flatMap { $0.changes(to: sample) }
        // What changed since the read and has stopped changing.
        let settled = if let sinceShown, let motion { sinceShown.subtracting(motion) } else { sinceShown }
        var wanted = false, due = false, small = false
        if shown == nil || sinceShown == nil {
            wanted = true
            due = true
        } else if let settled, !settled.isEmpty {
            wanted = true
            small = settled.fraction < Self.smallChange
            due = !small || time - lastRead >= smallInterval
        }
        let read = due && !moving && !reading
        if read {
            reading = true
            smallRead = small
            lastRead = time
        }
        return Step(sinceShown: sinceShown, moving: moving, read: read, pending: moving || reading || wanted)
    }

    /// The read of `sample` finished: its plates are the ones on screen now.
    /// A read for a small change that found no new text makes the next small
    /// change wait twice as long (an animation that is not text); one that
    /// found some, or any other read, brings the wait back.
    public mutating func finishedReading(_ sample: ScreenSample, foundNewText: Bool = true) {
        reading = false
        shown = sample
        smallInterval = smallRead && !foundNewText ? min(smallInterval * 2, Self.longestSmallChangeInterval) : Self.smallChangeInterval
        smallRead = false
    }

    /// The read failed or was dropped: the next still look reads again.
    public mutating func abandonedReading() {
        reading = false
    }

    /// Forgets everything (translation stopped).
    public mutating func reset() {
        self = ScreenWatch()
    }
}
