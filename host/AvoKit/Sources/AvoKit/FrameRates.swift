import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// How a Mac screen refreshes (NSScreen), for Android's display rates.
public struct ScreenRefresh: Equatable, Sendable {
    public var maximumFramesPerSecond: Int
    /// The shortest and longest time a frame may stay on screen: equal on a
    /// fixed-rate screen, a range on one that adapts (ProMotion, Adaptive-Sync).
    public var minimumInterval: Double
    public var maximumInterval: Double

    public init(maximumFramesPerSecond: Int, minimumInterval: Double? = nil, maximumInterval: Double? = nil) {
        self.maximumFramesPerSecond = maximumFramesPerSecond
        let fixed = 1 / Double(max(maximumFramesPerSecond, 1))
        self.minimumInterval = minimumInterval ?? fixed
        self.maximumInterval = maximumInterval ?? fixed
    }

    public static let standard = ScreenRefresh(maximumFramesPerSecond: 60)

    /// The refresh adapts to the content (within its range).
    public var isVariable: Bool { maximumInterval - minimumInterval > 0.0005 }

    /// Whether Android frames at `rate` Hz reach this screen evenly: it
    /// refreshes at a multiple of the rate, or adapts down to it. 60 Hz
    /// always counts (Android's displays ran at nothing else), and so does
    /// 120 under a faster screen (144 Hz): Android goes no higher.
    public func shows(_ rate: Int) -> Bool {
        if rate <= FrameRates.standardRate { return true }
        // 119.88 Hz screens say 120; a little slack for those that say 119.
        guard maximumFramesPerSecond + 1 >= rate else { return false }
        if maximumFramesPerSecond % rate <= 1 || maximumFramesPerSecond % rate >= rate - 1 { return true }
        let interval = 1 / Double(rate)
        if isVariable, minimumInterval <= interval + 0.0002, maximumInterval >= interval - 0.0002 { return true }
        return rate == FrameRates.maximumRate && maximumFramesPerSecond > FrameRates.maximumRate + 1
    }

    /// The screen's own rate as a cap of its own, so Android can run in step
    /// with it: a rate between 60 and 120 that is none of `VMConfig.fpsChoices`
    /// (75 or 100 Hz; nil for 60, 90, 119.88, 120 and 144 Hz screens).
    public var ownRate: Int? {
        let rate = maximumFramesPerSecond
        guard rate > FrameRates.standardRate, rate < FrameRates.maximumRate,
              !VMConfig.fpsChoices.contains(where: { abs($0 - rate) <= 1 }) else { return nil }
        return rate
    }
}

/// Android's refresh rates on a Mac. Every Android display runs at one rate
/// per boot (their EDIDs, engine/hvf/vmm/src/virtio/gpu/edid.rs): the frame
/// rate cap when it is above 60, else 60. Android paces displays of
/// different rates unevenly, and its own display (display 0) cannot change
/// rate while it runs. A lower cap is a render rate (`peak_refresh_rate`),
/// live when it divides the display rate. Every cap is offered whatever the
/// Mac's screens show (`screenNote` says what they make of it), and so is
/// the own rate of each screen between 60 and 120 (75 Hz).
public enum FrameRates {
    public static let standardRate = 60
    /// The fastest Android's displays run.
    public static let maximumRate = 120

    /// The frame rate caps to offer: `VMConfig.fpsChoices`, the own rate of
    /// each of `screens` (`ScreenRefresh.ownRate`), and `saved`, the cap
    /// now, which stays a choice after its screen went away.
    public static func choices(for screens: [ScreenRefresh], keeping saved: Int? = nil) -> [Int] {
        var rates = Set(VMConfig.fpsChoices).union(screens.compactMap(\.ownRate))
        if let saved, VMConfig.isSupportedFPS(saved) { rates.insert(saved) }
        return rates.sorted()
    }

