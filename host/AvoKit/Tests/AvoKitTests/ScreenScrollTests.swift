import CoreGraphics
import Foundation
import Testing
@testable import AvoKit

/// The mouse wheel's scroll watch: where it looks (ScrollRegion) and how it
/// tells a scroll from anything else that changes (ScreenSample.motion).
@Suite struct ScreenScrollTests {
    /// A list on a light background, as gray pixels: items 56 to 88 pixels
    /// high, each with an icon and two lines of words of their own lengths
    /// and grays.
    private struct Page {
        /// Content pixels that scrolled out at the top (or in, when negative).
        var offset = 0.0
        /// Content pixels that slid to the left (sideways scrolling).
        var sideways = 0.0
        /// A toolbar that stays put over the region's first pixels (it begins at 320).
        var toolbar = 0
        /// A square that changes gray (a spinner, a video), in frame pixels.
        var blink: (x: Int, y: Int, size: Int, gray: Double)?

        private struct Item {
            var start: Double
            var height: Double
            var seed: Int
        }

        private static let items: [Item] = {
            var items: [Item] = []
            var y = -4000.0, index = 0
            while y < 6000 {
                let seed = (index &* 7919 &+ 104_729) & 0xFFFF
                let height = 56 + Double(seed % 5) * 8
                items.append(Item(start: y, height: height, seed: seed))
                y += height
                index += 1
            }
            return items
        }()

        private static func item(at y: Double) -> Item {
            var low = 0, high = items.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if items[middle].start <= y { low = middle } else { high = middle - 1 }
            }
            return items[low]
        }

        func gray(_ x: Double, _ y: Double) -> Double {
            if y >= 320, y < 320 + Double(toolbar) { return 60 }
            if let blink, x >= Double(blink.x), x < Double(blink.x + blink.size), y >= Double(blink.y),
               y < Double(blink.y + blink.size) { return blink.gray }
            let cx = x + sideways, cy = y + offset
            let item = Self.item(at: cy)
            let inItem = cy - item.start, seed = item.seed
            if cx >= 8, cx < 56, inItem >= 8, inItem < item.height - 8 { return Double(40 + seed % 120) }
            let lines = [(top: 10.0, bottom: 24.0), (top: item.height - 24, bottom: item.height - 12)]
            for (line, band) in lines.enumerated() where inItem >= band.top && inItem < band.bottom {
                let length = 160 + Double((seed >> (line * 3)) % 500)
                var start = 72.0, word = 0
                while start < 72 + length {
                    let wordSeed = (seed &* 31 &+ word &* 977 &+ line &* 131) & 0xFFFF
                    let width = 24 + Double(wordSeed % 72)
                    if cx >= start, cx < start + width { return Double(20 + wordSeed % 90) }
                    start += width + 10
                    word += 1
                }
            }
            return 245
        }

