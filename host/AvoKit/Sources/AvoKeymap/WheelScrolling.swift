import AvoKit
import AvoProtocol
import Foundation

// The mouse wheel in an app window (spec: "scroll" next to trackpad
// gestures). Many Android views ignore ACTION_SCROLL (ViewPager, carousels,
// many Compose, Flutter, React Native and custom views, games, some web
// pages), so a notch may do nothing there, while a touch drag alone would
// lose the wheel's precision where views do support it. Automatic mode sends
// scroll events, watches the content under the pointer, and replays the
// notches as a swipe (WheelSwipe) where nothing scrolled; that app then gets
// swipes for a while. This file is the pure part; DisplayView's
// WheelScrollController samples the screen, runs the finger and sends input.

// MARK: - The setting

/// How the mouse wheel (and the trackpad) scroll Android apps.
public enum ScrollMode: String, CaseIterable, Sendable {
    /// The wheel sends Android scroll events; where an app ignores them a
    /// swipe does it instead, and that app gets swipes for a while. The
    /// trackpad drags a finger.
    case automatic
    /// Android scroll events only, the trackpad's too (with macOS's momentum).
    case mouseWheel
    /// Swipes only: the wheel drags a finger, as the trackpad does.
    case swipe
}

/// Where the scroll mode is kept: an app's own choice in its App Shim's
/// defaults, over the default for every app in the Window Host's defaults,
/// which every App Shim reads (as Translate Into does).
public struct ScrollModeSettings {
    public static let appKey = "AvoScrollMode"
    public static let defaultKey = "AvoScrollModeDefault"

    public let app: UserDefaults
    public let shared: UserDefaults

    public init(app: UserDefaults, shared: UserDefaults) {
        self.app = app
        self.shared = shared
    }

    /// The default for every app: Automatic unless the user chose another.
    public var defaultMode: ScrollMode {
        shared.string(forKey: Self.defaultKey).flatMap(ScrollMode.init(rawValue:)) ?? .automatic
    }

    /// This app's own choice; nil follows the default.
    public var appChoice: ScrollMode? {
        app.string(forKey: Self.appKey).flatMap(ScrollMode.init(rawValue:))
    }

    /// The mode this app uses.
    public var mode: ScrollMode { appChoice ?? defaultMode }

    /// Chooses this app's mode. Choosing the default's mode removes the
    /// app's own choice, so it follows later changes of the default (as an
    /// app's graphics settings keep only what differs from its profile).
    public func setAppMode(_ mode: ScrollMode) {
        if mode == defaultMode {
            app.removeObject(forKey: Self.appKey)
        } else {
            app.set(mode.rawValue, forKey: Self.appKey)
        }
    }

    /// Chooses the default for every app; apps with a choice of their own keep it.
    public func setDefaultMode(_ mode: ScrollMode) {
        if mode == .automatic {
            shared.removeObject(forKey: Self.defaultKey)
        } else {
            shared.set(mode.rawValue, forKey: Self.defaultKey)
        }
    }
}

// MARK: - Notches

public enum WheelNotch {
    /// A wheel event's lines in the content's direction (positive: the
    /// content moves down or to the right, as AppKit's scrolling deltas
    /// say), with Shift turning an up-and-down wheel sideways. macOS does
    /// that itself for some mice; then the event is sideways already.
    public static func lines(deltaX: Double, deltaY: Double, shift: Bool) -> (dx: Double, dy: Double) {
        if shift, deltaX == 0, deltaY != 0 { return (deltaY, 0) }
        return (deltaX, deltaY)
    }

    /// The axis lines scroll along: the larger part.
    public static func axis(dx: Double, dy: Double) -> ScrollAxis {
        abs(dx) > abs(dy) ? .horizontal : .vertical
    }

    /// +1 when the content moves down or right along `axis`, -1 up or left.
    public static func direction(dx: Double, dy: Double, axis: ScrollAxis) -> Int {
        (axis == .vertical ? dy : dx) < 0 ? -1 : 1
    }

