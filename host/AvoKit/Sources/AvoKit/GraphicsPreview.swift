import Foundation

// What Settings › Graphics shows under "Result": the size Android would get
// for a window (or a full screen) and how the Window Host would put that
// picture on screen. It runs the same DisplaySizing rules the windows use,
// so the preview never disagrees with what a window does.

public struct GraphicsPreview: Equatable, Sendable {
    /// What the window would ask Android for.
    public var request: DisplayRequest
    /// The window's (or screen's) size in pixels.
    public var screen: PixelSize
    /// Where Android's picture lands inside `screen`.
    public var shown: PixelRect
    public var path: ScalingPath

    /// - Parameters:
    ///   - contentWidth, contentHeight: points, already conformed to a locked
    ///     shape for a window (`conformedContentSize`).
    ///   - device: the device profile's screen, for the phone's-screen mode.
    ///   - landscape: the orientation a locked shape keeps; nil takes the
    ///     content's shape.
    public init(contentWidth: Double, contentHeight: Double, backingScale: Double, settings: GraphicsSettings,
                device: DeviceProfile.Display? = nil, landscape: Bool? = nil, metalFXAvailable: Bool = true) {
        let locked = settings.lockedRatio(device: device) != nil
        request = DisplaySizing.request(contentWidth: contentWidth, contentHeight: contentHeight, backingScale: backingScale,
                                        settings: settings, device: device, landscape: locked ? landscape : nil)
        screen = PixelSize(width: Int((contentWidth * backingScale).rounded()), height: Int((contentHeight * backingScale).rounded()))
        shown = DisplaySizing.presentationRect(source: request.size, target: screen)
        path = DisplaySizing.scalingPath(source: request.size, destination: shown.size, filter: settings.filter,
                                         metalFXAvailable: metalFXAvailable, interactive: false)
    }

    /// The picture on screen over Android's, on the axis that grows least
    /// (the one MetalFX's own minimum ratio looks at).
    public var ratio: Double {
        let source = request.size
        guard source.width > 0, source.height > 0 else { return 1 }
        return min(Double(shown.width) / Double(source.width), Double(shown.height) / Double(source.height))
    }

    /// The MetalFX step alone, when its output is capped at ×4 and a
    /// bilinear pass does the rest; nil for every other path.
    public var cappedMetalFXRatio: Double? {
        guard case .metalFX(let output) = path, output != shown.size, request.width > 0 else { return nil }
        return Double(output.width) / Double(request.width)
    }

    /// Android renders more pixels than the screen shows.
    public var shrinks: Bool {
        if case .downsample = path { true } else { false }
    }
}

extension GraphicsSettings {
    /// A typed-in resolution as Android can use it: the nearest even number
    /// in `shortSideRange`.
    public static func normalizedShortSide(_ value: Int) -> Int {
        let even = Int((Double(value) / 2).rounded()) * 2
        return min(max(even, shortSideRange.lowerBound), shortSideRange.upperBound)
    }
}
