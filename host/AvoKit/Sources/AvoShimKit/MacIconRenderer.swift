import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders Android launcher icons onto the macOS app icon grid: a 1024 pt
/// canvas with an 824 pt continuous-corner squircle and Apple's drop shadow
/// (spec §4: "adaptive icon dirender di atas squircle macOS").
public enum MacIconRenderer {
    public enum Layer: @unchecked Sendable {
        case color(CGColor)
        case image(CGImage)
    }

    public enum Source: @unchecked Sendable {
        /// AdaptiveIconDrawable layers (108 dp canvas, 72 dp safe zone).
        case adaptive(background: Layer?, foreground: Layer?)
        /// A legacy launcher bitmap of any shape.
        case legacy(CGImage)
    }

    static let canvas: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let cornerRadius: CGFloat = 185.4

    /// Renders the icon at `pixels` × `pixels`.
    public static func render(_ source: Source, pixels: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let scale = CGFloat(pixels) / canvas
        context.scaleBy(x: scale, y: scale)

        let shape = continuousRoundedRect(body, radius: cornerRadius)

        // Drop shadow under the body (CG's y axis points up, so the offset is negative).
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
        context.addPath(shape)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        switch source {
        case let .adaptive(background, foreground):
            // The 72 dp safe zone maps onto the 824 pt body, so the full 108 dp
            // layer spans 1236 pt centred on the canvas.
            let side = body.width * 108 / 72
            let layerRect = CGRect(x: (canvas - side) / 2, y: (canvas - side) / 2, width: side, height: side)
            draw(background ?? .color(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)), in: layerRect, context: context)
            if let foreground { draw(foreground, in: layerRect, context: context) }
        case .legacy(let image):
            if isFullBleed(image) {
                context.draw(image, in: body)
            } else if let shape = footprint(image), shape.isShape, let cropped = image.cropping(to: shape.bounds) {
                // Already a shape (rounded square, circle, squircle): it becomes
                // the icon's squircle, on its own edge colour instead of a white plate.
                context.setFillColor(shape.edgeColor ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(body)
                context.draw(cropped, in: body)
            } else {
                // A glyph on transparency needs something behind it.
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(body)
                context.draw(image, in: aspectFit(image, in: body.insetBy(dx: body.width * 0.1, dy: body.height * 0.1)))
            }
        }
        context.restoreGState()
        return context.makeImage()
    }

    /// An .icns with every size macOS asks for (16–512 pt at 1x and 2x).
    public static func icns(_ source: Source) -> Data? {
        let slots: [(pixels: Int, dpi: Int)] = [
            (16, 72), (32, 144), (32, 72), (64, 144), (128, 72), (256, 144), (256, 72), (512, 144), (512, 72), (1024, 144),
        ]
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.icns.identifier as CFString, slots.count, nil) else {
            return nil
        }
        for slot in slots {
            guard let image = render(source, pixels: slot.pixels) else { return nil }
            let properties = [kCGImagePropertyDPIWidth: slot.dpi, kCGImagePropertyDPIHeight: slot.dpi] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Decodes PNG, WebP or JPEG data.
    public static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func color(argb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat(argb >> 24) / 255)
    }

    // MARK: Helpers

    private static func draw(_ layer: Layer, in rect: CGRect, context: CGContext) {
        switch layer {
        case .color(let color):
            context.setFillColor(color)
            context.fill(rect)
        case .image(let image):
            context.draw(image, in: rect)
        }
    }

    private static func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Where a legacy bitmap is opaque: its bounds (pixels, origin top left),
    /// how much of them is opaque, and the average colour just inside them.
    struct Footprint {
        let bounds: CGRect
        let coverage: Double
        let edgeColor: CGColor?

        /// A filled, roughly square shape (a circle covers π/4 of its box).
        var isShape: Bool {
            coverage >= 0.7 && bounds.height > 0 && (0.85...1.18).contains(bounds.width / bounds.height)
        }
    }

