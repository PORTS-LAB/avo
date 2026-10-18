import AvoKit
import Foundation
import os

/// A point in display coordinates normalized to 0…1, so profiles survive
/// window resizes and different display sizes. Encoded as `[x, y]`.
public struct NormalizedPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }

    var isInside: Bool { (0...1).contains(x) && (0...1).contains(y) }
}

/// Encoded as `[x0, y0, x1, y1]`.
public struct NormalizedRect: Hashable, Sendable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        minX = try container.decode(Double.self)
        minY = try container.decode(Double.self)
        maxX = try container.decode(Double.self)
        maxY = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [minX, minY, maxX, maxY] { try container.encode(value) }
    }

    /// The whole screen.
    public static let screen = NormalizedRect(0, 0, 1, 1)

    public var center: NormalizedPoint { NormalizedPoint((minX + maxX) / 2, (minY + maxY) / 2) }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    public func contains(_ point: NormalizedPoint) -> Bool {
        minX <= point.x && point.x <= maxX && minY <= point.y && point.y <= maxY
    }

    var isValid: Bool { 0 <= minX && minX < maxX && maxX <= 1 && 0 <= minY && minY < maxY && maxY <= 1 }

    /// `point` moved into the rectangle, at least `inset` of its width and
    /// height (0…0.5) away from the edges.
    public func clamp(_ point: NormalizedPoint, inset: Double = 0) -> NormalizedPoint {
        let fraction = min(max(inset, 0), 0.5)
        let dx = width * fraction, dy = height * fraction
        return NormalizedPoint(min(max(point.x, minX + dx), maxX - dx), min(max(point.y, minY + dy), maxY - dy))
    }

    /// The sides a resize moves: `left` and `right` are minX and maxX, `top`
    /// and `bottom` minY and maxY (y grows down the screen).
    public struct Edges: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1 << 0)
        public static let right = Edges(rawValue: 1 << 1)
        public static let top = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)
    }

    /// The rectangle with `edges` moved by (dx, dy), kept on the screen and,
    /// as far as the screen allows, at least `minWidth` × `minHeight`.
    public func resized(_ edges: Edges, dx: Double, dy: Double, minWidth: Double, minHeight: Double) -> NormalizedRect {
        let w = min(max(minWidth, 0), 1), h = min(max(minHeight, 0), 1)
        var r = self
        if edges.contains(.left) { r.minX = min(max(minX + dx, 0), maxX - w) }
        if edges.contains(.right) { r.maxX = max(min(maxX + dx, 1), minX + w) }
        if edges.contains(.top) { r.minY = min(max(minY + dy, 0), maxY - h) }
        if edges.contains(.bottom) { r.maxY = max(min(maxY + dy, 1), minY + h) }
        // Too small to stay where it is (against an edge of the screen): it grows the other way.
        if r.minX < 0 { r.maxX = min(r.maxX - r.minX, 1); r.minX = 0 }
        if r.maxX > 1 { r.minX = max(r.minX - (r.maxX - 1), 0); r.maxX = 1 }
        if r.minY < 0 { r.maxY = min(r.maxY - r.minY, 1); r.minY = 0 }
        if r.maxY > 1 { r.minY = max(r.minY - (r.maxY - 1), 0); r.maxY = 1 }
        return r
    }

    /// Grown by `dw` × `dh` around its centre (shrunk when negative), kept on
    /// the screen and at least `minWidth` × `minHeight`.
    public func grown(dw: Double, dh: Double, minWidth: Double, minHeight: Double) -> NormalizedRect {
        func axis(_ low: Double, _ high: Double, _ change: Double, _ minimum: Double) -> (Double, Double) {
            let length = min(max(high - low + change, min(max(minimum, 0), 1)), 1)
            var a = (low + high) / 2 - length / 2, b = a + length
            if a < 0 { b -= a; a = 0 }
            if b > 1 { a = max(a - (b - 1), 0); b = 1 }
            return (a, b)
        }
        let (x0, x1) = axis(minX, maxX, dw, minWidth), (y0, y1) = axis(minY, maxY, dh, minHeight)
        return NormalizedRect(x0, y0, x1, y1)
    }

    /// Moved by (dx, dy) as far as the screen allows, the same size.
    public func offsetBy(dx: Double, dy: Double) -> NormalizedRect {
        let x = max(min(dx, 1 - maxX), -minX), y = max(min(dy, 1 - maxY), -minY)
        return NormalizedRect(minX + x, minY + y, maxX + x, maxY + y)
    }
}

