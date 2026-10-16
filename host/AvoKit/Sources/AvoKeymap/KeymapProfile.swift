import Foundation

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

    public var center: NormalizedPoint { NormalizedPoint((minX + maxX) / 2, (minY + maxY) / 2) }

    public func contains(_ point: NormalizedPoint) -> Bool {
        (minX...maxX).contains(point.x) && (minY...maxY).contains(point.y)
    }

    var isValid: Bool { 0 <= minX && minX < maxX && maxX <= 1 && 0 <= minY && minY < maxY && maxY <= 1 }
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
/// mouse aim, swipe, repeated tap and simple macros).
public struct Control: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A short touch when the trigger is pressed.
        case tap(NormalizedPoint)
        /// Touch held while the trigger is held.
        case hold(NormalizedPoint)
        /// Virtual joystick driven by four triggers (WASD) or a gamepad stick.
        case dpad(center: NormalizedPoint, radius: Double, up: Trigger, down: Trigger, left: Trigger, right: Trigger, stick: GamepadStick?)
        /// Camera area for mouse-look (FPS mode) or a gamepad stick.
        case aim(area: NormalizedRect, sensitivity: AxisPair, adsSensitivity: AxisPair, exponent: Double,
                 deadzone: Double, invertY: Bool, stick: GamepadStick?)
        /// Aim-down-sights button: also switches the aim control to ADS sensitivity.
        case ads(NormalizedPoint, toggle: Bool)
        case swipe(from: NormalizedPoint, to: NormalizedPoint, milliseconds: Int)
        case repeatTap(NormalizedPoint, intervalMilliseconds: Int)
        case macro([MacroStep])
    }

    public var id: String
    public var kind: Kind
    /// What activates the control (not used by `dpad`, which has four, or
    /// by `aim`, which follows the mouse).
    public var triggers: [Trigger]
    public var layer: ControlLayer?

    public init(id: String, kind: Kind, triggers: [Trigger] = [], layer: ControlLayer? = nil) {
        self.id = id
        self.kind = kind
        self.triggers = triggers
        self.layer = layer
    }

    // Flat JSON: {"type": "tap", "id": "jump", "triggers": ["key:Space"], "position": [0.9, 0.7]}
    private enum CodingKeys: String, CodingKey {
        case type, id, triggers, layer, position, center, radius, up, down, left, right, stick
        case area, sensitivity, adsSensitivity = "ads_sensitivity", exponent, deadzone, invertY = "invert_y"
        case toggle, from, to, ms, interval, steps
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
        layer = try c.decodeIfPresent(ControlLayer.self, forKey: .layer)
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
        case "aim":
            let sensitivity = try c.decodeIfPresent(AxisPair.self, forKey: .sensitivity) ?? AxisPair(x: 1, y: 1)
            kind = .aim(area: try c.decode(NormalizedRect.self, forKey: .area),
                        sensitivity: sensitivity,
                        adsSensitivity: try c.decodeIfPresent(AxisPair.self, forKey: .adsSensitivity) ?? sensitivity,
                        exponent: try c.decodeIfPresent(Double.self, forKey: .exponent) ?? 1,
                        deadzone: try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? 0,
                        invertY: try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false,
                        stick: try c.decodeIfPresent(GamepadStick.self, forKey: .stick))
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
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown control type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if !triggers.isEmpty { try c.encode(triggers, forKey: .triggers) }
        try c.encodeIfPresent(layer, forKey: .layer)
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
        case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, stick):
            try c.encode("aim", forKey: .type)
            try c.encode(area, forKey: .area)
            try c.encode(sensitivity, forKey: .sensitivity)
            try c.encode(ads, forKey: .adsSensitivity)
            try c.encode(exponent, forKey: .exponent)
            try c.encode(deadzone, forKey: .deadzone)
            try c.encode(invertY, forKey: .invertY)
            try c.encodeIfPresent(stick, forKey: .stick)
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
        }
    }

    /// Triggers this control listens to (including a D-pad's four keys).
    public var allTriggers: [Trigger] {
        if case let .dpad(_, _, up, down, left, right, _) = kind { return [up, down, left, right] }
        return triggers
    }
}

/// FPS mode (spec §5a).
public struct FPSSettings: Hashable, Sendable, Codable {
    /// Toggles between pointer lock (combat) and cursor mode (inventory, map).
    public var cursorToggle: Trigger
    /// The aim control that the mouse drives while the pointer is locked.
    public var aimControl: String

    public init(cursorToggle: Trigger = .key(.option), aimControl: String) {
        self.cursorToggle = cursorToggle
        self.aimControl = aimControl
    }

    private enum CodingKeys: String, CodingKey {
        case cursorToggle = "cursor_toggle", aimControl = "aim_control"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursorToggle = try c.decodeIfPresent(Trigger.self, forKey: .cursorToggle) ?? .key(.option)
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

