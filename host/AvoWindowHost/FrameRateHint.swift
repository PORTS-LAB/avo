import AppKit
import AvoKit
import QuartzCore

/// Paces the window's frames while Android draws above 60 Hz (a 75 or
/// 120 Hz display; FrameRates.presentPacing): a CADisplayLink of the display
/// view, which follows the window to another screen, asks the screen for
/// Android's rate, never for more than the screen refreshes (75 for 120 on
/// a 75 Hz screen), so a ProMotion or adaptive screen does not settle at
/// 60 Hz. Frames are presented as they arrive (MetalRenderer.present),
/// except when they come faster than the screen refreshes: then the link's
/// ticks draw the newest, once a refresh (MetalRenderer.refreshed), and
/// nothing draws faster than the screen shows. It runs only while the cap
/// is above 60, the window is on screen and frames come faster than 60 a
/// second; a check twice a second (only then too) looks at the renderer's
/// frame count.
@MainActor
final class FrameRateHint {
    private weak var view: NSView?
    private let renderer: MetalRenderer
    private var link: CADisplayLink?
    private var check: Timer?
    private var cap = FrameRates.standardRate
    private var onScreen = true
    /// What the link does now; nil while it is paused.
    private(set) var pacing: FrameRates.PresentPacing?

    init(view: NSView, renderer: MetalRenderer) {
        self.view = view
        self.renderer = renderer
    }

    /// Android's frame rate cap (VMConfig.fpsLimit).
    func setCap(_ cap: Int) {
        self.cap = cap
        update()
    }

    /// Hidden windows ask for nothing (MetalRenderer draws nothing for them either).
    func setOnScreen(_ onScreen: Bool) {
        self.onScreen = onScreen
        update()
    }

    func stop() {
        check?.invalidate()
        check = nil
        link?.invalidate()
        link = nil
        pacing = nil
        renderer.setNewestPerRefresh(false)
    }

    private func update() {
        let watching = onScreen && cap > FrameRates.standardRate
        if watching, check == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            check = timer
        } else if !watching {
            check?.invalidate()
            check = nil
        }
        evaluate()
    }

    private func evaluate() {
        let screen = view?.window?.screen.map(ScreenRefresh.init)
        let pacing = check == nil ? nil
            : FrameRates.presentPacing(arrivals: renderer.statistics().framesPerSecond, cap: cap, screen: screen)
        guard pacing != self.pacing else { return }
        self.pacing = pacing
        guard let pacing, let view else {
            link?.isPaused = true
            renderer.setNewestPerRefresh(false)
            return
        }
        let link = self.link ?? {
            let made = view.displayLink(target: RefreshTarget(renderer: renderer), selector: #selector(RefreshTarget.fire))
            made.add(to: .main, forMode: .common)
            self.link = made
            return made
        }()
        let rate = Float(pacing.rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(Float(FrameRates.standardRate), rate), maximum: rate, preferred: rate)
        link.isPaused = false
        // The renderer goes on drawing frames as they come until the first tick.
        renderer.setNewestPerRefresh(pacing.newestPerRefresh)
    }
}

/// CADisplayLink needs an Objective-C target: each refresh of the screen
/// draws the newest frame while frames come faster than it refreshes.
private final class RefreshTarget: NSObject {
    private let renderer: MetalRenderer

    init(renderer: MetalRenderer) {
        self.renderer = renderer
    }

    @objc func fire() {
        renderer.refreshed()
    }
}
