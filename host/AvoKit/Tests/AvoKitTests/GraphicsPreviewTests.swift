import Foundation
import Testing
@testable import AvoKit

// Settings › Graphics › Result: the preview must match what a window does.

@Suite struct GraphicsPreviewTests {
    @Test func appsDefaultIsOneToOne() {
        let preview = GraphicsPreview(contentWidth: 412, contentHeight: 892, backingScale: 2, settings: .appsDefault)
        #expect(preview.request.size == PixelSize(width: 824, height: 1784))
        #expect(preview.screen == PixelSize(width: 824, height: 1784))
        #expect(preview.path == .native)
        #expect(preview.ratio == 1)
        #expect(!preview.shrinks)
    }

    @Test func gamesDefaultWindowUsesMetalFX() {
        let content = DisplaySizing.conformedContentSize(width: 892, height: 412, longOverShort: 16.0 / 9)
        let preview = GraphicsPreview(contentWidth: content.width, contentHeight: content.height, backingScale: 2,
                                      settings: .gamesDefault, landscape: true)
        #expect(preview.request.size == PixelSize(width: 1280, height: 720))
        #expect(preview.screen == PixelSize(width: 1784, height: 1004))
        #expect(preview.path == .metalFX(output: PixelSize(width: 1784, height: 1004)))
        #expect(abs(preview.ratio - 1.39) < 0.01)
        #expect(preview.cappedMetalFXRatio == nil)
    }

    @Test func gamesFullScreenGetsBars() {
        let preview = GraphicsPreview(contentWidth: 1440, contentHeight: 900, backingScale: 2, settings: .gamesDefault, landscape: true)
        #expect(preview.shown == PixelRect(x: 0, y: 90, width: 2880, height: 1620))
        #expect(preview.ratio == 2.25)
    }

    @Test func fixedRatioKeepsTheChosenOrientation() {
        // A portrait preview of a 16:9 game in a landscape full screen.
        let preview = GraphicsPreview(contentWidth: 1440, contentHeight: 900, backingScale: 2, settings: .gamesDefault, landscape: false)
        #expect(preview.request.size == PixelSize(width: 720, height: 1280))
    }

    @Test func cappedMetalFXAndShrinking() {
        let sixK = GraphicsPreview(contentWidth: 3008, contentHeight: 1692, backingScale: 2, settings: .gamesDefault, landscape: true)
        #expect(sixK.cappedMetalFXRatio == 4)
        var big = GraphicsSettings.gamesDefault
        big.shortSide = 1600
        let shrunk = GraphicsPreview(contentWidth: 892, contentHeight: 501.75, backingScale: 1, settings: big, landscape: true)
        #expect(shrunk.shrinks)
        #expect(shrunk.ratio < 0.8)
    }

    @Test func phoneScreenPreview() {
        var settings = GraphicsSettings.appsDefault
        settings.mode = .deviceProfile
        let pixel = DeviceProfile.Display(width: 1080, height: 2400, dpi: 420)
        let content = DisplaySizing.conformedContentSize(width: 412, height: 892, longOverShort: pixel.longOverShort)
        let window = GraphicsPreview(contentWidth: content.width, contentHeight: content.height, backingScale: 2, settings: settings,
                                     device: pixel, landscape: false)
        #expect(window.request == DisplayRequest(width: 1080, height: 2400, dpi: 420))
        #expect(window.shrinks)
        // Landscape full screen of a landscape phone: Android in landscape.
        let full = GraphicsPreview(contentWidth: 1440, contentHeight: 900, backingScale: 2, settings: settings, device: pixel, landscape: true)
        #expect(full.request.size == PixelSize(width: 2400, height: 1080))
        #expect(full.path == .metalFX(output: PixelSize(width: 2880, height: 1296)))
        // No screen in the device profile: the preview follows the window, as the window does.
        let none = GraphicsPreview(contentWidth: 412, contentHeight: 892, backingScale: 2, settings: settings, device: nil, landscape: true)
        #expect(none.request.size == PixelSize(width: 824, height: 1784))
    }

    @Test func followRatioPreviewKeepsItsShape() {
        var settings = GraphicsSettings.appsDefault
        settings.followAspectRatio = .ratio16x9
        let full = GraphicsPreview(contentWidth: 1440, contentHeight: 900, backingScale: 2, settings: settings, landscape: true)
        #expect(full.request.size == PixelSize(width: 2880, height: 1620))
        #expect(full.shown == PixelRect(x: 0, y: 90, width: 2880, height: 1620))
        #expect(full.path == .native)
        // Free windows ignore the orientation: the content's shape decides.
        let free = GraphicsPreview(contentWidth: 1440, contentHeight: 900, backingScale: 2, settings: .appsDefault, landscape: false)
        #expect(free.request.size == PixelSize(width: 2880, height: 1800))
    }

    @Test func fourKPreview() {
        var settings = GraphicsSettings.gamesDefault
        settings.shortSide = 2160
        let fiveK = GraphicsPreview(contentWidth: 2560, contentHeight: 1440, backingScale: 2, settings: settings, landscape: true)
        #expect(fiveK.request.size == PixelSize(width: 3840, height: 2160))
        #expect(fiveK.path == .metalFX(output: PixelSize(width: 5120, height: 2880)))
    }

    @Test func normalizedShortSide() {
        #expect(GraphicsSettings.normalizedShortSide(720) == 720)
        #expect(GraphicsSettings.normalizedShortSide(721) == 722)
        #expect(GraphicsSettings.normalizedShortSide(100) == 360)
        #expect(GraphicsSettings.normalizedShortSide(5000) == 2160)
        #expect(GraphicsSettings.normalizedShortSide(2159) == 2160)
    }
}
