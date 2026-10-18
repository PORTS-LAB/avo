import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// The mouse wheel's finger: one continuous drag per burst, eased, inside
/// the display, resting before it lifts (no fling) unless the wheel spun fast.
@Suite struct WheelSwipeTests {
    /// A phone display, 1080 × 2340 at 420 dpi (2.625 pixels per dp): a line
    /// is 160 dp = 420 pixels, the slop 21, the margin 42.
    private func finger() -> WheelSwipe {
        WheelSwipe(displayID: 7, width: 1080, height: 2340, density: 2.625)
    }

    private struct Timed {
        var time: Double
        var event: TouchEvent
        var action: TouchAction { event.action }
        var x: Double { Double(event.pointers[0].x) }
        var y: Double { Double(event.pointers[0].y) }
    }

    /// Adds `notches` (time, dx, dy) at the pointer and ticks every display
    /// frame (120 Hz) until `until` seconds.
    private func run(_ swipe: inout WheelSwipe, _ notches: [(time: Double, dx: Double, dy: Double)],
                     x: Double = 540, y: Double = 1170, until: Double, frame: Double = 1.0 / 120,
                     watch: ((inout WheelSwipe, Double) -> Void)? = nil) -> [Timed] {
        var events: [Timed] = []
        var pending = notches.sorted { $0.time < $1.time }
        var time = 0.0
        while time <= until + 1e-9 {
            while let next = pending.first, next.time <= time + 1e-9 {
                pending.removeFirst()
                events += swipe.add(dx: next.dx, dy: next.dy, x: x, y: y, at: next.time).map { Timed(time: next.time, event: $0) }
            }
            events += swipe.tick(at: time).map { Timed(time: time, event: $0) }
            watch?(&swipe, time)
            time += frame
        }
        return events
    }

    @Test func metricsFollowAndroidsDensity() {
        let phone = WheelSwipe.Metrics(width: 1080, height: 2340, density: 2.625)
        #expect(phone.lineY == 420)
        #expect(abs(phone.lineX - 0.66 * 1080) < 1e-9)
        #expect(phone.slop == 21)
        #expect(phone.margin == 42)
        let tablet = WheelSwipe.Metrics(width: 1600, height: 2560, density: 1.5)
        #expect(tablet.lineY == 240 && tablet.slop == 12)
        // A line never takes more than 40% of a small display.
        let tiny = WheelSwipe.Metrics(width: 480, height: 640, density: 2)
        #expect(tiny.lineY == 256)
    }

    @Test func oneNotchIsOneDragThatStopsWhereTheNotchTookIt() throws {
        var swipe = finger()
        // The wheel rolled toward the user: the content (and the finger) moves up a line.
        let events = run(&swipe, [(0, 0, -1)], until: 1)
        let down = try #require(events.first)
        #expect(down.action == .down && down.x == 540 && down.y == 1170)
        let moves = events.filter { $0.action == .move }
        // It moves at once, past the slop on the first frame: no tap, no long press.
        let first = try #require(moves.first)
        #expect(first.time <= 1.0 / 120 + 1e-9)
        #expect(1170 - first.y > 21)
        // Always up, never back.
        #expect(zip(moves, moves.dropFirst()).allSatisfy { $1.y < $0.y })
        let up = try #require(events.last)
        #expect(up.action == .up)
        // A line and the slop the view swallows.
        #expect(abs(up.y - (1170 - 420 - 21)) < 0.01)
        let last = try #require(moves.last)
        // It rests before lifting: Android sees no velocity, so no fling.
        #expect(up.time - last.time >= WheelSwipe.rest - 1e-9)
        #expect(up.time - last.time > 0.04)
        // Most of the way early, all of it in a quarter of a second, lifted soon after.
        let halfway = try #require(moves.first { 1170 - $0.y >= 220 })
        #expect(halfway.time < 0.05)
        #expect(last.time < 0.25)
        #expect(up.time < 0.36)
        #expect(events.filter { $0.action == .down }.count == 1)
        #expect(!swipe.isActive)
    }

    @Test func theNotchesOfABurstAreOneDrag() throws {
        var swipe = finger()
        let events = run(&swipe, [(0, 0, -1), (0.06, 0, -1)], until: 1)
        #expect(events.filter { $0.action == .down }.count == 1)
        #expect(events.filter { $0.action == .up }.count == 1)
        let up = try #require(events.last)
        #expect(abs(up.y - (1170 - 2 * 420 - 21)) < 0.01)
    }

    @Test func aNotchWhileTheFingerRestsMovesItOn() throws {
        var swipe = finger()
        // The first notch's drag arrives before 0.23 s and rests until it would lift.
        let events = run(&swipe, [(0, 0, -1), (0.23, 0, -1)], until: 1.2)
        #expect(events.filter { $0.action == .down }.count == 1)
        let moves = events.filter { $0.action == .move }
        let resumed = moves.filter { $0.time > 0.23 }
        #expect(!resumed.isEmpty)
        let up = try #require(events.last)
        #expect(up.action == .up && abs(up.y - (1170 - 2 * 420 - 21)) < 0.01)
    }

    @Test func aFastSpinLiftsWhileMovingSoAndroidFlings() throws {
        var swipe = finger()
        // Eight notches in about a tenth of a second, near the bottom: room enough.
        let notches = (0..<8).map { (time: Double($0) * 0.015, dx: 0.0, dy: -1.0) }
        let events = run(&swipe, notches, y: 2200, until: 1)
        let up = try #require(events.first { $0.action == .up })
        let before = events.filter { $0.action == .move && $0.time <= up.time }
        let last = try #require(before.last)
        // Still moving when it lifts: no rest, Android computes a velocity.
        #expect(up.time - last.time < 0.02)
        let earlier = try #require(before.last { $0.time <= up.time - 0.03 })
        let speed = (earlier.y - last.y) / (last.time - earlier.time)
        #expect(speed > 3000)
        // Soon after the spin stopped, not at the end of a long way.
        #expect(up.time < 0.105 + WheelSwipe.flingGap + 0.02)
    }