    static func footprint(_ image: CGImage) -> Footprint? {
        let size = 64
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * size + x) * 4 + 3] }
        var minX = size, minY = size, maxX = -1, maxY = -1
        for y in 0..<size {
            for x in 0..<size where alpha(x, y) > 32 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        var opaque = 0
        for y in minY...maxY {
            for x in minX...maxX where alpha(x, y) > 128 { opaque += 1 }
        }
        // Average colour two pixels inside the box (corners of round shapes are skipped).
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        func sample(_ x: Int, _ y: Int) {
            let i = (y * size + x) * 4
            let a = Double(pixels[i + 3])
            guard a > 200 else { return }
            red += Double(pixels[i]) / a
            green += Double(pixels[i + 1]) / a
            blue += Double(pixels[i + 2]) / a
            count += 1
        }
        let inset = 2
        if maxX - minX > 2 * inset, maxY - minY > 2 * inset {
            for x in (minX + inset)...(maxX - inset) { sample(x, minY + inset); sample(x, maxY - inset) }
            for y in (minY + inset)...(maxY - inset) { sample(minX + inset, y); sample(maxX - inset, y) }
        }
        let scaleX = Double(image.width) / Double(size), scaleY = Double(image.height) / Double(size)
        let bounds = CGRect(x: Double(minX) * scaleX, y: Double(minY) * scaleY,
                            width: Double(maxX - minX + 1) * scaleX, height: Double(maxY - minY + 1) * scaleY).integral
        return Footprint(bounds: bounds, coverage: Double(opaque) / Double((maxX - minX + 1) * (maxY - minY + 1)),
                         edgeColor: count > 0 ? CGColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1) : nil)
    }

    /// A square icon whose corners are opaque already fills its shape, so it is
    /// masked to the squircle rather than placed on a white plate.
    static func isFullBleed(_ image: CGImage) -> Bool {
        guard image.width == image.height, image.width >= 8 else { return false }
        let size = 8
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let corners = [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)]
        return corners.allSatisfy { x, y in pixels[(y * size + x) * 4 + 3] > 240 }
    }

    /// Apple's continuous-corner rounded rectangle (matches SwiftUI's
    /// `RoundedRectangle(style: .continuous)` and branding/tools/generate.py).
    public static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
        let (a, b, c, d, e, f, g): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) =
            (1.52866483, 1.08849323, 0.86840689, 0.63149399, 0.07491100, 0.37282401, 0.16905899)
        let x = rect.minX, y = rect.minY, X = rect.maxX, Y = rect.maxY
        let path = CGMutablePath()
        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: px, y: py) }
        path.move(to: p(x + a * r, y))
        path.addLine(to: p(X - a * r, y))
        path.addCurve(to: p(X - d * r, y + e * r), control1: p(X - b * r, y), control2: p(X - c * r, y))
        path.addCurve(to: p(X - e * r, y + d * r), control1: p(X - f * r, y + g * r), control2: p(X - g * r, y + f * r))
        path.addCurve(to: p(X, y + a * r), control1: p(X, y + c * r), control2: p(X, y + b * r))
        path.addLine(to: p(X, Y - a * r))
        path.addCurve(to: p(X - e * r, Y - d * r), control1: p(X, Y - b * r), control2: p(X, Y - c * r))
        path.addCurve(to: p(X - d * r, Y - e * r), control1: p(X - g * r, Y - f * r), control2: p(X - f * r, Y - g * r))
        path.addCurve(to: p(X - a * r, Y), control1: p(X - c * r, Y), control2: p(X - b * r, Y))
        path.addLine(to: p(x + a * r, Y))
        path.addCurve(to: p(x + d * r, Y - e * r), control1: p(x + b * r, Y), control2: p(x + c * r, Y))
        path.addCurve(to: p(x + e * r, Y - d * r), control1: p(x + f * r, Y - g * r), control2: p(x + g * r, Y - f * r))
        path.addCurve(to: p(x, Y - a * r), control1: p(x, Y - c * r), control2: p(x, Y - b * r))
        path.addLine(to: p(x, y + a * r))
        path.addCurve(to: p(x + e * r, y + d * r), control1: p(x, y + b * r), control2: p(x, y + c * r))
        path.addCurve(to: p(x + d * r, y + e * r), control1: p(x + g * r, y + f * r), control2: p(x + f * r, y + g * r))
        path.addCurve(to: p(x + a * r, y), control1: p(x + c * r, y), control2: p(x + b * r, y))
        path.closeSubpath()
        return path
    }
}