public struct AxisPair: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// When a control is active in FPS mode.
public enum ControlLayer: String, Codable, Sendable {
    /// Only while the pointer is locked (combat).
    case locked
    /// Only in cursor mode (inventory, map).
    case cursor
}

public enum MacroStep: Hashable, Sendable, Codable {
    case tap(NormalizedPoint)
    case hold(NormalizedPoint, milliseconds: Int)
    case wait(milliseconds: Int)

    private enum CodingKeys: String, CodingKey { case tap, hold, ms, wait }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let point = try container.decodeIfPresent(NormalizedPoint.self, forKey: .tap) {
            self = .tap(point)
        } else if let point = try container.decodeIfPresent(NormalizedPoint.self, forKey: .hold) {
            self = .hold(point, milliseconds: try container.decode(Int.self, forKey: .ms))
        } else {
            self = .wait(milliseconds: try container.decode(Int.self, forKey: .wait))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tap(let point): try container.encode(point, forKey: .tap)
        case let .hold(point, ms):
            try container.encode(point, forKey: .hold)
            try container.encode(ms, forKey: .ms)
        case .wait(let ms): try container.encode(ms, forKey: .wait)
        }
    }

    var duration: Int {
        switch self {
        case .tap: KeymapEngine.tapDurationMilliseconds
        case .hold(_, let ms), .wait(let ms): ms
        }
    }
}

