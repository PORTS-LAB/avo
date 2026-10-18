import Foundation

/// Avo's own updates (Sparkle, in the Control Panel; docs/releasing.md):
/// whether this build can update itself, and how the daemon moves over to a
/// new build without stopping Android under the player.
public enum AppUpdate {
    /// Whether this build can update itself.
    public enum Readiness: Equatable, Sendable {
        case ready(feed: URL)
        /// SUFeedURL is missing or empty.
        case noFeed
        /// SUFeedURL is the placeholder of a build no feed was set up for
        /// (a `.invalid` host, which never resolves, or an example domain).
        case placeholderFeed
        /// SUPublicEDKey is not an Ed25519 public key: Sparkle would refuse
        /// to start, and could never check an update's signature.
        case invalidKey
    }

    /// From Info.plist's SUFeedURL and SUPublicEDKey. Updates come only
    /// over https and signed with the key.
    public static func readiness(feedURL: String?, publicKey: String?) -> Readiness {
        guard let text = feedURL?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return .noFeed }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              !host.isEmpty else { return .noFeed }
        let placeholder = host == "invalid" || host.hasSuffix(".invalid") || host.hasSuffix(".example")
            || ["example.com", "example.org", "example.net"].contains { host == $0 || host.hasSuffix(".\($0)") }
        guard !placeholder else { return .placeholderFeed }
        guard let key = publicKey.flatMap({ Data(base64Encoded: $0.trimmingCharacters(in: .whitespaces)) }), key.count == 32 else {
            return .invalidKey
        }
        return .ready(feed: url)
    }

    /// What to do with the daemon that runs, once a new Avo.app is in place
    /// (the Control Panel's launch, DaemonAgent).
    public enum DaemonDecision: Equatable, Sendable {
        /// The daemon that runs is this build's, or none runs (launchd
        /// starts this build's when asked).
        case current
        /// An older build's daemon runs with Android stopped: restart it on this build now.
        case restartNow
        /// An older build's daemon runs Android: leave both running. The
        /// daemon restarts on the new build by itself once Android stops
        /// (AppUpdateWatcher), and the Control Panel offers to restart Android.
        case waitForAndroid
    }

    /// `running` names the build of the daemon that runs (its hello's
    /// `daemonVersion`), `expected` this Avo.app's (`daemonVersion(short:build:)`);
    /// nil when unknown.
    public static func daemonDecision(running: String?, expected: String?, androidRunning: Bool) -> DaemonDecision {
        guard let running, let expected, running != expected else { return .current }
        return androidRunning ? .waitForAndroid : .restartNow
    }

    /// The daemon's own check (AppUpdateWatcher): Avo.app on disk is another
    /// build than the one it started from (an update replaced it), and
    /// Android holds nothing, so it can restart on the new build.
    public static func daemonShouldRestart(launchBuild: String?, diskBuild: String?, state: VMState) -> Bool {
        guard let launchBuild, let diskBuild, launchBuild != diskBuild else { return false }
        return !state.holdsAndroid
    }

    /// How the daemon names its build in its hello (`DaemonHello.daemonVersion`):
    /// "avo-host 0.2.0 (42) 1a2b3c4d5e6f", the version, the build and the
    /// start of its code directory hash. The Control Panel compares it with
    /// the daemon in its own Avo.app, to tell a daemon left over from before
    /// an update (or a rebuild that kept the build number).
    public static func daemonVersion(short: String, build: String?, code: String?) -> String {
        "avo-host \(short)" + (build.map { " (\($0))" } ?? "") + (code.map { " " + $0.prefix(12) } ?? "")
    }

    /// The exit status of a daemon that restarts on a new build: not 0, so
    /// launchd starts it again (KeepAlive: SuccessfulExit = false), which
    /// Quit Avo's 0 does not. EX_TEMPFAIL.
    public static let daemonRestartExitStatus: Int32 = 75
}

extension VMState {
    /// Android runs, starts, stops or is paused: a restart would take it away.
    public var holdsAndroid: Bool {
        switch self {
        case .starting, .running, .suspending, .suspended, .stopping: true
        case .notInstalled, .stopped, .failed: false
        }
    }
}