    /// Android's scroll event for lines in the content's direction:
    /// AXIS_VSCROLL is positive when the content moves down (the wheel
    /// rolled away from the user), AXIS_HSCROLL when it moves left.
    public static func scrollEvent(displayID: UInt32, x: Double, y: Double, dx: Double, dy: Double) -> ScrollEvent {
        ScrollEvent(displayID: displayID, x: Float(x), y: Float(y), horizontal: Float(-dx), vertical: Float(dy))
    }

    /// Android's own distance for one line of AXIS_SCROLL, in dp
    /// (ViewConfiguration's scroll factor, the list item height).
    public static let androidLineDP = 64.0
}

// MARK: - Learning

/// Automatic mode's memory for one app window: whether a burst of notches
/// goes out as scroll events (watched, and replayed as a swipe when nothing
/// scrolls) or as swipes (the app ignored scroll events); when to try scroll
/// events again; and the places where neither moved anything lately (the end
/// of a list, a picture), which get no swipe for a while.
public struct WheelRoute: Sendable {
    public enum Way: Sendable, Equatable {
        case scrollEvents, swipes
    }

    /// What a watched burst found out.
    public enum Finding: Sendable, Equatable {
        case scrollEventsWork
        case swipesWork
        /// Neither moved the content (the end of a list, a picture, a
        /// button). It says nothing about the app: the way stays.
        case nothingMoved
    }

    /// How the next burst goes out.
    public enum Plan: Sendable, Equatable {
        /// Scroll events, watched; when nothing scrolls a swipe replays
        /// them, unless `fallback` is false (a place where neither worked).
        case scrollEvents(fallback: Bool)
        case swipe
    }

    /// Swipes go on this long before scroll events are tried again, then
    /// twice as long each time the app still ignores them.
    public static let firstRetry: TimeInterval = 30
    public static let longestRetry: TimeInterval = 300
    /// After the screen changed (another screen of the app), scroll events
    /// are tried again, but not sooner than this after the last try.
    public static let retryAfterScreenChange: TimeInterval = 3
    public static let deadSpotLifetime: TimeInterval = 8
    /// How close, as a share of the display along each side, is the same place.
    public static let deadSpotRadius = 0.12

    public private(set) var way = Way.scrollEvents
    public private(set) var retryInterval = firstRetry
    /// When scroll events were last tried, or swipes found to work.
    private var lastTry = -Double.infinity
    private var deadSpots: [DeadSpot] = []

    private struct DeadSpot: Sendable {
        var x: Double
        var y: Double
        var axis: ScrollAxis
        var direction: Int
        var time: TimeInterval
    }

    public init() {}

    /// The plan for a burst that begins at (x, y), a share of the display
    /// (0…1), and moves the content along `axis` in `direction`.
    public mutating func plan(x: Double, y: Double, axis: ScrollAxis, direction: Int, at time: TimeInterval,
                              screenChanged: Bool) -> Plan {
        if screenChanged { deadSpots.removeAll() }
        deadSpots.removeAll { time - $0.time >= Self.deadSpotLifetime }
        let radius = Self.deadSpotRadius
        if deadSpots.contains(where: { $0.axis == axis && $0.direction == direction && abs($0.x - x) <= radius && abs($0.y - y) <= radius }) {
            return .scrollEvents(fallback: false)
        }
        switch way {
        case .scrollEvents:
            return .scrollEvents(fallback: true)
        case .swipes:
            let due = time - lastTry >= retryInterval || (screenChanged && time - lastTry >= Self.retryAfterScreenChange)
            guard due else { return .swipe }
            lastTry = time
            return .scrollEvents(fallback: true)
        }
    }

    /// Whether a screen change would make `plan` try scroll events now: the
    /// window then compares the screen with the one the last swipe left.
    public func wantsScreenCheck(at time: TimeInterval) -> Bool {
        way == .swipes && time - lastTry >= Self.retryAfterScreenChange && time - lastTry < retryInterval
    }

    public mutating func learn(_ finding: Finding, x: Double, y: Double, axis: ScrollAxis, direction: Int, at time: TimeInterval) {
        switch finding {
        case .scrollEventsWork:
            way = .scrollEvents
            retryInterval = Self.firstRetry
        case .swipesWork:
            if way == .swipes {
                // Tried again, and still only swipes work.
                retryInterval = min(retryInterval * 2, Self.longestRetry)
            } else {
                way = .swipes
                retryInterval = Self.firstRetry
            }
            lastTry = time
        case .nothingMoved:
            deadSpots.append(DeadSpot(x: x, y: y, axis: axis, direction: direction, time: time))
        }
    }
}