/// One on-screen control of a keymap profile (spec §5: tap, hold, D-pad,
/// mouse aim, swipe, repeated tap and simple macros, plus the MOBA controls
/// that aim at the cursor).
public struct Control: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A short touch when the trigger is pressed.
        case tap(NormalizedPoint)
        /// Touch held while the trigger is held.
        case hold(NormalizedPoint)
        /// Virtual joystick driven by four triggers (WASD) or a gamepad stick.
        case dpad(center: NormalizedPoint, radius: Double, up: Trigger, down: Trigger, left: Trigger, right: Trigger, stick: GamepadStick?)
        /// Camera area for mouse-look (FPS mode) or a gamepad stick: a
        /// finger touches down at `origin` (the centre of `area` when nil),
        /// swipes inside `area` as the mouse moves and, at its edge, lifts
        /// and touches down at `origin` again, so the camera turns without
        /// limit. The taller the area, the further a look up or down goes in
        /// one swipe.
        case aim(area: NormalizedRect, sensitivity: AxisPair, adsSensitivity: AxisPair, exponent: Double,
                 deadzone: Double, invertY: Bool, stick: GamepadStick?, origin: NormalizedPoint? = nil)
        /// Aim-down-sights button: also switches the aim control to ADS sensitivity.
        case ads(NormalizedPoint, toggle: Bool)
        case swipe(from: NormalizedPoint, to: NormalizedPoint, milliseconds: Int)
        case repeatTap(NormalizedPoint, intervalMilliseconds: Int)
        case macro([MacroStep])
        /// Anchor tap: a touch held at the point while the trigger is held,
        /// moved from there by the mouse (radial menus such as emote wheels:
        /// hold the key, move the mouse towards an item, let go), never out
        /// of `area` (the whole screen when nil).
        case anchor(NormalizedPoint, area: NormalizedRect? = nil)
        /// MOBA movement (move by mouse): while the trigger is held, a
        /// joystick touch at `center` is pushed the way the cursor lies from
        /// the hero (`KeymapProfile.hero`), all the way out to `radius` once
        /// the cursor is that far from the hero.
        case mobaMove(center: NormalizedPoint, radius: Double)
        /// MOBA skill with smart cast: the trigger puts a finger on the skill
        /// button and drags it the way the cursor lies from the hero,
        /// following the cursor; letting go casts. The drag grows with the
        /// cursor's distance from the hero and is a full `radius` at `reach`
        /// (the skill's range on screen), never longer.
        case smartCast(NormalizedPoint, radius: Double, reach: Double)
    }

    public var id: String
    public var kind: Kind
    /// What activates the control (not used by `dpad`, which has four, or
    /// by `aim`, which follows the mouse).
    public var triggers: [Trigger]
    public var layer: ControlLayer?
    /// How big the editor draws a button (tap, hold, ads, repeat_tap,
    /// macro), as a radius in fractions of the display height; nil is the
    /// default size. Only for lining it up with the game's own button.
    public var size: Double?
    /// A D-pad control (keys or a stick) that the controller's d-pad also
    /// pushes, its four buttons as the directions. Older versions of Avo
    /// leave it out and the keys still work.
    public var dpadButtons: Bool

    public static let defaultSize = 0.035
    public static let sizeRange = 0.012...0.3
    /// A MOBA joystick's radius, as a fraction of the display height.
    public static let defaultJoystickRadius = 0.12
    /// How far a smart cast drags the skill button at most, and how far the
    /// cursor must be from the hero for that (a typical skill range on a
    /// landscape screen), as fractions of the display height.
    public static let defaultCastRadius = 0.1
    public static let defaultCastReach = 0.35
    public static let castReachRange = 0.05...2.0

    /// A new eye's swipe area: most of the right part of the screen, at
    /// full height but for a margin. The finger goes all the way to its
    /// edge before it lifts and touches down at its point again (a thumb
    /// swiping again and again), so a look up or down travels far.
    public static let defaultEyeArea = NormalizedRect(0.45, 0.05, 0.97, 0.95)
    /// The shortest side the editor gives an area, as a fraction of the
    /// display height (on screen, a square of that side at the least).
    public static let minimumAreaSide = 0.1
    /// How far inside its area the editor keeps the eye's touch-down point,
    /// as a fraction of the area's width and height: from there the finger
    /// always has some way to go before it starts over.
    public static let eyeOriginInset = 0.1

    public init(id: String, kind: Kind, triggers: [Trigger] = [], layer: ControlLayer? = nil, size: Double? = nil,
                dpadButtons: Bool = false) {
        self.id = id
        self.kind = kind
        self.triggers = triggers
        self.layer = layer
        self.size = size
        self.dpadButtons = dpadButtons
    }

    // Flat JSON: {"type": "tap", "id": "jump", "triggers": ["key:Space"], "position": [0.9, 0.7]}
    private enum CodingKeys: String, CodingKey {
        case type, id, triggers, layer, size, position, center, radius, up, down, left, right, stick, dpadButtons = "dpad_buttons"
        case area, sensitivity, adsSensitivity = "ads_sensitivity", exponent, deadzone, invertY = "invert_y", origin
        case toggle, from, to, ms, interval, steps, reach
    }

    /// The `type` values this version reads; KeymapProfile skips the others.
    static let knownTypes: Set<String> = [
        "tap", "hold", "dpad", "aim", "ads", "swipe", "repeat_tap", "macro", "anchor", "moba_move", "smart_cast",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
        layer = try c.decodeIfPresent(ControlLayer.self, forKey: .layer)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        dpadButtons = false
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "tap": kind = .tap(try c.decode(NormalizedPoint.self, forKey: .position))
        case "hold": kind = .hold(try c.decode(NormalizedPoint.self, forKey: .position))
        case "dpad":
            kind = .dpad(center: try c.decode(NormalizedPoint.self, forKey: .center),
                         radius: try c.decode(Double.self, forKey: .radius),
                         up: try c.decodeIfPresent(Trigger.self, forKey: .up) ?? .key(.w),
                         down: try c.decodeIfPresent(Trigger.self, forKey: .down) ?? .key(.s),
                         left: try c.decodeIfPresent(Trigger.self, forKey: .left) ?? .key(.a),
                         right: try c.decodeIfPresent(Trigger.self, forKey: .right) ?? .key(.d),
                         stick: try c.decodeIfPresent(GamepadStick.self, forKey: .stick))
            dpadButtons = try c.decodeIfPresent(Bool.self, forKey: .dpadButtons) ?? false
        case "aim":
            let sensitivity = try c.decodeIfPresent(AxisPair.self, forKey: .sensitivity) ?? AxisPair(x: 1, y: 1)
            kind = .aim(area: try c.decode(NormalizedRect.self, forKey: .area),
                        sensitivity: sensitivity,
                        adsSensitivity: try c.decodeIfPresent(AxisPair.self, forKey: .adsSensitivity) ?? sensitivity,
                        exponent: try c.decodeIfPresent(Double.self, forKey: .exponent) ?? 1,
                        deadzone: try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? 0,
                        invertY: try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false,
                        stick: try c.decodeIfPresent(GamepadStick.self, forKey: .stick),
                        // Newer than the rest: a file without it (or with one
                        // this version cannot read) touches down at the centre.
                        origin: try? c.decodeIfPresent(NormalizedPoint.self, forKey: .origin))
        case "ads":
            kind = .ads(try c.decode(NormalizedPoint.self, forKey: .position),
                        toggle: try c.decodeIfPresent(Bool.self, forKey: .toggle) ?? false)
        case "swipe":
            kind = .swipe(from: try c.decode(NormalizedPoint.self, forKey: .from),
                          to: try c.decode(NormalizedPoint.self, forKey: .to),
                          milliseconds: try c.decodeIfPresent(Int.self, forKey: .ms) ?? 150)
        case "repeat_tap":
            kind = .repeatTap(try c.decode(NormalizedPoint.self, forKey: .position),
                              intervalMilliseconds: try c.decodeIfPresent(Int.self, forKey: .interval) ?? 150)
        case "macro":
            kind = .macro(try c.decode([MacroStep].self, forKey: .steps))
        case "anchor":
            // Newer than the position: without an area (or with one this
            // version cannot read) the finger may go anywhere on the screen.
            kind = .anchor(try c.decode(NormalizedPoint.self, forKey: .position),
                           area: try? c.decodeIfPresent(NormalizedRect.self, forKey: .area))
        case "moba_move":
            kind = .mobaMove(center: try c.decode(NormalizedPoint.self, forKey: .center),
                             radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultJoystickRadius)
        case "smart_cast":
            kind = .smartCast(try c.decode(NormalizedPoint.self, forKey: .position),
                              radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultCastRadius,
                              reach: try c.decodeIfPresent(Double.self, forKey: .reach) ?? Self.defaultCastReach)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown control type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !triggers.isEmpty { try c.encode(triggers, forKey: .triggers) }
        try c.encodeIfPresent(layer, forKey: .layer)
        try c.encodeIfPresent(size, forKey: .size)
        switch kind {
        case .tap(let point):
            try c.encode("tap", forKey: .type)
            try c.encode(point, forKey: .position)
        case .hold(let point):
            try c.encode("hold", forKey: .type)
            try c.encode(point, forKey: .position)
        case let .dpad(center, radius, up, down, left, right, stick):
            try c.encode("dpad", forKey: .type)
            try c.encode(center, forKey: .center)
            try c.encode(radius, forKey: .radius)
            try c.encode(up, forKey: .up)
            try c.encode(down, forKey: .down)
            try c.encode(left, forKey: .left)
            try c.encode(right, forKey: .right)
            try c.encodeIfPresent(stick, forKey: .stick)
            if dpadButtons { try c.encode(true, forKey: .dpadButtons) }
        case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, stick, origin):
            try c.encode("aim", forKey: .type)
            try c.encode(area, forKey: .area)
            try c.encode(sensitivity, forKey: .sensitivity)
            try c.encode(ads, forKey: .adsSensitivity)
            try c.encode(exponent, forKey: .exponent)
            try c.encode(deadzone, forKey: .deadzone)
            try c.encode(invertY, forKey: .invertY)
            try c.encodeIfPresent(stick, forKey: .stick)
            try c.encodeIfPresent(origin, forKey: .origin)
        case let .ads(point, toggle):
            try c.encode("ads", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encode(toggle, forKey: .toggle)
        case let .swipe(from, to, ms):
            try c.encode("swipe", forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(ms, forKey: .ms)
        case let .repeatTap(point, interval):
            try c.encode("repeat_tap", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encode(interval, forKey: .interval)
        case .macro(let steps):
            try c.encode("macro", forKey: .type)
            try c.encode(steps, forKey: .steps)
        case let .anchor(point, area):
            try c.encode("anchor", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encodeIfPresent(area, forKey: .area)
        case let .mobaMove(center, radius):
            try c.encode("moba_move", forKey: .type)
            try c.encode(center, forKey: .center)
            try c.encode(radius, forKey: .radius)
        case let .smartCast(point, radius, reach):
            try c.encode("smart_cast", forKey: .type)
            try c.encode(point, forKey: .position)
            try c.encode(radius, forKey: .radius)
            try c.encode(reach, forKey: .reach)
        }
    }

    /// Triggers this control listens to (including a D-pad's four keys, and
    /// the controller's d-pad buttons when they push it too).
    public var allTriggers: [Trigger] {
        if case let .dpad(_, _, up, down, left, right, _) = kind {
            let directions = [up, down, left, right]
            guard dpadButtons else { return directions }
            return directions + GamepadElement.dpadButtons.map(Trigger.gamepad).filter { !directions.contains($0) }
        }
        return triggers
    }

    /// Aimed from the hero at the free cursor (MOBA move and smart cast).
    public var followsCursor: Bool {
        switch kind {
        case .mobaMove, .smartCast: true
        default: false
        }
    }
}

// MARK: - Finger areas (eye and anchor tap)

extension Control {
    /// Where an eye's or anchor tap's finger may go: the eye's swipe area,
    /// the anchor tap's own area (the whole screen when it has none); nil
    /// for the other kinds.
    public var fingerArea: NormalizedRect? {
        switch kind {
        case let .aim(area, _, _, _, _, _, _, _): area
        case let .anchor(_, area): area ?? .screen
        default: nil
        }
    }

    /// Where an eye's or anchor tap's finger touches down: the eye's origin
    /// (the centre of its area unless the player moved it), the anchor
    /// tap's position; nil for the other kinds.
    public var touchPoint: NormalizedPoint? {
        switch kind {
        case let .aim(area, _, _, _, _, _, _, origin): origin ?? area.center
        case let .anchor(point, _): point
        default: nil
        }
    }

    /// Gives an eye or anchor tap `area`, its touch-down point kept inside
    /// (an eye's at the centre stays at the centre). An anchor tap's area
    /// that is the whole screen is stored as none, as before areas existed.
    public mutating func setFingerArea(_ area: NormalizedRect) {
        switch kind {
        case let .aim(_, sensitivity, ads, exponent, deadzone, invertY, stick, origin):
            kind = .aim(area: area, sensitivity: sensitivity, adsSensitivity: ads, exponent: exponent, deadzone: deadzone,
                        invertY: invertY, stick: stick, origin: origin.map { area.clamp($0, inset: Self.eyeOriginInset) })
        case let .anchor(point, _):
            kind = area == .screen ? .anchor(point) : .anchor(area.clamp(point), area: area)
        default:
            break
        }
    }

    /// Moves an eye's touch-down point (nil: the centre of its area) or an
    /// anchor tap's position, kept inside the area.
    public mutating func setTouchPoint(_ point: NormalizedPoint?) {
        switch kind {
        case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, stick, _):
            kind = .aim(area: area, sensitivity: sensitivity, adsSensitivity: ads, exponent: exponent, deadzone: deadzone,
                        invertY: invertY, stick: stick, origin: point.map { area.clamp($0, inset: Self.eyeOriginInset) })
        case .anchor(_, let area):
            guard let point else { return }
            kind = .anchor((area ?? .screen).clamp(point), area: area)
        default:
            break
        }
    }

    /// Moves an eye's or anchor tap's area together with its touch-down
    /// point, as far as the screen allows (an anchor tap without an area
    /// moves its point).
    public mutating func moveFinger(dx: Double, dy: Double) {
        guard let area = fingerArea, let point = touchPoint else { return }
        if case .anchor(_, nil) = kind {
            setTouchPoint(NormalizedPoint(point.x + dx, point.y + dy))
            return
        }
        let moved = area.offsetBy(dx: dx, dy: dy)
        let ox = moved.minX - area.minX, oy = moved.minY - area.minY
        switch kind {
        case let .aim(_, sensitivity, ads, exponent, deadzone, invertY, stick, origin):
            kind = .aim(area: moved, sensitivity: sensitivity, adsSensitivity: ads, exponent: exponent, deadzone: deadzone,
                        invertY: invertY, stick: stick, origin: origin.map { moved.clamp(NormalizedPoint($0.x + ox, $0.y + oy)) })
        case .anchor:
            kind = .anchor(moved.clamp(NormalizedPoint(point.x + ox, point.y + oy)), area: moved)
        default:
            break
        }
    }
}

/// One entry of a profile's `controls`: a control, or the type of a control
/// this version does not know.
private struct ControlEntry: Decodable {
    var control: Control?
    var unsupportedType: String?

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        if Control.knownTypes.contains(type) {
            control = try Control(from: decoder)
        } else {
            unsupportedType = type
        }
    }
}