        /// The region's sample: each cell the average of its pixels (every
        /// row, every other column).
        func sample(_ region: ScrollRegion) -> ScreenSample {
            let cellWidth = region.rect.width / Double(region.columns), cellHeight = region.rect.height / Double(region.rows)
            var sums = [Double](repeating: 0, count: region.columns * region.rows)
            var counts = [Double](repeating: 0, count: region.columns * region.rows)
            var y = region.rect.minY + 0.5
            while y < region.rect.maxY {
                let row = min(region.rows - 1, Int((y - region.rect.minY) / cellHeight))
                var x = region.rect.minX + 0.5
                while x < region.rect.maxX {
                    let column = min(region.columns - 1, Int((x - region.rect.minX) / cellWidth))
                    sums[row * region.columns + column] += gray(x, y)
                    counts[row * region.columns + column] += 1
                    x += 2
                }
                y += 1
            }
            let cells = zip(sums, counts).map { UInt8(($0 / max($1, 1)).rounded()) }
            return ScreenSample(width: Int(region.rect.width), height: Int(region.rect.height),
                                columns: region.columns, rows: region.rows, cells: cells)
        }
    }

    private let region = ScrollRegion(around: 360, 640, axis: .vertical, width: 720, height: 1280)

    private func shifted(_ motion: RegionMotion?) -> Double? {
        if case let .shifted(pixels)? = motion { return pixels }
        return nil
    }

    @Test func theRegionIsABandAroundThePointer() {
        // Up and down: the full width, half the height, fine rows of 4 pixels.
        #expect(region.rect == CGRect(x: 0, y: 320, width: 720, height: 640))
        #expect(region.rows == 160)
        #expect(region.columns == 18)
        // Near the top it stays on the display.
        let top = ScrollRegion(around: 100, 30, axis: .vertical, width: 1080, height: 2340)
        #expect(top.rect == CGRect(x: 0, y: 0, width: 1080, height: 1170))
        #expect(top.rows == 293 && top.columns == 27)
        let bottom = ScrollRegion(around: 100, 2339, axis: .vertical, width: 1080, height: 2340)
        #expect(bottom.rect.maxY == 2340)
        // Sideways: a third of the height, fine columns.
        let sideways = ScrollRegion(around: 500, 1000, axis: .horizontal, width: 1080, height: 2340)
        #expect(sideways.rect == CGRect(x: 0, y: 610, width: 1080, height: 780))
        #expect(sideways.columns == 270 && sideways.rows == 20)
        // A big display keeps to the cell limits.
        let big = ScrollRegion(around: 0, 0, axis: .vertical, width: 3840, height: 4000)
        #expect(big.rows == 320 && big.columns == 32)
    }

    @Test func theSamePictureIsStill() throws {
        let page = Page()
        #expect(page.sample(region).motion(to: page.sample(region), along: .vertical) == .still)
        // A cursor blinking in one cell is still too.
        var cursor = page.sample(region).cells
        cursor[50 * region.columns + 9] = 0
        let blinked = ScreenSample(width: 720, height: 640, columns: region.columns, rows: region.rows, cells: cursor)
        #expect(page.sample(region).motion(to: blinked, along: .vertical) == .still)
    }

    @Test func aScrollIsASlideOfTheContent() throws {
        let before = Page().sample(region)
        // The wheel rolled one line: Android's 64 dp at 2× moved the content up 128 pixels.
        let up = try #require(shifted(before.motion(to: Page(offset: 128).sample(region), along: .vertical)))
        #expect(abs(up + 128) <= 2, "\(up)")
        let down = try #require(shifted(before.motion(to: Page(offset: -200).sample(region), along: .vertical)))
        #expect(abs(down - 200) <= 2, "\(down)")
        // Part of a smooth scroll: not a whole number of cells.
        let partial = try #require(shifted(before.motion(to: Page(offset: 37).sample(region), along: .vertical)))
        #expect(abs(partial + 37) <= 3, "\(partial)")
        // A few pixels are a slide too.
        let small = try #require(shifted(before.motion(to: Page(offset: 10).sample(region), along: .vertical)))
        #expect(abs(small + 10) <= 2, "\(small)")
    }

    @Test func whatStandsStillDoesNotHideTheSlide() throws {
        // A toolbar over the top of the region stays; the list under it scrolls.
        let before = Page(toolbar: 100).sample(region)
        let after = Page(offset: 96, toolbar: 100).sample(region)
        let pixels = try #require(shifted(before.motion(to: after, along: .vertical)))
        #expect(abs(pixels + 96) <= 2)
    }

    @Test func aScrollWithAnAnimationBesideItIsStillASlide() throws {
        let before = Page(blink: (x: 600, y: 700, size: 80, gray: 20)).sample(region)
        let after = Page(offset: 150, blink: (x: 600, y: 700, size: 80, gray: 200)).sample(region)
        let pixels = try #require(shifted(before.motion(to: after, along: .vertical)))
        #expect(abs(pixels + 150) <= 2, "\(pixels)")
    }

    @Test func anAnimationIsNoSlide() {
        // A spinner or a video under the pointer: it changes, nothing slides.
        let before = Page(blink: (x: 200, y: 500, size: 200, gray: 20)).sample(region)
        let after = Page(blink: (x: 200, y: 500, size: 200, gray: 230)).sample(region)
        #expect(before.motion(to: after, along: .vertical) == .changed)
        // Another screen altogether.
        let other = Page(sideways: 0, toolbar: 0).sample(region)
        var cells = other.cells
        for index in cells.indices { cells[index] = UInt8(255 - Int(cells[index])) }
        let inverted = ScreenSample(width: 720, height: 640, columns: region.columns, rows: region.rows, cells: cells)
        #expect(other.motion(to: inverted, along: .vertical) == .changed)
    }

    @Test func aStretchIsNoSlideOfTheFingersWay() {
        // Android's overscroll stretch at the end of a list scales the
        // content a little from the far edge: no single slide explains it.
        let page = Page()
        var cells = [UInt8](repeating: 0, count: region.columns * region.rows)
        let stretched = Page()
        for row in 0..<region.rows {
            for column in 0..<region.columns {
                let y = 320 + (Double(row) + 0.5) * 4, x = (Double(column) + 0.5) * 40
                // 6% taller, anchored at the region's bottom.
                let source = 960 - (960 - y) / 1.06
                cells[row * region.columns + column] = UInt8(stretched.gray(x, source).rounded())
            }
        }
        let after = ScreenSample(width: 720, height: 640, columns: region.columns, rows: region.rows, cells: cells)
        let motion = page.sample(region).motion(to: after, along: .vertical)
        if case let .shifted(pixels)? = motion {
            // At most a little slide: far less than a finger's swipe.
            #expect(abs(pixels) < 60)
        }
    }

    @Test func sidewaysScrollingSlidesAlongTheColumns() throws {
        let strip = ScrollRegion(around: 360, 640, axis: .horizontal, width: 720, height: 1280)
        let before = Page().sample(strip)
        let after = Page(sideways: 180).sample(strip)
        let pixels = try #require(shifted(before.motion(to: after, along: .horizontal)))
        #expect(abs(pixels + 180) <= 2)
        // Up and down it is no slide.
        #expect(shifted(before.motion(to: after, along: .vertical)) == nil)
    }

    @Test func otherSizesCannotBeCompared() {
        let a = ScreenSample(width: 720, height: 640, columns: 18, rows: 160, cells: [UInt8](repeating: 1, count: 18 * 160))
        let b = ScreenSample(width: 720, height: 600, columns: 18, rows: 160, cells: [UInt8](repeating: 1, count: 18 * 160))
        #expect(a.motion(to: b, along: .vertical) == nil)
    }
}
