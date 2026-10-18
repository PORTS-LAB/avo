import AvoKit
import Foundation
import os

/// App usage statistics (AvoKit's `AppUsage`), recorded from what the daemon
/// sees of each app's windows: a shim opening a display (`openDisplay`), the
/// window going on or off screen (`setDisplayVisible`: minimized, fully
/// covered, another Space), Android's frames for it (`enginePresent`), and
/// the display closing (the window, Android ending the task, the shim
/// quitting, Android stopping).
///
/// An app is on screen while any of its windows is; time on screen goes to
/// the local day it falls on (cut at midnight). Coming back within
/// `AppUsage.sessionGap` continues the session. DaemonCore owns one and calls
/// it on its actor; the file `AvoPaths.usage` survives daemon restarts.
struct AppUsageRecorder {
    private struct Window {
        let package: String
        var visible: Bool
        /// Frames since the app's time was last accounted.
        var frames = 0
    }

    private(set) var usage: [String: AppUsage] = [:]
    private var windows: [UInt32: Window] = [:]
    private let url: URL?
    private let calendar: Calendar
    /// Something changed since the file was written.
    private(set) var unsaved = false
    /// When on-screen time was last moved into `usage` and published.
    private(set) var lastFlush: Date?
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Usage")

    /// Reads `url`. An app that was on screen when the daemon went away
    /// keeps the time accounted until then; its session ends there.
    init(url: URL?, calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do {
            for var record in try AvoXPC.decode([AppUsage].self, from: data) {
                if record.foregroundSince != nil {
                    record.lastActive = record.accountedUntil ?? record.foregroundSince
                    record.foregroundSince = nil
                    record.accountedUntil = nil
                }
                usage[record.package] = record
            }
        } catch {
            logger.error("ignoring \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every app's record, by package.
    var all: [AppUsage] { usage.values.sorted { $0.package < $1.package } }

    /// An app is on screen.
    var anyOnScreen: Bool { windows.values.contains { $0.visible } }

    // MARK: Window events

    /// A shim opened a window (it starts on screen).
    mutating func opened(display: UInt32, package: String, at now: Date) {
        windows[display] = Window(package: package, visible: true)
        usage[package, default: AppUsage(package: package)].lastOpened = now
        unsaved = true
        update(package, at: now)
    }

    mutating func visibility(display: UInt32, visible: Bool, at now: Date) {
        guard let window = windows[display], window.visible != visible else { return }
        // Frames drawn before it went away count for the time before.
        if !visible { account(window.package, at: now) }
        windows[display]?.visible = visible
        update(window.package, at: now)
    }

    mutating func closed(display: UInt32, at now: Date) {
        guard let window = windows[display] else { return }
        account(window.package, at: now)
        windows[display] = nil
        update(window.package, at: now)
    }

    /// Android stopped: every window is gone.
    mutating func closedAll(at now: Date) {
        for display in Array(windows.keys) { closed(display: display, at: now) }
    }

    /// One frame Android drew for `display`; counted while it is on screen.
    mutating func framePresented(display: UInt32) {
        guard windows[display]?.visible == true else { return }
        windows[display]?.frames += 1
    }

    /// The app is uninstalled (or Android was reset): its record goes.
    mutating func forget(_ package: String) {
        guard usage.removeValue(forKey: package) != nil else { return }
        unsaved = true
    }

    mutating func forgetAll() {
        guard !usage.isEmpty else { return }
        usage.removeAll()
        unsaved = true
    }

    // MARK: Accounting

    /// Moves every app's time on screen and frames up to `now` into its days,
    /// and drops days older than `AppUsage.keptDays`. Returns whether
    /// anything changed.
    @discardableResult
    mutating func flush(at now: Date) -> Bool {
        lastFlush = now
        for package in Set(windows.values.map(\.package)) { account(package, at: now) }
        prune(now: now)
        return unsaved
    }

    /// Starts or ends the app's time on screen when its windows changed.
    private mutating func update(_ package: String, at now: Date) {
        let onScreen = windows.values.contains { $0.package == package && $0.visible }
        var record = usage[package, default: AppUsage(package: package)]
        if onScreen, record.foregroundSince == nil {
            let continues = record.lastActive.map { now.timeIntervalSince($0) < AppUsage.sessionGap } ?? false
            if !continues { add(to: &record, day: now) { $0.sessions += 1 } }
            record.foregroundSince = now
            record.accountedUntil = now
            record.lastActive = now
            unsaved = true
        } else if !onScreen, record.foregroundSince != nil {
            accountTime(&record, until: now)
            record.foregroundSince = nil
            record.accountedUntil = nil
            record.lastActive = now
            unsaved = true
        }
        usage[package] = record
    }

    /// Adds the time since `accountedUntil` and the frames counted since.
    private mutating func account(_ package: String, at now: Date) {
        guard var record = usage[package] else { return }
        accountTime(&record, until: now)
        var frames = 0
        for (display, window) in windows where window.package == package && window.frames > 0 {
            frames += window.frames
            windows[display]?.frames = 0
        }
        if frames > 0 { add(to: &record, day: now) { $0.frames += frames } }
        usage[package] = record
    }

    private mutating func accountTime(_ record: inout AppUsage, until now: Date) {
        guard record.foregroundSince != nil, let from = record.accountedUntil, now > from else { return }
        for (day, seconds) in AppUsage.split(from: from, to: now, calendar: calendar) {
            add(to: &record, day: day) { $0.foregroundSeconds += seconds }
        }
        record.accountedUntil = now
        unsaved = true
    }

    private mutating func add(to record: inout AppUsage, day date: Date, _ change: (inout AppUsage.Day) -> Void) {
        let key = AppUsage.dayKey(date, calendar: calendar)
        if let index = record.days.lastIndex(where: { $0.date == key }) {
            change(&record.days[index])
        } else {
            var day = AppUsage.Day(date: key)
            change(&day)
            record.days.append(day)
            // Keys sort as dates ("2026-10-18").
            record.days.sort { $0.date < $1.date }
        }
        unsaved = true
    }

    private mutating func prune(now: Date) {
        guard let oldest = calendar.date(byAdding: .day, value: -(AppUsage.keptDays - 1), to: calendar.startOfDay(for: now)) else { return }
        let cutoff = AppUsage.dayKey(oldest, calendar: calendar)
        for (package, record) in usage {
            let kept = record.days.filter { $0.date >= cutoff }
            if kept.count != record.days.count {
                usage[package]?.days = kept
                unsaved = true
            }
        }
    }

    // MARK: File

    /// Writes the records when something changed (atomically).
    mutating func save() {
        guard unsaved, let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(all)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            unsaved = false
        } catch {
            logger.error("cannot save usage: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - DaemonCore

extension DaemonCore {
    /// How often on-screen time is written and sent to Control Panels while
    /// an app is on screen.
    static let usageFlushInterval: TimeInterval = 60

    /// Settings-free statistics for the Control Panel's Library (XPC `appUsage`).
    public func appUsage(client: ClientID) throws -> [AppUsage] {
        guard role(of: client) == .controlPanel else { throw AvoError.unauthorizedCaller }
        usage.flush(at: Date())
        usage.save()
        return usage.all
    }

    func usageWindowOpened(_ display: UInt32, package: String) {
        usage.opened(display: display, package: package, at: Date())
        usageChanged()
    }

    func usageVisibility(_ display: UInt32, visible: Bool) {
        usage.visibility(display: display, visible: visible, at: Date())
        usageChanged()
    }

    func usageWindowClosed(_ display: UInt32) {
        usage.closed(display: display, at: Date())
        usageChanged()
    }

    func usageWindowsClosed() {
        usage.closedAll(at: Date())
        usageChanged()
    }

    func usageForget(_ package: String?) {
        if let package { usage.forget(package) } else { usage.forgetAll() }
        usageChanged()
    }

    /// Called every few seconds: while an app is on screen, its time is
    /// written and published once a minute.
    func usageTick() {
        guard usage.anyOnScreen else { return }
        let now = Date()
        if let last = usage.lastFlush, now.timeIntervalSince(last) < Self.usageFlushInterval { return }
        usageChanged(at: now)
    }

    /// Writes what changed and tells the Control Panels.
    private func usageChanged(at now: Date = Date()) {
        guard usage.flush(at: now) else { return }
        usage.save()
        publishUsage(usage.all)
    }
}
