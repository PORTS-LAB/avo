import CoreGraphics
import Foundation
import Testing
@testable import AvoKit

/// Live Translate Screen: where frames differ (ScreenSample, ScreenChanges)
/// and when to drop plates and read again (ScreenWatch).
@Suite struct ScreenChangesTests {
    /// A 720 × 1280 frame as 45 × 80 cells of 16 pixels: a light background
    /// with text on some rows (each cell of it as dark as the letters in it).
    private struct Screen {
        var lines: [(row: Int, columns: ClosedRange<Int>)]
        var offset = 0 // rows scrolled up
        var extra: [Int: UInt8] = [:] // cell index → gray

        var sample: ScreenSample {
            var cells = [UInt8](repeating: 230, count: 45 * 80)
            for line in lines {
                let row = line.row - offset
                guard (0..<80).contains(row) else { continue }
                for column in line.columns { cells[row * 45 + column] = UInt8(30 + (line.row * 31 + column * 17) % 90) }
            }
            for (index, gray) in extra { cells[index] = gray }
            return ScreenSample(width: 720, height: 1280, columns: 45, rows: 80, cells: cells)
        }
    }

    /// The frame pixels of a text line in `Screen` (one row of cells).
    private func rect(row: Int, columns: ClosedRange<Int>) -> CGRect {
        CGRect(x: columns.lowerBound * 16, y: row * 16, width: (columns.count) * 16, height: 16)
    }

    private let home = Screen(lines: [(5, 2...20), (10, 2...30), (11, 2...25), (40, 2...12), (41, 30...40), (78, 2...8)])
    private let detail = Screen(lines: [(3, 4...14), (20, 2...35), (24, 6...26), (30, 2...40), (31, 2...36), (50, 2...20)])

    @Test func theGridHasCellsOfAboutSixteenPixels() {
        #expect(ScreenSample.grid(width: 720, height: 1280) == (45, 80))
        #expect(ScreenSample.grid(width: 1080, height: 2400) == (68, 150))
        // A big display keeps to 160 cells along its long side.
        #expect(ScreenSample.grid(width: 3840, height: 2160) == (160, 90))
        #expect(ScreenSample.grid(width: 0, height: 0) == (1, 1))
    }

    @Test func changesAreTheCellsThatDifferBeyondTheTolerance() throws {
        var flicker = home
        flicker.extra[100] = 232 // 2 levels: the same picture
        var cursor = home
        cursor.extra[10 * 45 + 31] = 40 // a cursor after the text on row 10
        let same = try #require(home.sample.changes(to: flicker.sample))
        #expect(same.isEmpty)
        let changed = try #require(home.sample.changes(to: cursor.sample))
        #expect(changed.count == 1)
        #expect(changed.fraction == 1.0 / 3600)
        #expect(home.sample.matches(flicker.sample, tolerance: 3))
        #expect(!home.sample.matches(cursor.sample))
        // Another size: everything changed.
        let other = ScreenSample(width: 1280, height: 720, columns: 80, rows: 45, cells: home.sample.cells)
        #expect(home.sample.changes(to: other) == nil)
        #expect(!home.sample.matches(other))
    }

    @Test func aCursorDoesNotSpoilItsLineButAScrollOrANewScreenDoes() throws {
        let line = rect(row: 10, columns: 2...30)
        var cursor = home
        cursor.extra[10 * 45 + 31] = 40 // after the text
        cursor.extra[10 * 45 + 30] = 200 // over its last letter
        let blink = try #require(home.sample.changes(to: cursor.sample))
        #expect(blink.cells(under: line) == (1, 29))
        #expect(!blink.spoils(line))
        var scrolled = home
        scrolled.offset = 1
        let scroll = try #require(home.sample.changes(to: scrolled.sample))
        #expect(scroll.spoils(line))
        let navigation = try #require(home.sample.changes(to: detail.sample))
        #expect(navigation.spoils(line))
        // Text that did not change keeps its plate: the bottom bar stays put while the list scrolls.
        var listOnly = home
        listOnly.lines = home.lines.map { $0.row == 78 ? $0 : (row: $0.row - 1, columns: $0.columns) }
        let list = try #require(home.sample.changes(to: listOnly.sample))
        #expect(!list.spoils(rect(row: 78, columns: 2...8)))
        #expect(list.spoils(rect(row: 40, columns: 2...12)))
        // A tiny plate goes with any change under it.
        var badge = home
        badge.extra[5 * 45 + 2] = 120
        #expect(try #require(home.sample.changes(to: badge.sample)).spoils(rect(row: 5, columns: 2...2)))
        // Outside the frame there is nothing to spoil.
        #expect(!scroll.spoils(CGRect(x: 800, y: 0, width: 50, height: 50)))
    }

