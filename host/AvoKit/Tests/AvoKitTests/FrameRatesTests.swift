import Foundation
import Testing
@testable import AvoKit

/// The frame rate caps a Mac offers, the rate Android's displays run at,
/// and what the Mac's screens make of it.
@Suite struct FrameRatesTests {
    /// This Mac's 1080p monitor: a fixed 75 Hz (74.97).
    private let monitor75 = ScreenRefresh(maximumFramesPerSecond: 75, minimumInterval: 0.013338208, maximumInterval: 0.013338208)
    private let studioDisplay = ScreenRefresh(maximumFramesPerSecond: 60)
    /// ProMotion: up to 120 Hz, down to 24.
    private let proMotion = ScreenRefresh(maximumFramesPerSecond: 120, minimumInterval: 1.0 / 120, maximumInterval: 1.0 / 24)
    private let fixed120 = ScreenRefresh(maximumFramesPerSecond: 120)
    private let fixed144 = ScreenRefresh(maximumFramesPerSecond: 144)
    private let fixed100 = ScreenRefresh(maximumFramesPerSecond: 100)
    private let fixed90 = ScreenRefresh(maximumFramesPerSecond: 90)
    /// Adaptive-Sync from 48 to 144 Hz.
    private let adaptive144 = ScreenRefresh(maximumFramesPerSecond: 144, minimumInterval: 1.0 / 144, maximumInterval: 1.0 / 48)

    @Test func ninetyAndOneTwentyAreAlwaysOffered() {
        for screens in [[], [studioDisplay], [proMotion], [fixed120], [fixed144], [fixed90], [adaptive144], [studioDisplay, fixed144]] {
            #expect(FrameRates.choices(for: screens) == [30, 60, 90, 120], "\(screens.map(\.maximumFramesPerSecond))")
        }
    }

    /// So Android can run in step with it: 75 or 100, not 144 (Android goes
    /// up to 120) nor a rate 1 Hz off a fixed choice (119.88 Hz says 119).
    @Test func aScreensOwnRateBetweenSixtyAndOneTwentyIsAChoice() {
        #expect(FrameRates.choices(for: [monitor75]) == [30, 60, 75, 90, 120])
        #expect(FrameRates.choices(for: [fixed100]) == [30, 60, 90, 100, 120])
        #expect(FrameRates.choices(for: [monitor75, fixed100, studioDisplay, monitor75]) == [30, 60, 75, 90, 100, 120], "each rate once")
        #expect(FrameRates.choices(for: [monitor75, proMotion]) == [30, 60, 75, 90, 120])
        for rate in [59, 60, 61, 89, 91, 119, 121, 144, 240] {
            #expect(ScreenRefresh(maximumFramesPerSecond: rate).ownRate == nil, "\(rate)")
        }
        #expect(ScreenRefresh(maximumFramesPerSecond: 62).ownRate == 62)
        #expect(ScreenRefresh(maximumFramesPerSecond: 118).ownRate == 118)
    }

    /// A saved cap stays what it is: 120 on a 75 Hz screen, and a monitor's
    /// 75 after the monitor was unplugged.
    @Test func aSavedCapIsAChoiceAsItIs() {
        #expect(FrameRates.choices(for: [studioDisplay], keeping: 75) == [30, 60, 75, 90, 120])
        #expect(FrameRates.choices(for: [monitor75], keeping: 120) == [30, 60, 75, 90, 120])
        #expect(FrameRates.choices(for: [monitor75], keeping: 30) == [30, 60, 75, 90, 120])
        #expect(FrameRates.choices(for: [], keeping: 144) == [30, 60, 90, 120], "not a cap Android runs at")
        #expect(FrameRates.choices(for: [], keeping: 45) == [30, 60, 90, 120])
    }

    /// One rate for all of Android, the cap's, whatever the screens show.
    @Test func androidRunsAtTheCap() {
        #expect(FrameRates.androidRate(cap: 60) == 60, "60 Hz stays the default")
        #expect(FrameRates.androidRate(cap: 30) == 60, "30 is a render rate of 60 Hz")
        #expect(FrameRates.androidRate(cap: 75) == 75)
        #expect(FrameRates.androidRate(cap: 90) == 90)
        #expect(FrameRates.androidRate(cap: 120) == 120)
        #expect(FrameRates.androidRate(cap: 144) == 120)
    }

    /// Display 0 keeps its rate while Android runs: a cap that divides it is
    /// a render rate at once; one that needs another rate waits for a restart.
    @Test func capsThatNeedAnotherDisplayRateWaitForARestart() {
        #expect(FrameRates.appliesLive(cap: 60, running: 120))
        #expect(FrameRates.appliesLive(cap: 30, running: 90))
        #expect(!FrameRates.appliesLive(cap: 60, running: 90), "45 is what Android would make of it")
        #expect(!FrameRates.appliesLive(cap: 60, running: 75), "37.5")
        #expect(!FrameRates.appliesLive(cap: 120, running: 60))
        #expect(!FrameRates.needsRestart(cap: 30, running: 60))
        #expect(!FrameRates.needsRestart(cap: 60, running: 120))
        #expect(!FrameRates.needsRestart(cap: 75, running: 75))
        #expect(FrameRates.needsRestart(cap: 120, running: 60), "whatever the screens show")
        #expect(FrameRates.needsRestart(cap: 75, running: 60))
        #expect(FrameRates.needsRestart(cap: 75, running: 120))
        #expect(FrameRates.needsRestart(cap: 90, running: 120))
        #expect(FrameRates.needsRestart(cap: 60, running: 90))
        #expect(FrameRates.needsRestart(cap: 60, running: 75))
        #expect(FrameRates.needsRestart(cap: 30, running: 75), "25 is what Android would make of it")
    }

