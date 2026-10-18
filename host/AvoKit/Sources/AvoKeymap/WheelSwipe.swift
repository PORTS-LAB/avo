import AvoProtocol
import Foundation

/// The mouse wheel's finger (Swipe mode, and Automatic mode where an app
/// ignores scroll events). The notches of a burst move one finger in one
/// continuous drag:
///
/// - It goes down at the pointer and moves at once, eased towards where the
///   notches so far take it, plus Android's touch slop, which a view
///   swallows before it starts to scroll: no tap and no long press.
/// - Once it gets there and no notch follows, it rests for `rest` and lifts.
///   Android sees no movement in the last 40 ms before the lift, so there is
///   no velocity and no fling: the view stops where the notches put it.
/// - A fast spin (`fastLines` within `fastWindow`) lifts while the finger
///   still moves, so Android flings.
/// - It stays inside the display. It goes down where there is room for the
///   notches that start it; a burst that takes it further rests, lifts and
///   goes down again where it began, as a thumb would.
/// - When the window saw that the content did not follow the finger
///   (`contentFollows` false, SwipeWatch) it lifts with ACTION_CANCEL, so it
///   clicks nothing it rested on, and it neither flings nor goes on.
///
/// One pointer, id 0, as DisplayView's own touches: the window never lets it
/// overlap a click, a trackpad drag or the key mapping's touches.
public struct WheelSwipe: Sendable {
    /// Sizes in display pixels for one display.
    public struct Metrics: Sendable, Equatable {
        /// One wheel line up and down: about three list items.
        public static let lineDP = 160.0
        /// One wheel line sideways, as a share of the display's width: past
        /// the point where a pager (ViewPager, a Compose pager) turns the page.
        public static let sidewaysShare = 0.66
        /// Android's touch slop (ViewConfiguration).
        public static let slopDP = 8.0
        public static let marginDP = 16.0
        public static let maxSpeedDP = 4000.0

        public var lineX: Double
        public var lineY: Double
        public var slop: Double
        /// The finger keeps this far from the display's edges.
        public var margin: Double
        /// Pixels per second the finger moves at most.
        public var maxSpeed: Double

        /// For a display of `width` × `height` pixels with `density` pixels per dp.
        public init(width: Double, height: Double, density: Double) {
            let density = max(density, 0.5)
            lineY = min(Self.lineDP * density, 0.4 * height)
            lineX = Self.sidewaysShare * width
            slop = Self.slopDP * density
            margin = min(Self.marginDP * density, 0.1 * min(width, height))
            maxSpeed = Self.maxSpeedDP * density
        }
    }

    /// The time constant of the ease towards the target: most of a notch's
    /// way in the first 70 ms, as a smooth scroll goes.
    public static let easing: TimeInterval = 0.035
    /// The finger's rest before it lifts, with no movement: more than
    /// Android's 40 ms after which it takes a pointer for stopped.
    public static let rest: TimeInterval = 0.09
    /// A spin this fast flings: this many lines within `fastWindow`.
    public static let fastLines = 6.0
    public static let fastWindow: TimeInterval = 0.2
    /// A fast spin lifts once no notch came for this long.
    public static let flingGap: TimeInterval = 0.05
    /// Between a lift and going down again for the rest of a burst.
    public static let regrip: TimeInterval = 0.016
    /// Closer to the target than this is there.
    static let arrival = 2.0

    private enum Phase: Sendable, Equatable {
        case up
        case moving
        case resting(since: TimeInterval)
        /// Lifted; goes down again at `start` for the rest of the burst.
        case regripping(until: TimeInterval)
    }

    public let displayID: UInt32
    public let width: Double
    public let height: Double
    public let metrics: Metrics
    /// Whether the content follows the finger, as the window saw it: false
    /// lifts with ACTION_CANCEL; nil (not watched) and true with ACTION_UP.
    /// The window sets it for each drag; it is read when the finger lifts.
    public var contentFollows: Bool?

    private var phase = Phase.up
    /// Where the finger went down, where it is, and where the notches so
    /// far take it (perhaps beyond the display).
    public private(set) var start = (x: 0.0, y: 0.0)
    public private(set) var finger = (x: 0.0, y: 0.0)
    private var target = (x: 0.0, y: 0.0)
    /// The way left for the next drag of the burst, in pixels.
    private var leftover = (x: 0.0, y: 0.0)
    private var lastTick: TimeInterval = 0
    private var lastNotch = -Double.infinity
    private var recent: [(time: TimeInterval, lines: Double)] = []

    public init(displayID: UInt32, width: Double, height: Double, density: Double) {
        self.displayID = displayID
        self.width = max(width, 1)
        self.height = max(height, 1)
        metrics = Metrics(width: self.width, height: self.height, density: density)
    }

    /// The finger is down.
    public var isDown: Bool {
        switch phase {
        case .moving, .resting: true
        case .up, .regripping: false
        }
    }

    /// Down, or about to go down again for the rest of a burst.
    public var isActive: Bool { phase != .up }

    /// How far the finger is from where it went down.
    public var displacement: (dx: Double, dy: Double) { (finger.x - start.x, finger.y - start.y) }

    /// Wheel lines in the content's direction (WheelNotch.lines) at (x, y)
    /// in display pixels: where the finger goes down when it is up.
    public mutating func add(dx: Double, dy: Double, x: Double, y: Double, at time: TimeInterval) -> [TouchEvent] {
        guard dx != 0 || dy != 0 else { return [] }
        recent.append((time, abs(dx) + abs(dy)))
        recent.removeAll { time - $0.time > Self.fastWindow }
        lastNotch = time
        let way = (x: dx * metrics.lineX, y: dy * metrics.lineY)
        switch phase {
        case .moving, .resting:
            target.x += way.x
            target.y += way.y
            phase = .moving
            return []
        case .regripping:
            leftover.x += way.x
            leftover.y += way.y
            return []
        case .up:
            start = (x, y)
            return down(way: way, at: time, fresh: true)
        }
    }