    @Test func textReadBeforeIsKeptWhereNothingChanged() throws {
        // A toast appears at the bottom: the text above it stays as it was read.
        var toast = home
        toast.lines.append((70, 10...30))
        let changes = try #require(home.sample.changes(to: toast.sample))
        let title = rect(row: 5, columns: 2...20), body = rect(row: 10, columns: 2...30)
        #expect(changes.leavesAlone(title))
        #expect(!changes.leavesAlone(rect(row: 70, columns: 10...30)))
        let old = [title, body]
        let new = [title.offsetBy(dx: 1, dy: 0.5), // the same text, its box a pixel off
                   body.insetBy(dx: 100, dy: 0), // much smaller: not the same box
                   rect(row: 70, columns: 10...30)] // the toast: changed
        #expect(changes.carriedOver(new: new, old: old) == [0, nil, nil])
        // Where the screen changed, nothing is kept.
        var moved = home
        moved.offset = 1
        let scroll = try #require(home.sample.changes(to: moved.sample))
        #expect(scroll.carriedOver(new: [title], old: [title]) == [nil])
    }

    @Test func theFirstLookReadsAtOnce() {
        var watch = ScreenWatch()
        let step = watch.look(at: detail.sample, time: 0)
        #expect(step.read)
        #expect(!step.moving)
        #expect(step.sinceShown == nil)
        #expect(watch.reading)
        // One read at a time.
        #expect(!watch.look(at: detail.sample, time: 0.1).read)
    }

    /// The bug users saw: plates read from the post they had open stayed over
    /// the home feed they went back to.
    @Test func platesOfAnEarlierScreenNeverShowOverANewOne() throws {
        var watch = ScreenWatch()
        #expect(watch.look(at: detail.sample, time: 0).read)
        watch.finishedReading(detail.sample)
        let title = rect(row: 20, columns: 2...35), author = rect(row: 24, columns: 6...26)
        // Back to the home feed: every plate of the post goes on the first look.
        let back = watch.look(at: home.sample, time: 0.1)
        let changes = try #require(back.sinceShown)
        #expect(changes.spoils(title) && changes.spoils(author))
        #expect(back.moving)
        #expect(!back.read)
        // The feed holds still: it is read on the next look.
        #expect(watch.look(at: home.sample, time: 0.2).read)
    }

    /// The other half of it: a read that ends after the screen changed (the
    /// first read in an app can take most of a minute) is checked against the
    /// screen now, and that screen is read next.
    @Test func aReadThatEndsAfterTheScreenChangedIsCheckedAgainstTheScreenNow() throws {
        var watch = ScreenWatch()
        #expect(watch.look(at: detail.sample, time: 0).read)
        // While the post is being read, the user goes back to the feed.
        #expect(!watch.look(at: home.sample, time: 0.1).read)
        #expect(!watch.look(at: home.sample, time: 0.2).read) // still reading
        watch.finishedReading(detail.sample)
        // The read's plates are checked against the frame on screen now.
        let latest = try #require(watch.latest)
        let since = try #require(detail.sample.changes(to: latest))
        #expect(since.spoils(rect(row: 20, columns: 2...35)))
        // And the feed is read on the next look.
        let next = watch.look(at: home.sample, time: 0.3)
        #expect(next.read)
        #expect(next.sinceShown?.spoils(rect(row: 30, columns: 2...40)) == true)
    }

    @Test func aScrollHidesThePlatesAndTheScreenIsReadOnceItStops() throws {
        var watch = ScreenWatch()
        #expect(watch.look(at: home.sample, time: 0).read)
        watch.finishedReading(home.sample)
        let row40 = rect(row: 40, columns: 2...12)
        var frame = home
        var time = 0.0
        for offset in 1...6 {
            frame.offset = offset * 2
            time += 0.1
            let step = watch.look(at: frame.sample, time: time)
            #expect(step.moving)
            #expect(!step.read)
            #expect(step.sinceShown?.spoils(row40) == true)
        }
        // Stopped: the first still look reads the screen where it stopped.
        time += 0.1
        let still = watch.look(at: frame.sample, time: time)
        #expect(!still.moving)
        #expect(still.read)
        watch.finishedReading(frame.sample)
        #expect(watch.look(at: frame.sample, time: time + 0.1).sinceShown?.isEmpty == true)
        #expect(!watch.look(at: frame.sample, time: time + 5).read)
    }