    public init(schema: Int = KeymapProfile.currentSchema, package: String, name: String, author: String? = nil,
                notes: String? = nil, controls: [Control], fps: FPSSettings? = nil) {
        self.schema = schema
        self.package = package
        self.name = name
        self.author = author
        self.notes = notes
        self.controls = controls
        self.fps = fps
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
    public static let maxPointers = 16
    public static let minimumMacroWait = 16
    public static let maximumMacroDuration = 10_000

    /// Problems that stop the profile from loading. Enforces the spec's hard
    /// limits: no recoil macros, auto-aim or automatic rapid fire.
    public func validate() -> [String] {
        var problems: [String] = []
        if schema != Self.currentSchema { problems.append("unsupported schema \(schema)") }
        if package.isEmpty { problems.append("package is empty") }

        var ids = Set<String>()
        var bindings: [ControlLayer?: Set<Trigger>] = [:]
        for control in controls {
            if !ids.insert(control.id).inserted { problems.append("duplicate control id \(control.id)") }
            problems += validate(control)

            for trigger in control.allTriggers {
                // A trigger may be bound once per layer; unlayered controls share both layers.
                let layers: [ControlLayer?] = control.layer == nil ? [nil, .locked, .cursor] : [control.layer, nil]
                for layer in layers where bindings[layer]?.contains(trigger) == true {
                    problems.append("\(trigger) is bound more than once (\(control.id))")
                }
                bindings[control.layer, default: []].insert(trigger)
            }
        }
        if controls.count > Self.maxPointers {
            problems.append("at most \(Self.maxPointers) controls can be active at once")
        }

        if let fps {
            let aims = controls.filter { if case .aim = $0.kind { return true } else { return false } }
            guard let aim = controls.first(where: { $0.id == fps.aimControl }), case .aim(let area, _, _, _, _, _, _) = aim.kind else {
                problems.append("fps.aim_control must name an aim control")
                return problems
            }
            if aims.count > 1 { problems.append("FPS mode supports one aim control") }
            if bindings.values.contains(where: { $0.contains(fps.cursorToggle) }) {
                problems.append("the cursor toggle \(fps.cursorToggle) is also bound to a control")
            }
            for control in controls {
                switch control.kind {
                case .repeatTap:
                    problems.append("\(control.id): repeated taps are not allowed in FPS mode (no automatic rapid fire)")
                case .macro:
                    problems.append("\(control.id): macros are not allowed in FPS mode (no recoil or fire macros)")
                case let .swipe(from, to, _) where area.contains(from) || area.contains(to):
                    problems.append("\(control.id): swipes may not touch the aim area (no recoil compensation)")
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
            if !p.isInside { problems.append("\(name): position \(p.x), \(p.y) is outside the screen") }
        }
        switch control.kind {
        case .tap(let p), .hold(let p), .ads(let p, _):
            point(p)
            if control.triggers.isEmpty { problems.append("\(name): needs a trigger") }
        case let .repeatTap(p, interval):
            point(p)
            if control.triggers.isEmpty { problems.append("\(name): needs a trigger") }
            if interval < 50 { problems.append("\(name): repeat interval must be at least 50 ms") }
        case let .dpad(center, radius, _, _, _, _, _):
            point(center)
            if !(0.01...0.5).contains(radius) { problems.append("\(name): radius must be between 0.01 and 0.5") }
        case let .aim(area, sensitivity, ads, exponent, deadzone, _, _):
            if !area.isValid { problems.append("\(name): aim area is invalid") }
            for s in [sensitivity.x, sensitivity.y, ads.x, ads.y] where !(0.01...20).contains(s) {
                problems.append("\(name): sensitivity must be between 0.01 and 20")
                break
            }
            if !(0.5...3).contains(exponent) { problems.append("\(name): curve exponent must be between 0.5 and 3") }
            if !(0...50).contains(deadzone) { problems.append("\(name): deadzone must be between 0 and 50") }
        case let .swipe(from, to, ms):
            point(from)
            point(to)
            if control.triggers.isEmpty { problems.append("\(name): needs a trigger") }
            if !(30...2000).contains(ms) { problems.append("\(name): swipe duration must be 30–2000 ms") }
        case .macro(let steps):
            if control.triggers.isEmpty { problems.append("\(name): needs a trigger") }
            if steps.isEmpty || steps.count > 32 { problems.append("\(name): macros need 1–32 steps") }
            var total = 0
            for step in steps {
                switch step {
                case .tap(let p): point(p)
                case let .hold(p, ms):
                    point(p)
                    if ms < Self.minimumMacroWait { problems.append("\(name): holds must last at least \(Self.minimumMacroWait) ms") }
                case .wait(let ms):
                    if ms < Self.minimumMacroWait { problems.append("\(name): waits must be at least \(Self.minimumMacroWait) ms") }
                }
                total += step.duration
            }
            if total > Self.maximumMacroDuration { problems.append("\(name): macros may run at most 10 s") }
        }
        if control.allTriggers.contains(where: \.isMomentary) {
            switch control.kind {
            case .tap, .swipe, .macro: break
            default: problems.append("\(name): scroll triggers only work with tap, swipe or macro controls")
            }
        }
        return problems
    }
}
