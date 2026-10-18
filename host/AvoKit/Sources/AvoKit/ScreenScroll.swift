import CoreGraphics
import Foundation

/// Which way a view scrolls: up and down, or sideways.
public enum ScrollAxis: Sendable, Equatable {
    case vertical, horizontal
}

/// How the picture in one part of the screen moved between two samples of
/// it (the same region, on the same grid). The mouse wheel's Automatic
/// scroll mode tells by it whether the app scrolled: the content under the
/// pointer slides along the axis when it does.
public enum RegionMotion: Sendable, Equatable {
    /// Nothing changed, or next to nothing (a blinking cursor).
    case still
    /// The content slid along the axis by this many pixels (positive: down
    /// or to the right), which explains most of what changed: a scroll.
    case shifted(pixels: Double)
    /// Something changed that no slide along the axis explains: an
    /// animation, a video, another screen, an overscroll stretch.
    case changed
}

/// The part of the frame watched for a scroll at a point: the display's
/// full width (a list or a carousel spans it) and a band around the point,
/// half the display high for up and down, a third for sideways. Its grid has
/// fine cells along the axis, so a slide of a few pixels shows, and coarse
/// ones across it, which keeps a look cheap.
public struct ScrollRegion: Sendable, Equatable {
    /// Frame pixels, origin at the top left.
    public let rect: CGRect
    public let columns: Int
    public let rows: Int

    /// Pixels per cell along the axis.
    static let fineCell = 4.0
    /// Pixels per cell across the axis.
    static let coarseCell = 40.0
    static let maxFine = 320
    static let maxCoarse = 32

    public init(rect: CGRect, columns: Int, rows: Int) {
        self.rect = rect
        self.columns = columns
        self.rows = rows
    }

    public init(around x: Double, _ y: Double, axis: ScrollAxis, width: Double, height: Double) {
        let w = max(width.rounded(), 1), h = max(height.rounded(), 1)
        let band = (axis == .vertical ? h / 2 : h / 3).rounded()
        let top = min(max((y - band / 2).rounded(), 0), h - band)
        rect = CGRect(x: 0, y: top, width: w, height: band)
        func cells(_ length: Double, _ cell: Double, _ limit: Int) -> Int {
            min(limit, max(1, Int((length / cell).rounded())))
        }
        switch axis {
        case .vertical:
            columns = min(Self.maxCoarse, max(8, cells(w, Self.coarseCell, Self.maxCoarse)))
            rows = cells(band, Self.fineCell, Self.maxFine)
        case .horizontal:
            columns = cells(w, Self.fineCell, Self.maxFine)
            rows = min(Self.maxCoarse, max(8, cells(band, Self.coarseCell, Self.maxCoarse)))
        }
    }
}

extension ScreenSample {
    /// Gray levels a cell may change by and still count as the same.
    static let motionTolerance = 6
    /// At most this part of the cells changing is still (a cursor blinking).
    static let stillFraction = 0.0025
    /// A slide explains a change when the cells that changed differ from
    /// the slid picture by at most this part of how much they changed.
    static let slideFit = 0.45
    /// A scroll changes at least this part of the region (a marquee or a
    /// small animation that happens to slide does not).
    static let slideMinimum = 0.02