/// FPS mode (spec §5a).
public struct FPSSettings: Hashable, Sendable, Codable {
    /// Toggles between pointer lock (combat) and cursor mode (inventory, map).
    public var cursorToggle: Trigger
    /// The aim control that the mouse drives while the pointer is locked.
    public var aimControl: String

    /// F8 by default: a key games rarely use (fn+F8 on keyboards whose top
    /// row controls media).
    public static let defaultCursorToggle = Trigger.key(.f8)

    public init(cursorToggle: Trigger = FPSSettings.defaultCursorToggle, aimControl: String) {
        self.cursorToggle = cursorToggle
        self.aimControl = aimControl
    }

    private enum CodingKeys: String, CodingKey {
        case cursorToggle = "cursor_toggle", aimControl = "aim_control"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursorToggle = try c.decodeIfPresent(Trigger.self, forKey: .cursorToggle) ?? Self.defaultCursorToggle
        aimControl = try c.decode(String.self, forKey: .aimControl)
    }
}

/// A keymapping profile for one Android package, stored as JSON so the
/// community can share them (spec §5).
public struct KeymapProfile: Hashable, Sendable, Codable {
    public static let currentSchema = 1

    public var schema: Int
    public var package: String
    public var name: String
    public var author: String?
    public var notes: String?
    public var controls: [Control]
    public var fps: FPSSettings?
    /// Where the player's character stands on the screen in a MOBA (the
    /// camera keeps it there): move-by-mouse and smart-cast controls aim
    /// from here to the cursor. Nil is the centre.
    public var hero: NormalizedPoint?
    /// The controller's sticks, vibration and saved controller presets
    /// (GamepadMapping.swift); nil uses the standard sticks.
    public var gamepad: GamepadSettings?
    /// Types of controls in the file that this version of Avo does not know
    /// (a newer one wrote them). They are left out so the rest of the profile
    /// still loads; saving the profile again drops them.
    public private(set) var unsupportedControls: [String] = []