/// One watched burst in Automatic mode. Its notches went out as scroll
/// events: did the content under the pointer slide their way within
/// `window`? If not, a swipe replays them (WheelSwipe), and whether the
/// content followed that finger says if swipes work.
public struct WheelProbe: Sendable {
    /// How long scroll events get to show on screen: Android draws the
    /// scrolled frame and the window gets it in well under this.
    public static let window: TimeInterval = 0.22

    public enum Stage: Sendable, Equatable {
        /// Waiting for the picture before the first notch goes out.
        case starting
        /// Scroll events went out; the region is watched.
        case scrollEvents
        /// A swipe replays them.
        case swipe
        case finished
    }

    public enum Event: Sendable, Equatable {
        /// The content slid: the app scrolls with scroll events.
        case scrolled
        /// Nothing slid in time: replay what went out (lines in the
        /// content's direction) as a swipe from where the burst began.
        case replay(dx: Double, dy: Double)
        /// Nothing slid, and no swipe follows.
        case nothingMoved
    }

    /// Where the burst began, in display pixels.
    public let x: Double
    public let y: Double
    public let axis: ScrollAxis
    public let direction: Int
    public let fallback: Bool
    public private(set) var stage = Stage.starting
    /// The region before any notch went out.
    public private(set) var before: ScreenSample?
    /// What went out as scroll events, in lines.
    public private(set) var sent = (dx: 0.0, dy: 0.0)
    private var since: TimeInterval = 0
    /// The last look: a slide between two looks counts too, so a scroll
    /// that went further than the region since `before` is not missed.
    private var previous: ScreenSample?

    public init(x: Double, y: Double, axis: ScrollAxis, direction: Int, fallback: Bool) {
        self.x = x
        self.y = y
        self.axis = axis
        self.direction = direction
        self.fallback = fallback
    }

    /// The picture before the first notch goes out; nil when there is no
    /// frame to watch (the probe ends: the burst stays scroll events).
    public mutating func start(with before: ScreenSample?, at time: TimeInterval) {
        guard stage == .starting else { return }
        self.before = before
        since = time
        stage = before == nil ? .finished : .scrollEvents
    }

    public mutating func noteSent(dx: Double, dy: Double) {
        sent.dx += dx
        sent.dy += dy
    }

    /// Whether `sample`, a later look at the region, shows the content
    /// slid this probe's way since the picture before or since the last
    /// look. It only reads, so the window can run it off the main thread
    /// (comparing takes milliseconds in a debug build).
    public func slid(_ sample: ScreenSample) -> Bool {
        guard stage == .scrollEvents, let before else { return false }
        for earlier in [before, previous] {
            guard let earlier, let motion = earlier.motion(to: sample, along: axis, direction: direction),
                  case let .shifted(pixels) = motion, pixels * Double(direction) > 0 else { continue }
            return true
        }
        return false
    }

    /// A later look at the region, and what `slid(_:)` said of it.
    public mutating func look(_ sample: ScreenSample, slid: Bool) -> Event? {
        guard stage == .scrollEvents else { return nil }
        previous = sample
        guard slid else { return nil }
        stage = .finished
        return .scrolled
    }

    /// A later look at the region.
    public mutating func look(_ sample: ScreenSample) -> Event? {
        look(sample, slid: slid(sample))
    }

    public mutating func tick(at time: TimeInterval) -> Event? {
        guard stage == .scrollEvents, time - since >= Self.window else { return nil }
        guard fallback, sent.dx != 0 || sent.dy != 0 else {
            stage = .finished
            return .nothingMoved
        }
        stage = .swipe
        return .replay(dx: sent.dx, dy: sent.dy)
    }

    /// The replaying swipe lifted: whether the content followed its finger.
    public mutating func swipeEnded(followed: Bool) -> WheelRoute.Finding? {
        guard stage == .swipe else { return nil }
        stage = .finished
        return followed ? .swipesWork : .nothingMoved
    }
}