    @Test func itStaysInsideTheDisplayAndGoesDownWhereTheWayFits() throws {
        var swipe = finger()
        // At the very bottom, the content moving down: the finger needs room below.
        let events = run(&swipe, [(0, 0, 1)], x: 1079, y: 2339, until: 1)
        let down = try #require(events.first)
        #expect(down.action == .down)
        #expect(down.x == 1080 - 1 - 42)
        #expect(abs(down.y - (2339 - 42 - 441)) < 0.01)
        for timed in events {
            #expect(timed.x >= 42 && timed.x <= 1037)
            #expect(timed.y >= 42 && timed.y <= 2297)
        }
        let up = try #require(events.last)
        #expect(up.action == .up && abs(up.y - 2297) < 0.01)
    }

    @Test func aLongBurstLiftsAtTheEdgeAndGoesDownAgain() throws {
        var swipe = finger()
        // Four slow notches up from the middle: 1701 pixels, more than the 1128 of room.
        let notches = (0..<4).map { (time: Double($0) * 0.15, dx: 0.0, dy: -1.0) }
        let events = run(&swipe, notches, until: 2.5)
        let downs = events.filter { $0.action == .down }, ups = events.filter { $0.action == .up }
        #expect(downs.count == 2 && ups.count == 2)
        // The second drag goes down where the first did, after the first lifted.
        #expect(downs[1].y == downs[0].y && downs[1].time > ups[0].time)
        #expect(abs(ups[0].y - 42) < 0.01)
        // Together the whole way: four lines and the slop of each drag.
        let travel = (downs[0].y - ups[0].y) + (downs[1].y - ups[1].y)
        #expect(abs(travel - (4 * 420 + 2 * 21)) < 0.05)
        // Each lift comes after a rest.
        for up in ups {
            let move = try #require(events.last { $0.action == .move && $0.time < up.time })
            #expect(up.time - move.time >= WheelSwipe.rest - 1e-9)
        }
    }

    @Test func aFingerTheContentDoesNotFollowLiftsWithCancel() throws {
        var swipe = finger()
        // The window watched and saw nothing follow (a picture, the end of a
        // list). Three slow notches take it past the edge.
        let notches = (0..<3).map { (time: Double($0) * 0.15, dx: 0.0, dy: -1.0) }
        let events = run(&swipe, notches, until: 2.5) { swipe, _ in
            if swipe.isDown { swipe.contentFollows = false }
        }
        // No click and no fling, and it does not go down again.
        #expect(events.filter { $0.action == .down }.count == 1)
        #expect(events.last?.action == .cancel)
        #expect(!events.contains { $0.action == .up })
    }

    @Test func aFingerFoundNotFollowedAtTheEdgeDoesNotGoDownAgain() throws {
        var swipe = finger()
        // Unknown while it moves; by the time it lifts at the edge the window
        // knows nothing followed (SwipeWatch.verdict).
        let notches = (0..<4).map { (time: Double($0) * 0.1, dx: 0.0, dy: -1.0) }
        let events = run(&swipe, notches, until: 2.5) { swipe, time in
            swipe.contentFollows = time >= 0.3 ? false : nil
        }
        #expect(events.filter { $0.action == .down }.count == 1)
        #expect(events.last?.action == .cancel)
    }

    @Test func aFastSpinTheContentDoesNotFollowDoesNotFling() throws {
        var swipe = finger()
        let notches = (0..<8).map { (time: Double($0) * 0.015, dx: 0.0, dy: -1.0) }
        let events = run(&swipe, notches, y: 2200, until: 1.5) { swipe, _ in
            if swipe.isDown { swipe.contentFollows = false }
        }
        #expect(events.filter { $0.action == .down }.count == 1)
        let lift = try #require(events.last)
        #expect(lift.action == .cancel)
    }

    @Test func cancelLiftsAtOnce() throws {
        var swipe = finger()
        var events = run(&swipe, [(0, 0, -1)], until: 0.05)
        #expect(swipe.isDown)
        let at = swipe.finger
        let cancel = swipe.cancel()
        #expect(cancel.count == 1 && cancel[0].action == .cancel)
        #expect(cancel[0].pointers[0].y == Float(at.y))
        #expect(!swipe.isActive)
        events = run(&swipe, [], until: 0.5)
        #expect(events.isEmpty)
        #expect(swipe.cancel().isEmpty)
    }

    @Test func sidewaysNotchesMoveAcross() throws {
        var swipe = finger()
        // Shift + wheel: the content moves right by most of a page.
        let events = run(&swipe, [(0, 1, 0)], until: 1)
        let down = try #require(events.first)
        // It goes down far enough left for the way to fit.
        let way = 0.66 * 1080 + 21
        #expect(abs(down.x - (1037 - way)) < 0.01 && down.y == 1170)
        let up = try #require(events.last)
        #expect(up.action == .up && abs(up.x - 1037) < 0.01 && up.y == 1170)
        #expect(events.allSatisfy { $0.y == 1170 })
    }

    @Test func eventsCarryOnePointerOnTheDisplay() throws {
        var swipe = finger()
        let events = run(&swipe, [(0, 0, -0.5)], until: 1)
        #expect(events.allSatisfy { $0.event.displayID == 7 && $0.event.pointers.count == 1 && $0.event.pointers[0].id == 0 })
        // Half a line is half the way.
        let up = try #require(events.last)
        #expect(abs(up.y - (1170 - 210 - 21)) < 0.01)
    }
}