    /// How the picture moved from this sample to `other` (the same region
    /// and grid, taken later), along `axis`; with `direction` (+1: down or
    /// right, -1: up or left) only slides that way count, as when the caller
    /// knows which way a scroll would go. Nil when the samples differ in
    /// size or grid.
    ///
    /// Only the cells that changed count: what stands still (a toolbar, the
    /// background between rows) says nothing about a slide. For each slide
    /// along the axis, up to half the region, it measures how far the
    /// changed cells are from this sample slid that far (both ways, see
    /// `Slides`). The best slides are found on a grid four times coarser and
    /// then refined in half cells, together with the small slides a coarse
    /// grid cannot see. Lists repeat themselves every item, so a slide by
    /// one item more or less can fit almost as well: the magnitude is a
    /// guess within that, the direction (when given) is not.
    public func motion(to other: ScreenSample, along axis: ScrollAxis, direction: Int? = nil) -> RegionMotion? {
        guard width == other.width, height == other.height, columns == other.columns, rows == other.rows else { return nil }
        let along = axis == .vertical ? rows : columns
        let across = axis == .vertical ? columns : rows
        // Cells as [along][across], so both axes run the same code.
        let a = Self.lines(cells, columns: columns, rows: rows, axis: axis)
        let b = Self.lines(other.cells, columns: columns, rows: rows, axis: axis)
        let fine = Slides(before: a, after: b, along: along, across: across, tolerance: Self.motionTolerance)
        guard Double(fine.changedCount) > Double(along * across) * Self.stillFraction, fine.changedCount > 1 else { return .still }
        guard Double(fine.changedCount) >= Double(along * across) * Self.slideMinimum else { return .changed }
        let still = fine.error(shift: 0)
        guard still > 0 else { return .still }
        let reach = Double(along / 2)
        let lowest = direction.map { $0 > 0 ? 0.5 : -reach } ?? -reach
        let highest = direction.map { $0 > 0 ? reach : -0.5 } ?? reach
        // Small slides, then around the best coarse ones.
        var ranges = [max(lowest, -4)...min(highest, 4)]
        if along >= 32 {
            let step = 4
            let coarse = Slides(before: Self.grouped(a, along: along, across: across, step: step),
                                after: Self.grouped(b, along: along, across: across, step: step),
                                along: along / step, across: across, tolerance: Self.motionTolerance, measured: Slides.measured / 2)
            let coarseReach = Double((along / step) / 2)
            // In half coarse cells: a slide halfway between two of them fits neither.
            var candidates: [(shift: Double, error: Double)] = []
            var shift = -coarseReach
            while shift <= coarseReach {
                let fineShift = shift * Double(step)
                if shift != 0, fineShift >= lowest - 2, fineShift <= highest + 2 {
                    candidates.append((shift, coarse.error(shift: shift)))
                }
                shift += 0.5
            }
            // The best few that are not neighbours of a better one.
            var picked: [Double] = []
            for candidate in candidates.sorted(by: { $0.error < $1.error }) where candidate.error.isFinite {
                guard !picked.contains(where: { abs($0 - candidate.shift) <= 1 }) else { continue }
                picked.append(candidate.shift)
                if picked.count == 3 { break }
            }
            for center in picked {
                let middle = center * Double(step)
                ranges.append(max(lowest, middle - 2)...min(highest, middle + 2))
            }
        } else {
            ranges = [lowest...highest]
        }
        // In half cells.
        var best = (shift: 0.0, error: Double.infinity)
        for range in ranges where range.lowerBound <= range.upperBound {
            var shift = (range.lowerBound * 2).rounded(.up) / 2
            while shift <= range.upperBound {
                if shift != 0 {
                    let error = fine.error(shift: shift)
                    if error < best.error { best = (shift, error) }
                }
                shift += 0.5
            }
        }
        guard best.error <= Self.slideFit * still else { return .changed }
        let cell = axis == .vertical ? Double(height) / Double(rows) : Double(width) / Double(columns)
        return .shifted(pixels: best.shift * cell)
    }

    /// The cells as lines along the axis: row by row for vertical, column by column for horizontal.
    private static func lines(_ cells: [UInt8], columns: Int, rows: Int, axis: ScrollAxis) -> [Double] {
        switch axis {
        case .vertical:
            return cells.map(Double.init)
        case .horizontal:
            var out = [Double](repeating: 0, count: cells.count)
            for row in 0..<rows {
                for column in 0..<columns { out[column * rows + row] = Double(cells[row * columns + column]) }
            }
            return out
        }
    }