    public static let defaultHero = NormalizedPoint(0.5, 0.5)

    public init(schema: Int = KeymapProfile.currentSchema, package: String, name: String, author: String? = nil,
                notes: String? = nil, controls: [Control], fps: FPSSettings? = nil, hero: NormalizedPoint? = nil,
                gamepad: GamepadSettings? = nil) {
        self.schema = schema
        self.package = package
        self.name = name
        self.author = author
        self.notes = notes
        self.controls = controls
        self.fps = fps
        self.hero = hero
        self.gamepad = gamepad
    }

    private enum CodingKeys: String, CodingKey {
        case schema, package, name, author, notes, controls, fps, hero, gamepad
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        package = try c.decode(String.self, forKey: .package)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        // A control kind from a newer Avo is skipped instead of failing the
        // whole profile; a broken control of a known kind still fails it.
        let entries = try c.decode([ControlEntry].self, forKey: .controls)
        controls = entries.compactMap(\.control)
        unsupportedControls = entries.compactMap(\.unsupportedType)
        fps = try c.decodeIfPresent(FPSSettings.self, forKey: .fps)
        hero = try c.decodeIfPresent(NormalizedPoint.self, forKey: .hero)
        // Newer than the rest: a block this version cannot read leaves the
        // standard sticks, and the controls still load.
        gamepad = try? c.decodeIfPresent(GamepadSettings.self, forKey: .gamepad)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(package, forKey: .package)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(controls, forKey: .controls)
        try c.encodeIfPresent(fps, forKey: .fps)
        try c.encodeIfPresent(hero, forKey: .hero)
        try c.encodeIfPresent(gamepad, forKey: .gamepad)
    }