    @Test func aSmallChangeIsReadAtMostEveryInterval() {
        var watch = ScreenWatch()
        #expect(watch.look(at: home.sample, time: 0).read)
        watch.finishedReading(home.sample)
        var cursor = home
        cursor.extra[10 * 45 + 31] = 40
        // A cursor appears 0.5 s after the read: too soon to read again for it.
        #expect(!watch.look(at: cursor.sample, time: 0.5).read) // it just changed: moving cells are not read
        #expect(!watch.look(at: cursor.sample, time: 0.6).read)
        #expect(!watch.look(at: cursor.sample, time: 1.4).read)
        // Once the interval has passed since the last read, it is.
        #expect(watch.look(at: cursor.sample, time: 1.6).read)
        watch.finishedReading(cursor.sample)
        // A big change is read as soon as it holds still.
        #expect(!watch.look(at: detail.sample, time: 1.7).read)
        #expect(watch.look(at: detail.sample, time: 1.8).read)
    }

    @Test func smallChangesThatBringNoNewTextAreReadLessAndLessOften() {
        var watch = ScreenWatch()
        #expect(watch.look(at: home.sample, time: 0).read)
        watch.finishedReading(home.sample)
        // A little animation (a blinking dot) that is not text: each read finds nothing new.
        var time = 0.0
        var reads: [Double] = []
        for look in 1...400 {
            time += 0.1
            var dot = home
            if look % 5 < 2 { dot.extra[60 * 45 + 40] = 10 }
            let sample = dot.sample
            if watch.look(at: sample, time: time).read {
                reads.append((time * 10).rounded() / 10)
                watch.finishedReading(sample, foundNewText: false)
            }
        }
        let gaps = zip(reads.dropFirst(), reads).map { $0 - $1 }
        #expect(gaps.count >= 4)
        // 1.5, 3, 6 and then at most 12 seconds apart (give or take a blink).
        #expect(gaps.allSatisfy { $0 >= 1.5 && $0 <= 13 })
        #expect(gaps.suffix(2).allSatisfy { $0 >= 11 })
        #expect(watch.smallInterval == ScreenWatch.longestSmallChangeInterval)
        // New text brings the wait back.
        var typed = home
        typed.extra[60 * 45 + 40] = 10
        typed.extra[60 * 45 + 41] = 10
        _ = watch.look(at: typed.sample, time: time + 20)
        let read = watch.look(at: typed.sample, time: time + 20.1)
        #expect(read.read)
        watch.finishedReading(typed.sample, foundNewText: true)
        #expect(watch.smallInterval == ScreenWatch.smallChangeInterval)
    }

    @Test func aStillScreenThatWasReadNeedsNoMoreLooks() {
        var watch = ScreenWatch()
        let first = watch.look(at: home.sample, time: 0)
        #expect(first.read && first.pending) // pending while the read runs
        #expect(watch.look(at: home.sample, time: 0.1).pending)
        watch.finishedReading(home.sample)
        #expect(!watch.look(at: home.sample, time: 0.2).pending)
        // Moving: pending, even if no new frame comes.
        var scrolled = home
        scrolled.offset = 3
        #expect(watch.look(at: scrolled.sample, time: 0.3).pending)
    }

    @Test func somethingThatNeverStopsMovingDoesNotHoldUpTheRest() {
        var watch = ScreenWatch()
        // A video in the top quarter: its cells change on every look.
        func frame(_ look: Int, scrolled: Bool) -> ScreenSample {
            var screen = scrolled ? detail : home
            for row in 0..<20 {
                for column in 0..<45 { screen.extra[row * 45 + column] = UInt8((look * 37 + row + column) % 200) }
            }
            return screen.sample
        }
        var time = 0.0
        #expect(watch.look(at: frame(0, scrolled: false), time: time).read)
        watch.finishedReading(frame(0, scrolled: false))
        // The text below changes and holds still, but the video keeps moving.
        var reads = 0
        for look in 1...(ScreenWatch.restlessLooks + 3) {
            time += 0.1
            if watch.look(at: frame(look, scrolled: true), time: time).read {
                reads += 1
                watch.finishedReading(frame(look, scrolled: true))
            }
        }
        // Read once the video counts as an animation, and only once.
        #expect(reads == 1)
    }

    @Test func aNewDisplaySizeDropsAllPlatesAndReadsOnceItSettles() {
        var watch = ScreenWatch()
        #expect(watch.look(at: home.sample, time: 0).read)
        watch.finishedReading(home.sample)
        let rotated = ScreenSample(width: 1280, height: 720, columns: 80, rows: 45, cells: home.sample.cells)
        let step = watch.look(at: rotated, time: 0.1)
        #expect(step.sinceShown == nil) // no plate fits any more
        #expect(step.moving)
        #expect(!step.read)
        #expect(watch.look(at: rotated, time: 0.2).read)
    }

    @Test func aReadThatFailedIsTriedAgain() {
        var watch = ScreenWatch()
        #expect(watch.look(at: home.sample, time: 0).read)
        watch.abandonedReading()
        #expect(watch.look(at: home.sample, time: 0.1).read)
        watch.reset()
        #expect(watch.shown == nil && watch.latest == nil && !watch.reading)
    }
}