/// Watches the content under the wheel's finger: does it follow the finger
/// (a view scrolls with the swipe), or does nothing slide (a picture, a
/// button, the end of a list, where Android only stretches)? A finger whose
/// content never followed lifts with ACTION_CANCEL, so it clicks nothing.
public struct SwipeWatch: Sendable {
    /// The content must slide at least this part of the finger's way (the
    /// frame on screen lags the finger a little; a stretch moves far less).
    public static let share = 0.2
    /// How long after the finger went down the frames have had time to show
    /// the content following it. Until then nothing is known, and a finger
    /// that lifts (a fast spin's fling) lifts with ACTION_UP.
    public static let patience: TimeInterval = 0.18

    public let axis: ScrollAxis
    /// The region when the finger went down.
    public let before: ScreenSample
    /// When the finger went down.
    public let since: TimeInterval
    public private(set) var followed = false
    /// The last look and where the finger was then: the content's slide
    /// between two looks counts too.
    private var previous: (sample: ScreenSample, displacement: Double)?

    public init(axis: ScrollAxis, before: ScreenSample, since: TimeInterval = 0) {
        self.axis = axis
        self.before = before
        self.since = since
    }

    /// What the finger lifts with at `time` (WheelSwipe.contentFollows):
    /// true once the content followed; false when it did not within
    /// `patience`; nil before then.
    public func verdict(at time: TimeInterval) -> Bool? {
        if followed { return true }
        return time - since >= Self.patience ? false : nil
    }

    /// Whether `sample`, a look at the region while the finger is
    /// `displacement` pixels from where it went down (along the axis), shows
    /// the content following it. It only reads, so the window can run it off
    /// the main thread.
    public func follows(_ sample: ScreenSample, displacement: Double) -> Bool {
        if followed { return true }
        if follows(from: before, to: sample, moved: displacement) { return true }
        guard let previous else { return false }
        return follows(from: previous.sample, to: sample, moved: displacement - previous.displacement)
    }

    /// A look, and what `follows(_:displacement:)` said of it. True once the content followed.
    @discardableResult
    public mutating func look(_ sample: ScreenSample, displacement: Double, follows: Bool) -> Bool {
        previous = (sample, displacement)
        if follows { followed = true }
        return followed
    }

    /// A look at the region while the finger is `displacement` pixels from
    /// where it went down, along the axis. True once the content followed.
    @discardableResult
    public mutating func look(_ sample: ScreenSample, displacement: Double) -> Bool {
        look(sample, displacement: displacement, follows: follows(sample, displacement: displacement))
    }

    /// The content slid the finger's way, by a fair part of how far it moved.
    private func follows(from earlier: ScreenSample, to later: ScreenSample, moved: Double) -> Bool {
        guard moved != 0, let motion = earlier.motion(to: later, along: axis, direction: moved > 0 ? 1 : -1),
              case let .shifted(pixels) = motion else { return false }
        let cell = axis == .vertical ? Double(before.height) / Double(before.rows) : Double(before.width) / Double(before.columns)
        return pixels * moved > 0 && abs(pixels) >= max(2 * cell, Self.share * abs(moved))
    }
}

// MARK: - Bursts

/// Routes the mouse wheel's notches for one window: Android scroll events,
/// the wheel's finger (WheelSwipe), or in Automatic mode scroll events that
/// are watched and replayed as a swipe where the app ignores them. Notches
/// closer together than `burstGap` are one burst, which goes out one way.
/// Pure: the window samples the screen, moves the finger and sends what the
/// commands say, and reports back.
public struct WheelScroller: Sendable {
    /// Notches further apart than this begin a new burst.
    public static let burstGap: TimeInterval = 0.35
    /// The longest wait for the window's answer to a command before the
    /// notches go out as scroll events anyway.
    public static let answerTimeout: TimeInterval = 0.25