    /// Averages of `step` neighbouring cells along the axis.
    private static func grouped(_ values: [Double], along: Int, across: Int, step: Int) -> [Double] {
        let count = along / step
        var out = [Double](repeating: 0, count: count * across)
        for line in 0..<count {
            for cell in 0..<across {
                var sum = 0.0
                for k in 0..<step { sum += values[(line * step + k) * across + cell] }
                out[line * across + cell] = sum / Double(step)
            }
        }
        return out
    }
}

/// Compares a later picture with an earlier one slid along the axis.
private struct Slides {
    /// The changed cells measured: at most this many, spread over all of
    /// them (a few hundred tell a slide as well as all of them, and this
    /// runs several times a second, in debug builds too).
    static let measured = 512

    let before: [Double]
    let after: [Double]
    let along: Int
    let across: Int
    /// How many cells changed.
    let changedCount: Int
    /// The line and the place across it of the changed cells measured.
    private let lines: [Int]
    private let places: [Int]

    init(before: [Double], after: [Double], along: Int, across: Int, tolerance: Int, measured: Int = Slides.measured) {
        self.before = before
        self.after = after
        self.along = along
        self.across = across
        let limit = Double(tolerance)
        var changed: [Int] = []
        before.withUnsafeBufferPointer { a in
            after.withUnsafeBufferPointer { b in
                for index in 0..<a.count where abs(a[index] - b[index]) > limit { changed.append(index) }
            }
        }
        changedCount = changed.count
        let stride = max(1, (changed.count + measured - 1) / measured)
        var lines: [Int] = [], places: [Int] = []
        lines.reserveCapacity(changed.count / stride + 1)
        places.reserveCapacity(changed.count / stride + 1)
        var index = 0
        while index < changed.count {
            lines.append(changed[index] / across)
            places.append(changed[index] % across)
            index += stride
        }
        self.lines = lines
        self.places = places
    }

    /// How far the changed cells are from the earlier picture slid by
    /// `shift` cells (positive: down or right), both ways: what each shows
    /// now must have been `shift` before it, and what each showed before
    /// must be `shift` further on now. One way alone, content that went
    /// away would pass for a slide (the background it left matches the
    /// background anywhere). The mean of the two mean differences, over the
    /// cells the slide keeps inside the region; infinity when that is under
    /// half of them either way. A half-cell slide takes the mean of two
    /// neighbours.
    func error(shift: Double) -> Double {
        let whole = Int(shift.rounded(.down))
        let half = shift - Double(whole) > 0.25
        guard let forward = meanDifference(of: after, against: before, by: whole, half: half),
              let backward = meanDifference(of: before, against: after, by: half ? -whole - 1 : -whole, half: half)
        else { return .infinity }
        return (forward + backward) / 2
    }

    /// The mean of |values[i] − others[i − slide]| over the changed cells
    /// measured (lines along the axis), others taken half a cell further
    /// back when `half`.
    private func meanDifference(of values: [Double], against others: [Double], by slide: Int, half: Bool) -> Double? {
        var sum = 0.0, count = 0
        let across = across, along = along
        values.withUnsafeBufferPointer { b in
            others.withUnsafeBufferPointer { a in
                lines.withUnsafeBufferPointer { lines in
                    places.withUnsafeBufferPointer { places in
                        for k in 0..<lines.count {
                            let line = lines[k], place = places[k]
                            let source = line - slide
                            let value = b[line * across + place]
                            var difference: Double
                            if half {
                                guard source >= 1, source < along else { continue }
                                difference = value - (a[source * across + place] + a[(source - 1) * across + place]) * 0.5
                            } else {
                                guard source >= 0, source < along else { continue }
                                difference = value - a[source * across + place]
                            }
                            // Not abs(): a generic call in debug builds.
                            if difference < 0 { difference = -difference }
                            sum += difference
                            count += 1
                        }
                    }
                }
            }
        }
        guard count * 2 >= lines.count, count > 0 else { return nil }
        return sum / Double(count)
    }
}