    public static func decode(_ data: Data) throws -> KeymapProfile {
        try JSONDecoder().decode(KeymapProfile.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Validation

extension KeymapProfile {
    /// Fingers on Android's touch screen at the same time (its multitouch
    /// slots). A profile may have any number of controls; past this many
    /// fingers down, another control waits for one to lift.
    public static let maxPointers = 16
    public static let minimumMacroWait = 16
    public static let maximumMacroDuration = 10_000

    /// Problems that stop the profile from loading. Enforces the spec's hard
    /// limits: no recoil macros, auto-aim or automatic rapid fire.
    public func validate() -> [String] {
        var problems: [String] = []
        if schema != Self.currentSchema { problems.append(String(localized: "unsupported schema \(schema)", bundle: .avoKit)) }
        if package.isEmpty { problems.append(String(localized: "package is empty", bundle: .avoKit)) }
        if let hero, !hero.isInside {
            problems.append(String(localized: "the hero point \(String(describing: hero.x)), \(String(describing: hero.y)) is outside the screen", bundle: .avoKit))
        }
        if let gamepad { problems += gamepad.validate() }

        var ids = Set<String>()
        var bindings: [ControlLayer?: Set<Trigger>] = [:]
        for control in controls {
            if !ids.insert(control.id).inserted { problems.append(String(localized: "duplicate control id \(control.id)", bundle: .avoKit)) }
            problems += validate(control)

            for trigger in control.allTriggers {
                // A trigger may be bound once per layer; unlayered controls share both layers.
                let layers: [ControlLayer?] = control.layer == nil ? [nil, .locked, .cursor] : [control.layer, nil]
                for layer in layers where bindings[layer]?.contains(trigger) == true {
                    problems.append(String(localized: "\(trigger.description) is bound more than once (\(control.id))", bundle: .avoKit))
                }
                bindings[control.layer, default: []].insert(trigger)
            }
        }
        if let fps {
            let aims = controls.filter { if case .aim = $0.kind { return true } else { return false } }
            guard let aim = controls.first(where: { $0.id == fps.aimControl }), case .aim(let area, _, _, _, _, _, _, _) = aim.kind else {
                problems.append(String(localized: "fps.aim_control must name an aim control", bundle: .avoKit))
                return problems
            }
            if aims.count > 1 { problems.append(String(localized: "FPS mode supports one aim control", bundle: .avoKit)) }
            if bindings.values.contains(where: { $0.contains(fps.cursorToggle) }) {
                problems.append(String(localized: "the cursor toggle \(fps.cursorToggle.description) is also bound to a control", bundle: .avoKit))
            }
            for control in controls {
                switch control.kind {
                case .repeatTap:
                    problems.append(String(localized: "\(control.id): repeated taps are not allowed in FPS mode (no automatic rapid fire)", bundle: .avoKit))
                case .macro:
                    problems.append(String(localized: "\(control.id): macros are not allowed in FPS mode (no recoil or fire macros)", bundle: .avoKit))
                case let .swipe(from, to, _) where area.contains(from) || area.contains(to):
                    problems.append(String(localized: "\(control.id): swipes may not touch the aim area (no recoil compensation)", bundle: .avoKit))
                default:
                    break
                }
            }
        }
        return problems
    }

    private func validate(_ control: Control) -> [String] {
        var problems: [String] = []
        let name = control.id
        func point(_ p: NormalizedPoint) {
            if !p.isInside { problems.append(String(localized: "\(name): position \(String(describing: p.x)), \(String(describing: p.y)) is outside the screen", bundle: .avoKit)) }
        }
        if let size = control.size, !Control.sizeRange.contains(size) {
            problems.append(String(localized: "\(name): size must be between \(Control.sizeRange.lowerBound) and \(Control.sizeRange.upperBound)", bundle: .avoKit))
        }
        switch control.kind {
        case .tap(let p), .hold(let p), .ads(let p, _), .anchor(let p, _):
            point(p)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if case .anchor(_, let area?) = control.kind {
                if !area.isValid {
                    problems.append(String(localized: "\(name): anchor area is invalid", bundle: .avoKit))
                } else if !area.contains(p) {
                    problems.append(String(localized: "\(name): position must be inside the anchor area", bundle: .avoKit))
                }
            }
        case let .repeatTap(p, interval):
            point(p)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if interval < 50 { problems.append(String(localized: "\(name): repeat interval must be at least 50 ms", bundle: .avoKit)) }
        case let .dpad(center, radius, _, _, _, _, _):
            point(center)
            if !(0.01...0.5).contains(radius) { problems.append(String(localized: "\(name): radius must be between 0.01 and 0.5", bundle: .avoKit)) }
        case let .mobaMove(center, radius):
            point(center)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if !(0.01...0.5).contains(radius) { problems.append(String(localized: "\(name): radius must be between 0.01 and 0.5", bundle: .avoKit)) }
        case let .smartCast(p, radius, reach):
            point(p)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if !(0.01...0.5).contains(radius) { problems.append(String(localized: "\(name): radius must be between 0.01 and 0.5", bundle: .avoKit)) }
            if !Control.castReachRange.contains(reach) { problems.append(String(localized: "\(name): reach must be between 0.05 and 2", bundle: .avoKit)) }
        case let .aim(area, sensitivity, ads, exponent, deadzone, _, _, origin):
            if !area.isValid { problems.append(String(localized: "\(name): aim area is invalid", bundle: .avoKit)) }
            if let origin, !area.contains(origin) {
                problems.append(String(localized: "\(name): touch-down point must be inside the aim area", bundle: .avoKit))
            }
            for s in [sensitivity.x, sensitivity.y, ads.x, ads.y] where !(0.01...20).contains(s) {
                problems.append(String(localized: "\(name): sensitivity must be between 0.01 and 20", bundle: .avoKit))
                break
            }
            if !(0.5...3).contains(exponent) { problems.append(String(localized: "\(name): curve exponent must be between 0.5 and 3", bundle: .avoKit)) }
            if !(0...50).contains(deadzone) { problems.append(String(localized: "\(name): deadzone must be between 0 and 50", bundle: .avoKit)) }
        case let .swipe(from, to, ms):
            point(from)
            point(to)
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if !(30...2000).contains(ms) { problems.append(String(localized: "\(name): swipe duration must be 30–2000 ms", bundle: .avoKit)) }
        case .macro(let steps):
            if control.triggers.isEmpty { problems.append(String(localized: "\(name): needs a trigger", bundle: .avoKit)) }
            if steps.isEmpty || steps.count > 32 { problems.append(String(localized: "\(name): macros need 1–32 steps", bundle: .avoKit)) }
            var total = 0
            for step in steps {
                switch step {
                case .tap(let p): point(p)
                case let .hold(p, ms):
                    point(p)
                    if ms < Self.minimumMacroWait { problems.append(String(localized: "\(name): holds must last at least \(Self.minimumMacroWait) ms", bundle: .avoKit)) }
                case .wait(let ms):
                    if ms < Self.minimumMacroWait { problems.append(String(localized: "\(name): waits must be at least \(Self.minimumMacroWait) ms", bundle: .avoKit)) }
                }
                total += step.duration
            }
            if total > Self.maximumMacroDuration { problems.append(String(localized: "\(name): macros may run at most 10 s", bundle: .avoKit)) }
        }
        if control.allTriggers.contains(where: \.isMomentary) {
            switch control.kind {
            case .tap, .swipe, .macro: break
            default: problems.append(String(localized: "\(name): scroll triggers only work with tap, swipe or macro controls", bundle: .avoKit))
            }
        }
        return problems
    }
}

// MARK: - Lookup

extension KeymapProfile {
    /// The profile a window uses: the user's (`paths.keymap(for:)`) when it
    /// decodes and validates, else the one shipped with Avo,
    /// `<bundledDirectory>/<package>.json`, under the same rule. It is also
    /// the one definition of "this app has a key mapping", which gives the
    /// app the Games graphics defaults, so the profile and the graphics
    /// always agree.
    public static func usable(for package: String, bundledDirectory: URL?,
                              paths: AvoPaths = AvoPaths()) -> (profile: KeymapProfile, url: URL)? {
        let candidates = [paths.keymap(for: package), bundledDirectory?.appending(path: "\(package).json")]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let profile = try decode(data)
                let problems = profile.validate()
                guard problems.isEmpty else {
                    lookupLogger.error("ignoring \(url.lastPathComponent, privacy: .public): \(problems.joined(separator: "; "), privacy: .public)")
                    continue
                }
                return (profile, url)
            } catch {
                lookupLogger.error("cannot read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
}

private let lookupLogger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Keymap")