    public enum Command: Sendable, Equatable {
        /// An Android scroll event at (x, y) for lines in the content's direction.
        case scroll(x: Double, y: Double, dx: Double, dy: Double)
        /// Lines for the wheel's finger, which goes down at (x, y) if it is up.
        case swipe(x: Double, y: Double, dx: Double, dy: Double)
        /// Sample the region around (x, y) along `axis` (ScrollRegion) and
        /// pass it to `pictureBefore`; the burst's notches wait for it.
        case samplePicture(x: Double, y: Double, axis: ScrollAxis)
        /// Compare the screen with the one the last swipe left and pass the
        /// answer to `screenChecked`; the burst's notches wait for it.
        case checkScreen
    }

    private struct Notch: Sendable {
        var x: Double
        var y: Double
        var dx: Double
        var dy: Double
    }

    private enum Awaiting: Sendable, Equatable {
        case picture, screen
    }

    public private(set) var route = WheelRoute()
    public private(set) var probe: WheelProbe?
    /// Counts the probes, so a look judged off the main thread finds its own.
    public private(set) var probeNumber = 0
    /// How the current burst goes out (Automatic mode).
    public private(set) var burst: WheelRoute.Way?
    private var awaiting: (what: Awaiting, since: TimeInterval)?
    private var waiting: [Notch] = []
    private var lastNotch = -Double.infinity
    /// Where the last swipe of the burst went down, and which way (for a dead spot).
    private var swipeStart: (x: Double, y: Double, axis: ScrollAxis, direction: Int)?
    public private(set) var width: Double
    public private(set) var height: Double

