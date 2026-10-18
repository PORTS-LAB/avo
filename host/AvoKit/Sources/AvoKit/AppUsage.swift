import Foundation

/// How much one app was used, as the daemon measures it from the app's
/// windows (AvoDaemonCore's AppUsageRecorder): the time a window of the app
/// was on screen, the sessions that time came in, the frames Android drew
/// for those windows, and when the app was last opened. Kept per local
/// calendar day for the last `AppUsage.keptDays` days, in
/// `AvoPaths.usage`; the Control Panel's Library shows it per week.
///
/// "On screen" is what the window tells the daemon (`setDisplayVisible`): a
/// window that is open and not minimized, fully covered or on another Space.
public struct AppUsage: Codable, Equatable, Sendable, Identifiable {
    /// One local calendar day.
    public struct Day: Codable, Equatable, Sendable {
        /// "2026-10-18" in the calendar the daemon ran with.
        public var date: String
        public var foregroundSeconds: Double
        /// Sessions that started this day.
        public var sessions: Int
        /// Frames Android drew for the app's windows while one was on screen.
        public var frames: Int

        public init(date: String, foregroundSeconds: Double = 0, sessions: Int = 0, frames: Int = 0) {
            self.date = date
            self.foregroundSeconds = foregroundSeconds
            self.sessions = sessions
            self.frames = frames
        }
    }

    /// Days kept, so a month (and the week before it) can always be shown.
    public static let keptDays = 120
    /// Back on screen within this long after its windows went away, the app
    /// continues its session (a look at another app, a minimized window).
    public static let sessionGap: TimeInterval = 5 * 60

    public var package: String
    /// Oldest first, only days with something in them.
    public var days: [Day]
    /// When a window of the app last opened.
    public var lastOpened: Date?
    /// When a window of the app was last on screen (while one is: when that began).
    public var lastActive: Date?
    /// While a window of the app is on screen: since when. Nil otherwise.
    public var foregroundSince: Date?
    /// How far the time on screen is in `days`; while the app is on screen,
    /// the time after it is still to be added (`week` adds it).
    public var accountedUntil: Date?

    public var id: String { package }

    public init(package: String, days: [Day] = [], lastOpened: Date? = nil, lastActive: Date? = nil,
                foregroundSince: Date? = nil, accountedUntil: Date? = nil) {
        self.package = package
        self.days = days
        self.lastOpened = lastOpened
        self.lastActive = lastActive
        self.foregroundSince = foregroundSince
        self.accountedUntil = accountedUntil
    }

    /// A window of the app is on screen now.
    public var isOnScreen: Bool { foregroundSince != nil }

    /// When the app was last used: `now` while a window is on screen.
    public func lastUsed(now: Date = Date()) -> Date? {
        isOnScreen ? now : (lastActive ?? lastOpened)
    }

    /// All the time on screen kept, with the part not yet accounted up to `now`.
    public func totalSeconds(now: Date = Date()) -> Double {
        days.reduce(0) { $0 + $1.foregroundSeconds } + pendingSeconds(now: now)
    }

    /// Time on screen after `accountedUntil`, while a window is on screen.
    func pendingSeconds(now: Date) -> Double {
        guard isOnScreen, let from = accountedUntil ?? foregroundSince else { return 0 }
        return max(0, now.timeIntervalSince(from))
    }

    /// The week of `calendar` (from its first weekday) that contains `date`.
    /// While the app is on screen, the time not yet accounted up to `now` is
    /// added to the days it falls on.
    public func week(containing date: Date, now: Date = Date(), calendar: Calendar = .current) -> UsageWeek {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        var stored: [String: Day] = [:]
        for day in days { stored[day.date] = day }
        var result: [UsageWeek.Day] = []
        for offset in 0..<7 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let key = Self.dayKey(dayStart, calendar: calendar)
            let day = stored[key] ?? Day(date: key)
            result.append(UsageWeek.Day(start: dayStart, seconds: day.foregroundSeconds, sessions: day.sessions, frames: day.frames))
        }
        // The stretch on screen that is not in `days` yet.
        if pendingSeconds(now: now) > 0, let from = accountedUntil ?? foregroundSince {
            for (start, seconds) in Self.split(from: from, to: now, calendar: calendar) {
                if let index = result.firstIndex(where: { $0.start == start }) { result[index].seconds += seconds }
            }
        }
        return UsageWeek(days: result)
    }

    // MARK: Days

    /// "2026-10-18": the calendar day of `date`.
    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of the day a key names, in `calendar`.
    public static func date(ofDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// `from..<to` cut at midnights: (start of each day, seconds in it).
    public static func split(from: Date, to: Date, calendar: Calendar) -> [(day: Date, seconds: Double)] {
        var parts: [(Date, Double)] = []
        var cursor = from
        while cursor < to {
            let day = calendar.startOfDay(for: cursor)
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? to
            let end = min(next, to)
            // A day that does not move forward (a calendar quirk) ends the loop.
            guard end > cursor else { break }
            parts.append((day, end.timeIntervalSince(cursor)))
            cursor = end
        }
        return parts
    }
}

/// One week of an app's use, a day at a time (`AppUsage.week(containing:)`).
public struct UsageWeek: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        /// Local midnight.
        public var start: Date
        public var seconds: Double
        public var sessions: Int
        public var frames: Int

        public var id: Date { start }

        public init(start: Date, seconds: Double, sessions: Int, frames: Int) {
            self.start = start
            self.seconds = seconds
            self.sessions = sessions
            self.frames = frames
        }
    }

    /// Seven days from the calendar's first weekday.
    public var days: [Day]

    public init(days: [Day]) {
        self.days = days
    }

    public var seconds: Double { days.reduce(0) { $0 + $1.seconds } }
    public var sessions: Int { days.reduce(0) { $0 + $1.sessions } }
    public var frames: Int { days.reduce(0) { $0 + $1.frames } }

    /// Frames Android drew per second on screen, once the week has a minute
    /// on screen with frames counted.
    public var averageFPS: Double? {
        let counted = days.filter { $0.frames > 0 }
        let seconds = counted.reduce(0) { $0 + $1.seconds }
        guard seconds >= 60 else { return nil }
        return Double(counted.reduce(0) { $0 + $1.frames }) / seconds
    }

    /// Time on screen per session started this week.
    public var secondsPerSession: Double? {
        sessions > 0 ? seconds / Double(sessions) : nil
    }

    /// This week against `previous` as a fraction (0.38 is 38% more); nil
    /// when the earlier week had no time to compare with.
    public func change(from previous: UsageWeek) -> Double? {
        guard previous.seconds >= 60 else { return nil }
        return (seconds - previous.seconds) / previous.seconds
    }

    /// The day with the most time (the latest of equal ones); nil for an empty week.
    public var busiestDay: Day? {
        days.filter { $0.seconds > 0 }.max { $0.seconds < $1.seconds || ($0.seconds == $1.seconds && $0.start < $1.start) }
    }
}

extension AvoPaths {
    /// The daemon's record of how much each app was used (`[AppUsage]`).
    public var usage: URL { applicationSupport.appending(path: "usage.json") }
}
