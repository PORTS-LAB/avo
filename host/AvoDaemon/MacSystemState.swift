import AppKit
import AvoDaemonCore
import IOKit.ps

/// The Mac's appearance, time zone, clock, languages and battery, for
/// Android to follow like a phone paired to this Mac (HostAgent applies
/// them; MacState builds the guest commands). Read on the main thread a
/// second after macOS says something changed (one change comes as several
/// notifications), and once a minute for what macOS does not announce;
/// delivered when it differs, and in full whenever Android starts running.
@MainActor
final class MacSystemState: NSObject {
    private let deliver: (MacState) -> Void
    private var running = false
    private var delivered: MacState?
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var appearance: NSKeyValueObservation?
    private var powerSources: CFRunLoopSource?
    private var timer: Timer?

    init(deliver: @escaping (MacState) -> Void) {
        self.deliver = deliver
        super.init()
        // The daemon is never the active app, and AppKit holds distributed
        // notifications back from inactive apps unless asked not to.
        let distributed = DistributedNotificationCenter.default()
        for name in ["AppleInterfaceThemeChangedNotification", "AppleLanguagePreferencesChangedNotification"] {
            distributed.addObserver(self, selector: #selector(macChanged), name: Notification.Name(name), object: nil,
                                    suspensionBehavior: .deliverImmediately)
        }
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
        // Light, dark, or Auto switching between them.
        appearance = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        // Plugged in, unplugged, and every percent.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<MacSystemState>.fromOpaque(context).takeUnretainedValue().changed() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSources = source
        }
    }

    /// Android (re)started or stopped: a fresh Android gets all of it.
    func update(running: Bool) {
        guard running != self.running else { return }
        self.running = running
        delivered = nil
        if running {
            changed(after: .zero)
            // Only while there is an Android to tell: the daemon always runs.
            let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(after: .zero) }
            }
            timer.tolerance = 10
            self.timer = timer
        } else {
            pending?.cancel()
            timer?.invalidate()
            timer = nil
        }
    }

    @objc nonisolated private func macChanged() {
        Task { @MainActor in self.changed() }
    }

    private func changed(after delay: Duration = .seconds(1)) {
        guard running else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        guard running else { return }
        let state = Self.current()
        guard state != delivered else { return }
        delivered = state
        deliver(state)
    }

    static func current() -> MacState {
        // Foundation keeps the system time zone it first read.
        NSTimeZone.resetSystemTimeZone()
        // The global preferences themselves: Locale caches them until it
        // hears of a change, which a background app may not.
        let defaults = UserDefaults.standard
        let languages = defaults.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        return MacState(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                        timeZone: TimeZone.current.identifier,
                        uses24HourClock: MacState.uses24HourClock(force24Hour: defaults.object(forKey: "AppleICUForce24HourTime") as? Bool,
                                                                  force12Hour: defaults.object(forKey: "AppleICUForce12HourTime") as? Bool,
                                                                  regionDefault: Locale.autoupdatingCurrent.hourCycle),
                        languages: languages,
                        battery: battery())
    }

    /// The internal battery among IOKit's power sources; nil on a desktop Mac.
    static func battery() -> MacBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let battery = MacBattery(powerSource: description) {
                return battery
            }
        }
        return nil
    }
}