    /// The window asks its screen for Android's rate, at most the screen's
    /// own, only while Android's frames really come faster than 60 (not at
    /// a render rate of 60, nor before a restart); frames faster than the
    /// screen refreshes are drawn once a refresh, the newest.
    @Test func aWindowAsksForAndroidsRateUpToItsScreens() {
        typealias Pacing = FrameRates.PresentPacing
        #expect(FrameRates.presentPacing(arrivals: 119, cap: 120, screen: proMotion) == Pacing(rate: 120, newestPerRefresh: false))
        #expect(FrameRates.presentPacing(arrivals: 89, cap: 90, screen: proMotion) == Pacing(rate: 90, newestPerRefresh: false))
        #expect(FrameRates.presentPacing(arrivals: 75, cap: 75, screen: proMotion) == Pacing(rate: 75, newestPerRefresh: false),
                "ProMotion adapts to 75")
        #expect(FrameRates.presentPacing(arrivals: 75, cap: 75, screen: monitor75) == Pacing(rate: 75, newestPerRefresh: false),
                "in step: as they come")
        #expect(FrameRates.presentPacing(arrivals: 119, cap: 120, screen: fixed144) == Pacing(rate: 120, newestPerRefresh: false))
        // Never faster than the screen.
        #expect(FrameRates.presentPacing(arrivals: 120, cap: 120, screen: monitor75) == Pacing(rate: 75, newestPerRefresh: true))
        #expect(FrameRates.presentPacing(arrivals: 90, cap: 90, screen: monitor75) == Pacing(rate: 75, newestPerRefresh: true))
        #expect(FrameRates.presentPacing(arrivals: 120, cap: 120, screen: studioDisplay) == Pacing(rate: 60, newestPerRefresh: true))
        #expect(FrameRates.presentPacing(arrivals: 120, cap: 120, screen: nil) == Pacing(rate: 60, newestPerRefresh: true), "no screen yet: 60")
        // At 60 or under: as they come.
        #expect(FrameRates.presentPacing(arrivals: 60, cap: 120, screen: proMotion) == nil)
        #expect(FrameRates.presentPacing(arrivals: 60, cap: 120, screen: monitor75) == nil)
        #expect(FrameRates.presentPacing(arrivals: 0, cap: 120, screen: proMotion) == nil, "a static screen")
        #expect(FrameRates.presentPacing(arrivals: 119, cap: 60, screen: proMotion) == nil)
    }

    @Test func screensShowRatesEvenly() {
        #expect(monitor75.shows(75))
        #expect(!monitor75.shows(90) && !monitor75.shows(120))
        #expect(proMotion.shows(75) && proMotion.shows(90) && proMotion.shows(100) && proMotion.shows(120))
        #expect(fixed120.shows(120) && !fixed120.shows(90) && !fixed120.shows(75))
        #expect(fixed144.shows(120), "the closest Android gets")
        #expect(!fixed144.shows(90) && !fixed144.shows(100))
        #expect(!fixed100.shows(90), "no longer the highest under it: 100 is a choice")
        #expect(fixed100.shows(100))
        #expect(adaptive144.shows(75) && adaptive144.shows(120))
        #expect(ScreenRefresh(maximumFramesPerSecond: 119).shows(120), "119.88 Hz")
        #expect(ScreenRefresh(maximumFramesPerSecond: 150).shows(75))
        #expect(studioDisplay.shows(60) && monitor75.shows(60) && monitor75.shows(30))
    }

    /// The note under each frame rate cap control: only when no screen
    /// shows the cap evenly.
    @Test func aNoteSaysWhatTheScreensMakeOfTheCap() throws {
        let slower = try #require(FrameRates.screenNote(cap: 120, screens: [monitor75]))
        #expect(slower == "This Mac’s screen shows up to 75 Hz. Android runs at 120 fps; the window shows 75 of them. Games respond a little faster; Android uses a bit more power.")
        #expect(FrameRates.screenNote(cap: 90, screens: [monitor75])?.contains("Android runs at 90 fps; the window shows 75 of them") == true)
        #expect(FrameRates.screenNote(cap: 75, screens: [studioDisplay])?.contains("shows up to 60 Hz. Android runs at 75 fps") == true,
                "a monitor's rate saved before it was unplugged")
        let several = try #require(FrameRates.screenNote(cap: 120, screens: [studioDisplay, monitor75]))
        #expect(several.hasPrefix("This Mac’s screens show up to 75 Hz. Android runs at 120 fps; windows show up to 75 of them."))

        #expect(FrameRates.screenNote(cap: 90, screens: [fixed120])
                == "This Mac’s screen refreshes at 120 Hz, out of step with 90 fps, so motion can judder a little.")
        #expect(FrameRates.screenNote(cap: 90, screens: [fixed120, monitor75])
                == "No screen of this Mac refreshes in step with 90 fps, so motion can judder a little.")

        // Shown evenly somewhere: nothing to say.
        #expect(FrameRates.screenNote(cap: 75, screens: [monitor75]) == nil)
        #expect(FrameRates.screenNote(cap: 120, screens: [monitor75, proMotion]) == nil)
        #expect(FrameRates.screenNote(cap: 120, screens: [fixed144]) == nil)
        #expect(FrameRates.screenNote(cap: 90, screens: [adaptive144]) == nil)
        #expect(FrameRates.screenNote(cap: 60, screens: [monitor75]) == nil)
        #expect(FrameRates.screenNote(cap: 30, screens: [studioDisplay]) == nil)
        #expect(FrameRates.screenNote(cap: 120, screens: []) == nil, "no screen to speak of")
    }

    @Test func screensReportVariableRefresh() {
        #expect(proMotion.isVariable)
        #expect(!monitor75.isVariable)
        #expect(!ScreenRefresh.standard.isVariable)
    }
}
