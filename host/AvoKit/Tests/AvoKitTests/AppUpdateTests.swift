import Foundation
import Testing
@testable import AvoKit

@Suite struct AppUpdateTests {
    private let key = "W/SKL81r8nkZRC+f1CYNMK2uhNWWWbRmHhHFarxIG9M="

    @Test func aBuildUpdatesItselfOnlyWithARealFeedAndAKey() {
        let feed = "https://avo.example.dev/updates/appcast.xml"
        #expect(AppUpdate.readiness(feedURL: feed, publicKey: key) == .ready(feed: URL(string: feed)!))
        #expect(AppUpdate.readiness(feedURL: nil, publicKey: key) == .noFeed)
        #expect(AppUpdate.readiness(feedURL: "  ", publicKey: key) == .noFeed)
        #expect(AppUpdate.readiness(feedURL: "http://avo.example.dev/appcast.xml", publicKey: key) == .noFeed, "https only")
        #expect(AppUpdate.readiness(feedURL: "$(AVO_UPDATE_FEED_URL)", publicKey: key) == .noFeed, "an unexpanded build setting")
    }

    @Test func thePlaceholderFeedIsNoFeed() {
        // Info.plist's placeholder (docs/releasing.md) and the example domains.
        for feed in ["https://updates.avo.invalid/appcast.xml", "https://invalid/appcast.xml",
                     "https://example.com/appcast.xml", "https://updates.example.org/appcast.xml", "https://avo.example/a.xml"] {
            #expect(AppUpdate.readiness(feedURL: feed, publicKey: key) == .placeholderFeed, "\(feed)")
        }
    }

    @Test func theKeyMustBeAnEd25519PublicKey() {
        let feed = "https://avo.example.dev/appcast.xml"
        // Sparkle refuses to start with an empty or malformed key.
        #expect(AppUpdate.readiness(feedURL: feed, publicKey: nil) == .invalidKey)
        #expect(AppUpdate.readiness(feedURL: feed, publicKey: "") == .invalidKey)
        #expect(AppUpdate.readiness(feedURL: feed, publicKey: "not base64!") == .invalidKey)
        #expect(AppUpdate.readiness(feedURL: feed, publicKey: Data(count: 16).base64EncodedString()) == .invalidKey)
    }

    @Test func androidIsNeverTakenAwayForAnUpdate() {
        #expect(AppUpdate.daemonDecision(running: nil, expected: "b", androidRunning: false) == .current, "none runs")
        #expect(AppUpdate.daemonDecision(running: "b", expected: "b", androidRunning: true) == .current)
        #expect(AppUpdate.daemonDecision(running: "a", expected: nil, androidRunning: false) == .current, "cannot tell")
        #expect(AppUpdate.daemonDecision(running: "a", expected: "b", androidRunning: false) == .restartNow)
        #expect(AppUpdate.daemonDecision(running: "a", expected: "b", androidRunning: true) == .waitForAndroid)
        // A daemon from before builds were in its hello is an older build too.
        let expected = AppUpdate.daemonVersion(short: "0.2.0", build: "42", code: "1a2b3c4d5e6f7a8b9c0d")
        #expect(expected == "avo-host 0.2.0 (42) 1a2b3c4d5e6f")
        #expect(AppUpdate.daemonVersion(short: "0.2.0", build: nil, code: nil) == "avo-host 0.2.0")
        // A rebuild that kept the build number is another daemon too.
        let rebuilt = AppUpdate.daemonVersion(short: "0.2.0", build: "42", code: "ffff")
        #expect(AppUpdate.daemonDecision(running: rebuilt, expected: expected, androidRunning: true) == .waitForAndroid)
        #expect(AppUpdate.daemonDecision(running: "avo-host 0.1.0", expected: expected, androidRunning: false) == .restartNow)
    }

    @Test func theDaemonRestartsOnANewBuildOnceAndroidHoldsNothing() {
        #expect(AppUpdate.daemonShouldRestart(launchBuild: "41", diskBuild: "42", state: .stopped))
        #expect(AppUpdate.daemonShouldRestart(launchBuild: "41", diskBuild: "42", state: .notInstalled))
        #expect(AppUpdate.daemonShouldRestart(launchBuild: "41", diskBuild: "42", state: .failed))
        for state in [VMState.starting, .running, .suspending, .suspended, .stopping] {
            #expect(!AppUpdate.daemonShouldRestart(launchBuild: "41", diskBuild: "42", state: state), "\(state)")
        }
        #expect(!AppUpdate.daemonShouldRestart(launchBuild: "42", diskBuild: "42", state: .stopped), "the same build")
        #expect(!AppUpdate.daemonShouldRestart(launchBuild: "41", diskBuild: nil, state: .stopped), "Avo.app is mid-swap")
        // Not 0: launchd starts the daemon again only after a failure (KeepAlive: SuccessfulExit = false).
        #expect(AppUpdate.daemonRestartExitStatus != 0)
    }
}