    public init(width: Double, height: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    /// The probe watches the screen (the window samples its region).
    public var isWatching: Bool { probe?.stage == .scrollEvents }

    /// Something waits for time to pass (`tick`).
    public var isBusy: Bool { awaiting != nil || isWatching }

    /// A notch: `dx`, `dy` in lines in the content's direction, at (x, y)
    /// in display pixels. `touches`: a finger may go down now (not while the
    /// key mapping holds the touches or a click, drag or trackpad gesture
    /// does). `fingerDown`: the wheel's finger is down.
    public mutating func notch(dx: Double, dy: Double, x: Double, y: Double, mode: ScrollMode, touches: Bool,
                               fingerDown: Bool, at time: TimeInterval) -> [Command] {
        let notch = Notch(x: x, y: y, dx: dx, dy: dy)
        let gap = time - lastNotch
        lastNotch = time
        guard dx != 0 || dy != 0 else { return [] }
        switch mode {
        case .mouseWheel:
            return [scroll(notch)]
        case .swipe:
            return [touches || fingerDown ? swipe(notch) : scroll(notch)]
        case .automatic:
            break
        }
        if awaiting != nil {
            waiting.append(notch)
            return []
        }
        if fingerDown { return [swipe(notch)] }
        guard touches else { return [scroll(notch)] }
        if var probe, probe.stage == .scrollEvents {
            probe.noteSent(dx: dx, dy: dy)
            self.probe = probe
            return [scroll(notch)]
        }
        if gap < Self.burstGap, let burst {
            return [burst == .swipes ? swipe(notch) : scroll(notch)]
        }
        // A new burst.
        probe = nil
        burst = nil
        waiting = [notch]
        if route.wantsScreenCheck(at: time) {
            awaiting = (.screen, time)
            return [.checkScreen]
        }
        return begin(screenChanged: false, at: time)
    }

    /// The answer to `checkScreen`: whether the screen changed by more than
    /// the last swipe did (another screen of the app).
    public mutating func screenChecked(_ changed: Bool, at time: TimeInterval) -> [Command] {
        guard awaiting?.what == .screen else { return [] }
        awaiting = nil
        return begin(screenChanged: changed, at: time)
    }

    /// The answer to `samplePicture`: the region before the first notch
    /// goes out, or nil when there is no frame. The notches go out now.
    public mutating func pictureBefore(_ sample: ScreenSample?, at time: TimeInterval) -> [Command] {
        guard awaiting?.what == .picture, var probe else { return [] }
        awaiting = nil
        probe.start(with: sample, at: time)
        burst = .scrollEvents
        var commands: [Command] = []
        for notch in waiting {
            probe.noteSent(dx: notch.dx, dy: notch.dy)
            commands.append(scroll(notch))
        }
        waiting = []
        self.probe = probe.stage == .finished ? nil : probe
        return commands
    }

    /// A look at the probe's region (the window samples it while
    /// `isWatching`), judged by `probe.slid(_:)` for probe `number`.
    public mutating func look(_ sample: ScreenSample, slid: Bool, probe number: Int, at time: TimeInterval) {
        guard var probe, number == probeNumber else { return }
        if probe.look(sample, slid: slid) == .scrolled {
            route.learn(.scrollEventsWork, x: probe.x / width, y: probe.y / height, axis: probe.axis,
                        direction: probe.direction, at: time)
            self.probe = nil
            return
        }
        self.probe = probe
    }

    /// A look at the probe's region, judged here.
    public mutating func look(_ sample: ScreenSample, at time: TimeInterval) {
        guard let probe else { return }
        look(sample, slid: probe.slid(sample), probe: probeNumber, at: time)
    }

    public mutating func tick(at time: TimeInterval) -> [Command] {
        if let awaiting, time - awaiting.since >= Self.answerTimeout {
            // No answer: the notches go out as scroll events, unwatched.
            self.awaiting = nil
            probe = nil
            burst = .scrollEvents
            defer { waiting = [] }
            return waiting.map { scroll($0) }
        }
        guard var probe, let event = probe.tick(at: time) else { return [] }
        switch event {
        case let .replay(dx, dy):
            self.probe = probe
            burst = .swipes
            return [swipe(Notch(x: probe.x, y: probe.y, dx: dx, dy: dy))]
        case .nothingMoved:
            route.learn(.nothingMoved, x: probe.x / width, y: probe.y / height, axis: probe.axis,
                        direction: probe.direction, at: time)
            self.probe = nil
        case .scrolled:
            self.probe = nil
        }
        return []
    }

    /// The wheel's finger lifted at the end of a drag, and whether the
    /// content followed it.
    public mutating func swipeEnded(followed: Bool, at time: TimeInterval) {
        if var probe, let finding = probe.swipeEnded(followed: followed) {
            route.learn(finding, x: probe.x / width, y: probe.y / height, axis: probe.axis, direction: probe.direction, at: time)
            self.probe = nil
            return
        }
        // Swipes for an app that needs them, and this one moved nothing:
        // no swipe here for a while.
        if burst == .swipes, !followed, let start = swipeStart {
            route.learn(.nothingMoved, x: start.x / width, y: start.y / height, axis: start.axis, direction: start.direction, at: time)
        }
    }

    /// Ends what is in progress (focus left the window, a click or a
    /// trackpad gesture took the touches); what was learned stays.
    public mutating func cancel() {
        probe = nil
        burst = nil
        awaiting = nil
        waiting = []
        lastNotch = -.infinity
    }

    /// The display changed size.
    public mutating func resize(width: Double, height: Double) {
        cancel()
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    private mutating func begin(screenChanged: Bool, at time: TimeInterval) -> [Command] {
        guard let first = waiting.first else { return [] }
        let axis = WheelNotch.axis(dx: first.dx, dy: first.dy)
        let direction = WheelNotch.direction(dx: first.dx, dy: first.dy, axis: axis)
        switch route.plan(x: first.x / width, y: first.y / height, axis: axis, direction: direction, at: time,
                          screenChanged: screenChanged) {
        case .swipe:
            burst = .swipes
            var commands: [Command] = []
            for notch in waiting { commands.append(swipe(notch)) }
            waiting = []
            return commands
        case let .scrollEvents(fallback):
            probe = WheelProbe(x: first.x, y: first.y, axis: axis, direction: direction, fallback: fallback)
            probeNumber += 1
            awaiting = (.picture, time)
            return [.samplePicture(x: first.x, y: first.y, axis: axis)]
        }
    }

    private func scroll(_ notch: Notch) -> Command {
        .scroll(x: notch.x, y: notch.y, dx: notch.dx, dy: notch.dy)
    }

    private mutating func swipe(_ notch: Notch) -> Command {
        let axis = WheelNotch.axis(dx: notch.dx, dy: notch.dy)
        swipeStart = (notch.x, notch.y, axis, WheelNotch.direction(dx: notch.dx, dy: notch.dy, axis: axis))
        return .swipe(x: notch.x, y: notch.y, dx: notch.dx, dy: notch.dy)
    }
}