    /// Moves the finger to where it is at `time` (call it every display frame while `isActive`).
    public mutating func tick(at time: TimeInterval) -> [TouchEvent] {
        switch phase {
        case .up:
            return []
        case let .regripping(until):
            guard time >= until else { return [] }
            let way = leftover
            leftover = (0, 0)
            return down(way: way, at: time, fresh: false)
        case let .resting(since):
            guard time - since >= Self.rest else { return [] }
            return lift(regrip: leftover.x != 0 || leftover.y != 0, at: time)
        case .moving:
            return move(at: time)
        }
    }

    /// Lifts at once with ACTION_CANCEL (focus left the window, a click or a
    /// trackpad gesture takes the touches, the display changed): no fling,
    /// no click, and the rest of the burst is dropped.
    public mutating func cancel() -> [TouchEvent] {
        leftover = (0, 0)
        defer { phase = .up }
        return isDown ? [touch(.cancel)] : []
    }

    // MARK: Moving

    /// Goes down at `start` (moved to where the way fits, the first time)
    /// with `way` ahead and the slop on top of it.
    private mutating func down(way: (x: Double, y: Double), at time: TimeInterval, fresh: Bool) -> [TouchEvent] {
        let slop = (x: way.x == 0 ? 0 : way.x < 0 ? -metrics.slop : metrics.slop,
                    y: way.y == 0 ? 0 : way.y < 0 ? -metrics.slop : metrics.slop)
        var point = (x: clamp(start.x, width), y: clamp(start.y, height))
        if fresh {
            point.x = roomy(point.x, way: way.x + slop.x, length: width)
            point.y = roomy(point.y, way: way.y + slop.y, length: height)
        }
        start = point
        finger = point
        target = (point.x + way.x + slop.x, point.y + way.y + slop.y)
        lastTick = time
        phase = .moving
        return [touch(.down)]
    }

    private mutating func move(at time: TimeInterval) -> [TouchEvent] {
        let dt = time - lastTick
        guard dt > 0 else { return [] }
        lastTick = time
        let k = 1 - exp(-dt / Self.easing)
        var step = (x: (target.x - finger.x) * k, y: (target.y - finger.y) * k)
        let length = (step.x * step.x + step.y * step.y).squareRoot()
        let limit = metrics.maxSpeed * dt
        if length > limit, length > 0 {
            step.x *= limit / length
            step.y *= limit / length
        }
        var next = (x: clamp(finger.x + step.x, width), y: clamp(finger.y + step.y, height))
        // Close enough: there.
        if abs(target.x - next.x) <= Self.arrival, abs(target.y - next.y) <= Self.arrival {
            next = (clamp(target.x, width), clamp(target.y, height))
        }
        var events: [TouchEvent] = []
        if next.x != finger.x || next.y != finger.y {
            finger = next
            events.append(touch(.move))
        }
        let left = (x: target.x - finger.x, y: target.y - finger.y)
        let there = abs(left.x) <= Self.arrival && abs(left.y) <= Self.arrival
        // The display's edge holds the finger on every axis it still has a way to go on.
        let blocked = !there && (abs(left.x) <= Self.arrival || atEdge(finger.x, toward: left.x, width))
            && (abs(left.y) <= Self.arrival || atEdge(finger.y, toward: left.y, height))
        let fast = recent.reduce(0) { $0 + (time - $1.time <= Self.fastWindow ? $1.lines : 0) } >= Self.fastLines
        // A fast spin lifts while the finger still moves, once its notches
        // stop or at the edge: Android flings.
        if fast, contentFollows != false, !there, blocked || time - lastNotch >= Self.flingGap {
            return events + lift(regrip: false, at: time)
        }
        if there {
            phase = .resting(since: time)
        } else if blocked {
            // At the edge with more of the way ahead: rest, lift and go down
            // again. A finger the content does not follow goes no further.
            leftover = contentFollows == false ? (0, 0) : left
            phase = .resting(since: time)
        }
        return events
    }

    private func atEdge(_ position: Double, toward way: Double, _ length: Double) -> Bool {
        let low = metrics.margin, high = max(length - 1 - metrics.margin, low)
        return way < 0 ? position <= low : position >= high
    }

    private mutating func lift(regrip: Bool, at time: TimeInterval) -> [TouchEvent] {
        let event = touch(contentFollows == false ? .cancel : .up)
        // A finger the content does not follow does not go down again.
        let regrip = regrip && contentFollows != false
        phase = regrip ? .regripping(until: time + Self.regrip) : .up
        if !regrip { leftover = (0, 0) }
        return [event]
    }

    /// `position` moved back so that `way` (signed) fits before the edge,
    /// as far as the display allows.
    private func roomy(_ position: Double, way: Double, length: Double) -> Double {
        guard way != 0 else { return position }
        let low = metrics.margin, high = max(length - 1 - metrics.margin, low)
        let wanted = min(abs(way), high - low)
        return way > 0 ? min(position, high - wanted) : max(position, low + wanted)
    }

    private func clamp(_ value: Double, _ length: Double) -> Double {
        let low = metrics.margin, high = max(length - 1 - metrics.margin, low)
        return min(max(value, low), high)
    }

    private func touch(_ action: TouchAction) -> TouchEvent {
        TouchEvent(displayID: displayID, action: action,
                   pointers: [TouchPointer(id: 0, x: Float(finger.x), y: Float(finger.y))])
    }
}
