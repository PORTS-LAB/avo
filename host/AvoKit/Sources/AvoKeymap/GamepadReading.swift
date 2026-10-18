import AvoProtocol

/// A Mac game controller's state as GameController.framework reads it, for
/// Android's gamepad: games with controller support get the Input channel's
/// GAMEPAD record, which the daemon plays on the engine's Xbox-layout
/// gamepad (HostAgent, engine/hvf/vmm/src/virtio/input.rs).
public struct GamepadReading: Equatable, Sendable {
    public var pressed: Set<GamepadButton>
    /// The Home button (Xbox, PS), when macOS lets it through.
    public var home: Bool
    /// Sticks, -1…1 with y up (GameController convention).
    public var leftX: Float, leftY: Float, rightX: Float, rightY: Float
    /// Triggers, 0…1.
    public var leftTrigger: Float, rightTrigger: Float

    public init(pressed: Set<GamepadButton> = [], home: Bool = false, leftX: Float = 0, leftY: Float = 0,
                rightX: Float = 0, rightY: Float = 0, leftTrigger: Float = 0, rightTrigger: Float = 0) {
        self.pressed = pressed
        self.home = home
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }

    /// GamepadState.buttons bit of the Home button, after GamepadButton's
    /// sixteen (the engine's gamepad presses BTN_MODE for it). It is no
    /// keymap trigger: macOS keeps the button for itself unless a game asks.
    public static let homeBit: UInt32 = 1 << 16

    /// The GAMEPAD record's state: buttons by `GamepadButton.bit`, the
    /// d-pad also as the hat axes (an Xbox pad has no d-pad keys), with y up
    /// like the sticks. Opposite directions held together cancel out.
    public func state(pad: UInt8 = 0) -> GamepadState {
        var state = GamepadState(pad: pad)
        state.buttons = pressed.reduce(home ? Self.homeBit : 0) { $0 | $1.bit }
        state[.leftX] = Self.clamp(leftX, -1)
        state[.leftY] = Self.clamp(leftY, -1)
        state[.rightX] = Self.clamp(rightX, -1)
        state[.rightY] = Self.clamp(rightY, -1)
        state[.leftTrigger] = Self.clamp(leftTrigger, 0)
        state[.rightTrigger] = Self.clamp(rightTrigger, 0)
        state[.hatX] = direction(.dpadRight) - direction(.dpadLeft)
        state[.hatY] = direction(.dpadUp) - direction(.dpadDown)
        return state
    }

    private func direction(_ button: GamepadButton) -> Float {
        pressed.contains(button) ? 1 : 0
    }

    private static func clamp(_ value: Float, _ lowest: Float) -> Float {
        value.isNaN ? 0 : min(max(value, lowest), 1)
    }

    /// What changed since `previous`, as the key mapping's input: buttons
    /// pressed or let go (in GamepadButton's order), then the sticks that
    /// moved. GameController reports one element at a time; the Window Host
    /// reads the whole controller each time and passes on the difference.
    public func inputs(since previous: GamepadReading) -> [KeymapEngine.Input] {
        var inputs: [KeymapEngine.Input] = []
        for button in GamepadButton.allCases where pressed.contains(button) != previous.pressed.contains(button) {
            inputs.append(.gamepadButton(button, pressed: pressed.contains(button)))
        }
        if leftX != previous.leftX || leftY != previous.leftY {
            inputs.append(.gamepadStick(.left, x: Double(leftX), y: Double(leftY)))
        }
        if rightX != previous.rightX || rightY != previous.rightY {
            inputs.append(.gamepadStick(.right, x: Double(rightX), y: Double(rightY)))
        }
        return inputs
    }

    /// Where `stick` points, -1…1 with y up.
    public func position(of stick: GamepadStick) -> (x: Double, y: Double) {
        stick == .left ? (Double(leftX), Double(leftY)) : (Double(rightX), Double(rightY))
    }
}

extension KeymapProfile {
    /// Some control is bound to a gamepad button or stick: in Game Mode the
    /// mapping turns the controller into touches, and Android gets no gamepad.
    public var usesGamepad: Bool {
        func isGamepad(_ trigger: Trigger?) -> Bool {
            if case .gamepad = trigger { true } else { false }
        }
        return isGamepad(fps?.cursorToggle)
            || controls.contains { $0.stick != nil || $0.allTriggers.contains(where: isGamepad) }
    }
}
