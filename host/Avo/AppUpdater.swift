import AppKit
import AvoKit
import os
import Sparkle

/// Avo's own updates, with Sparkle 2 (docs/releasing.md). The appcast at
/// Info.plist's SUFeedURL lists the releases; each archive carries an EdDSA
/// signature that the key in SUPublicEDKey checks. That signature is what
/// Sparkle trusts while Avo is signed ad hoc (an ad hoc signature names
/// one build's code and never matches the next), so every release must be
/// signed with the same key, which lives in the release Mac's login
/// Keychain.
///
/// Sparkle swaps Avo.app when the Control Panel quits or relaunches.
/// Android is never stopped for that without the player's say: before
/// Install and Relaunch, a running Android is offered a stop first. The
/// daemon notices the new build by itself and restarts on it once Android
/// holds nothing (AvoDaemon/AppUpdateWatcher.swift); the Control Panel does
/// the same for a daemon left from before (ControlPanelModel.checkDaemonBuild).
/// Shims made from the old build's template are made again
/// (ShortcutManager.madeForAnotherAvo).
@MainActor @Observable
final class AppUpdater: NSObject {
    /// Whether this build can update itself: a real feed and a valid key.
    let readiness: AppUpdate.Readiness
    private(set) var canCheckForUpdates = false
    /// Settings › About's switch (Sparkle keeps it in Avo's defaults).
    private(set) var automaticallyChecks = false
    private(set) var lastCheck: Date?
    /// Asked whether Android runs, and to stop it, before an install.
    @ObservationIgnored weak var model: ControlPanelModel?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Updates")
    private static let feedOverrideKey = "AvoUpdateFeedURL"

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        // `defaults write dev.avo.Avo AvoUpdateFeedURL https://…` tries a staging feed (docs/releasing.md).
        let feed = UserDefaults.standard.string(forKey: Self.feedOverrideKey) ?? info["SUFeedURL"] as? String
        readiness = AppUpdate.readiness(feedURL: feed, publicKey: info["SUPublicEDKey"] as? String)
        super.init()
        guard case .ready(let feed) = readiness else {
            // Sparkle is not started at all: no checks, no alerts about a feed that does not exist.
            logger.notice("updates are not set up in this build: \(String(describing: self.readiness), privacy: .public)")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            logger.notice("checking for updates at \(feed.absoluteString, privacy: .public)")
        } catch {
            logger.error("the updater did not start: \(error.localizedDescription, privacy: .public)")
        }
        // KVO-compliant in Sparkle; changed on the main thread.
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        refresh()
    }

    /// Avo › Check for Updates…, Settings › About and the menu bar item's.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        refresh()
    }

    func refresh() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        lastCheck = updater.lastUpdateCheckDate
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// The feed checked: a staging override, else Info.plist's.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard case .ready(let feed) = readiness else { return nil }
        return feed.absoluteString
    }

    /// Before Install and Relaunch: a running Android is stopped first if
    /// the player says so (the update swaps the code under it otherwise; it
    /// goes on running the old build until it stops, then the daemon restarts
    /// on the new one).
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model, model.status.state.holdsAndroid else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Stop Android before installing Avo \(item.displayVersionString)?")
        alert.informativeText = String(localized: "Android and its app windows run on the version of Avo you have now. Stop Android first to install cleanly (save your progress in open games), or install now and restart Android later: until then it keeps running as it is.")
        alert.addButton(withTitle: String(localized: "Stop Android and Install"))
        alert.addButton(withTitle: String(localized: "Install Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                if await model.stopAndroidForUpdate() {
                    installHandler()
                } else {
                    self.logger.error("Android did not stop for the update; it installs when Avo quits")
                }
            }
        case .alertSecondButtonReturn:
            installHandler()
        default:
            // Sparkle installs it when Avo quits.
            logger.notice("update \(item.displayVersionString, privacy: .public) waits for Avo to quit")
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        refresh()
    }
}