    /// Android's display rate for a boot (avo-vmm `--refresh-rate`, and every
    /// app display): the cap above 60, else 60 (30 is a render rate of it).
    public static func androidRate(cap: Int) -> Int {
        min(max(cap, standardRate), maximumRate)
    }

    /// Whether Android, running at `running` Hz, takes `cap` exactly as a
    /// render rate (a divisor of the display rate, at most that rate).
    public static func appliesLive(cap: Int, running: Int) -> Bool {
        cap > 0 && cap <= running && running % cap == 0
    }

    /// The cap takes a restart of Android: it is not a render rate of the
    /// running rate, and a start would pick another display rate for it.
    public static func needsRestart(cap: Int, running: Int) -> Bool {
        !appliesLive(cap: cap, running: running) && androidRate(cap: cap) != running
    }

    /// How a window presents Android's frames (`presentPacing`).
    public struct PresentPacing: Equatable, Sendable {
        /// The refresh to ask the screen for: Android's rate, or the
        /// screen's own when that is lower (75 for 120 on a 75 Hz screen).
        public var rate: Int
        /// Android's frames come faster than the screen refreshes: the
        /// newest is drawn once a refresh, so frames replace each other
        /// instead of queueing up behind the screen with their latency.
        public var newestPerRefresh: Bool

        public init(rate: Int, newestPerRefresh: Bool) {
            self.rate = rate
            self.newestPerRefresh = newestPerRefresh
        }
    }

    /// How a window presents Android's frames once they arrive faster than
    /// 60 a second (`arrivals`; nil: as they come, the screen doing as it likes).
    public static func presentPacing(arrivals: Double, cap: Int, screen: ScreenRefresh?) -> PresentPacing? {
        guard arrivals > Double(standardRate) + 3 else { return nil }
        let screenRate = (screen ?? .standard).maximumFramesPerSecond
        let pacing = PresentPacing(rate: min(androidRate(cap: cap), screenRate), newestPerRefresh: arrivals > Double(screenRate) + 3)
        return pacing.rate > standardRate || pacing.newestPerRefresh ? pacing : nil
    }

    /// What `screens` make of a cap that none of them shows evenly (nil when
    /// one does, for 60 and under, and without a screen): a screen slower
    /// than Android shows the newest frame at each of its refreshes, and a
    /// faster one out of step with them judders.
    public static func screenNote(cap: Int, screens: [ScreenRefresh]) -> String? {
        let rate = androidRate(cap: cap)
        guard cap > standardRate, let fastest = screens.map(\.maximumFramesPerSecond).max(),
              !screens.contains(where: { $0.shows(rate) }) else { return nil }
        if fastest < rate {
            return screens.count == 1
                ? String(localized: "This Mac’s screen shows up to \(fastest) Hz. Android runs at \(rate) fps; the window shows \(fastest) of them. Games respond a little faster; Android uses a bit more power.",
                         bundle: .avoKit)
                : String(localized: "This Mac’s screens show up to \(fastest) Hz. Android runs at \(rate) fps; windows show up to \(fastest) of them. Games respond a little faster; Android uses a bit more power.",
                         bundle: .avoKit)
        }
        return screens.count == 1
            ? String(localized: "This Mac’s screen refreshes at \(fastest) Hz, out of step with \(rate) fps, so motion can judder a little.",
                     bundle: .avoKit)
            : String(localized: "No screen of this Mac refreshes in step with \(rate) fps, so motion can judder a little.", bundle: .avoKit)
    }
}

#if canImport(AppKit)
extension ScreenRefresh {
    @MainActor public init(_ screen: NSScreen) {
        self.init(maximumFramesPerSecond: screen.maximumFramesPerSecond,
                  minimumInterval: screen.minimumRefreshInterval, maximumInterval: screen.maximumRefreshInterval)
    }

    /// Every screen of the Mac now.
    @MainActor public static var attached: [ScreenRefresh] { NSScreen.screens.map(ScreenRefresh.init) }
}
#endif
