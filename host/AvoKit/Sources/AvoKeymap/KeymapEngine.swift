import AvoProtocol
import Foundation

/// Turns keyboard, mouse and gamepad input into multitouch events for one
/// display, following a `KeymapProfile`.
///
/// The engine is a pure state machine: the Window Host feeds it input with
/// timestamps, calls `tick(at:)` on every display refresh, and sends the
/// resulting `TouchEvent`s over the Input channel. Every event carries the full
/// pointer set, as Android's MotionEvent expects.
public struct KeymapEngine: Sendable {
    public static let tapDurationMilliseconds = 40
    /// Mouse counts per second at full gamepad stick deflection.
    public static let stickAimSpeed = 1400.0
    public static let stickDeadzone = 0.15
    /// Reference height that makes aim sensitivity resolution-independent.
    static let referenceHeight = 1080.0
    static let swipeStepMilliseconds = 8

    public enum Input: Sendable, Equatable {
        case keyDown(KeyName)
        case keyUp(KeyName)
        case mouseDown(MouseButton)
        case mouseUp(MouseButton)
        /// Raw, unaccelerated mouse delta in counts (pointer locked).
        case mouseMoved(dx: Double, dy: Double)
        /// One wheel notch per event; positive scrolls up.
        case scroll(dy: Double)
        case gamepadButton(GamepadButton, pressed: Bool)
        /// Stick position, -1…1, with y up positive (GameController convention).
        case gamepadStick(GamepadStick, x: Double, y: Double)
    }

    public struct Output: Sendable, Equatable {
        public var events: [TouchEvent] = []
        /// The input was handled by a control and must not reach the app as a key or click.
        public var consumed = false
        /// Set when the host should engage (true) or release (false) pointer lock.
        public var pointerLock: Bool?
    }

    public let profile: KeymapProfile
    public let displayID: UInt32
    public private(set) var width: Double
    public private(set) var height: Double
    /// FPS combat mode: the mouse drives the aim control.
    public private(set) var pointerLocked = false
    public private(set) var adsActive = false

    private struct Touch: Sendable {
        let id: Int
        let pointerID: UInt32
        var x: Double
        var y: Double
    }

    private enum Action: Sendable {
        case lift(touch: Int)
        case move(touch: Int, x: Double, y: Double)
        case repeatTap(control: String, trigger: Trigger)
        case macroStep(control: String, index: Int)
    }

    private struct Scheduled: Sendable {
        let time: TimeInterval
        let order: Int
        let action: Action
    }

    private var touches: [Touch] = []
    private var nextTouchID = 1
    private var movedSinceFlush = false
    private var events: [TouchEvent] = []
    private var pressed: Set<Trigger> = []
    /// Touches held by hold, ads, dpad and aim controls.
    private var held: [String: Int] = [:]
    private var schedule: [Scheduled] = []
    private var scheduleOrder = 0
    private var sticks: [GamepadStick: (x: Double, y: Double)] = [:]
    private var lastTick: TimeInterval?

    public init(profile: KeymapProfile, displayID: UInt32, width: Double, height: Double) {
        self.profile = profile
        self.displayID = displayID
        self.width = width
        self.height = height
    }

    // MARK: Public API

    public mutating func handle(_ input: Input, at now: TimeInterval) -> Output {
        var output = Output()
        runDue(until: now)
        switch input {
        case .keyDown(let key): output.consumed = press(.key(key), at: now, output: &output)
        case .keyUp(let key): output.consumed = release(.key(key))
        case .mouseDown(let button): output.consumed = press(.mouse(button), at: now, output: &output)
        case .mouseUp(let button): output.consumed = release(.mouse(button))
        case .gamepadButton(let button, true): output.consumed = press(.gamepad(button), at: now, output: &output)
        case .gamepadButton(let button, false): output.consumed = release(.gamepad(button))
        case .scroll(let dy):
            let trigger: Trigger = dy > 0 ? .scrollUp : .scrollDown
            output.consumed = press(trigger, at: now, output: &output)
            _ = release(trigger)
        case let .mouseMoved(dx, dy):
            if pointerLocked, let camera = fpsAim {
                aim(control: camera, dx: dx, dy: dy, applyCurve: true)
                output.consumed = true
            }
        case let .gamepadStick(stick, x, y):
            sticks[stick] = (x, y)
            output.consumed = controls.contains { $0.stick == stick }
            for control in profile.controls where control.stick == stick {
                if case .dpad = control.kind { updateDPad(control) }
            }
        }
        flushMoves()
        output.events = takeEvents()
        return output
    }

    /// Advances timers (taps, swipes, repeats, macros) and gamepad aiming.
    public mutating func tick(at now: TimeInterval) -> [TouchEvent] {
        let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
        lastTick = now
        runDue(until: now)
        if dt > 0 {
            for control in profile.controls where control.stick != nil && isActive(control) {
                guard case .aim = control.kind, let stick = control.stick, let value = sticks[stick] else { continue }
                let magnitude = hypot(value.x, value.y)
                guard magnitude > Self.stickDeadzone else { continue }
                let scale = (magnitude - Self.stickDeadzone) / (1 - Self.stickDeadzone) / magnitude
                aim(control: control, dx: value.x * scale * Self.stickAimSpeed * dt,
                    dy: -value.y * scale * Self.stickAimSpeed * dt, applyCurve: false)
            }
        }
        flushMoves()
        return takeEvents()
    }

    /// Lifts every touch (window lost focus, profile switched).
    public mutating func reset() -> [TouchEvent] {
        schedule.removeAll()
        pressed.removeAll()
        held.removeAll()
        adsActive = false
        pointerLocked = false
        flushMoves()
        while let touch = touches.last { lift(touch.id) }
        return takeEvents()
    }

    /// Called by the host when macOS pointer lock is engaged or released
    /// (click into the window, toggle key, focus loss).
    public mutating func setPointerLocked(_ locked: Bool) -> [TouchEvent] {
        guard profile.fps != nil, locked != pointerLocked else { return [] }
        pointerLocked = locked
        // Leave the layer: lift touches of controls that are no longer active.
        for (controlID, touchID) in held {
            guard let control = profile.controls.first(where: { $0.id == controlID }), !isActive(control) || isFPSAim(control) else { continue }
            lift(touchID)
            held[controlID] = nil
            if case .ads = control.kind { adsActive = false }
        }
        if !locked { adsActive = false }
        if locked, let camera = fpsAim, case let .aim(area, _, _, _, _, _, _) = camera.kind {
            held[camera.id] = down(area.center)
        }
        flushMoves()
        return takeEvents()
    }

    public mutating func resize(width: Double, height: Double) -> [TouchEvent] {
        let events = reset()
        self.width = width
        self.height = height
        return events
    }

    public var activeTouchCount: Int { touches.count }

    // MARK: Triggers

    private var controls: [Control] { profile.controls }

    private var fpsAim: Control? {
        guard let id = profile.fps?.aimControl else { return nil }
        return profile.controls.first { $0.id == id }
    }

    private func isFPSAim(_ control: Control) -> Bool { control.id == profile.fps?.aimControl }

    private func isActive(_ control: Control) -> Bool {
        guard profile.fps != nil, let layer = control.layer else { return true }
        return pointerLocked ? layer == .locked : layer == .cursor
    }

    private mutating func press(_ trigger: Trigger, at now: TimeInterval, output: inout Output) -> Bool {
        if let fps = profile.fps, trigger == fps.cursorToggle {
            output.pointerLock = !pointerLocked
            events += setPointerLocked(!pointerLocked)
            return true
        }
        guard !pressed.contains(trigger) || trigger.isMomentary else { return true }
        let matches = controls.filter { isActive($0) && $0.allTriggers.contains(trigger) }
        // In cursor mode an unbound left click is a normal touch at the cursor (handled by the host).
        guard !matches.isEmpty else { return false }
        pressed.insert(trigger)
        for control in matches { activate(control, trigger: trigger, at: now) }
        return true
    }

    private mutating func release(_ trigger: Trigger) -> Bool {
        guard pressed.remove(trigger) != nil else {
            return profile.fps?.cursorToggle == trigger
        }
        for control in controls where control.allTriggers.contains(trigger) {
            switch control.kind {
            case .hold:
                if let touch = held.removeValue(forKey: control.id) { lift(touch) }
            case .ads(_, let toggle) where !toggle:
                if let touch = held.removeValue(forKey: control.id) { lift(touch) }
                adsActive = false
            case .dpad:
                updateDPad(control)
            default:
                break
            }
        }
        return true
    }

    private mutating func activate(_ control: Control, trigger: Trigger, at now: TimeInterval) {
        switch control.kind {
        case .tap(let point):
            tap(point, at: now)
        case .hold(let point):
            if held[control.id] == nil { held[control.id] = down(point) }
        case let .ads(point, toggle):
            if toggle {
                tap(point, at: now)
                adsActive.toggle()
            } else if held[control.id] == nil {
                held[control.id] = down(point)
                adsActive = true
            }
        case .dpad:
            updateDPad(control)
        case .aim:
            break
        case let .swipe(from, to, ms):
            guard let touch = down(from) else { return }
            let steps = max(2, ms / Self.swipeStepMilliseconds)
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let time = now + Double(ms) / 1000 * t
                enqueue(time, .move(touch: touch, x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
            enqueue(now + Double(ms) / 1000, .lift(touch: touch))
        case let .repeatTap(point, interval):
            tap(point, at: now)
            enqueue(now + Double(interval) / 1000, .repeatTap(control: control.id, trigger: trigger))
        case .macro:
            runMacroStep(control, index: 0, at: now)
        }
    }

    private mutating func tap(_ point: NormalizedPoint, at now: TimeInterval) {
        guard let touch = down(point) else { return }
        enqueue(now + Double(Self.tapDurationMilliseconds) / 1000, .lift(touch: touch))
    }

    private mutating func runMacroStep(_ control: Control, index: Int, at now: TimeInterval) {
        guard case .macro(let steps) = control.kind, index < steps.count else { return }
        let step = steps[index]
        switch step {
        case .tap(let point): tap(point, at: now)
        case let .hold(point, ms):
            if let touch = down(point) { enqueue(now + Double(ms) / 1000, .lift(touch: touch)) }
        case .wait: break
        }
        enqueue(now + Double(step.duration) / 1000, .macroStep(control: control.id, index: index + 1))
    }

    // MARK: D-pad

    private mutating func updateDPad(_ control: Control) {
        guard case let .dpad(center, radius, up, down, left, right, stick) = control.kind else { return }
        var vx = (pressed.contains(right) ? 1.0 : 0) - (pressed.contains(left) ? 1.0 : 0)
        var vy = (pressed.contains(down) ? 1.0 : 0) - (pressed.contains(up) ? 1.0 : 0)
        let length = hypot(vx, vy)
        if length > 0 {
            vx /= length
            vy /= length
        } else if let stick, let value = sticks[stick], hypot(value.x, value.y) > Self.stickDeadzone {
            let magnitude = min(hypot(value.x, value.y), 1)
            let scale = (magnitude - Self.stickDeadzone) / (1 - Self.stickDeadzone) / hypot(value.x, value.y)
            vx = value.x * scale
            vy = -value.y * scale
        }
        let active = vx != 0 || vy != 0
        if !active || !isActive(control) {
            if let touch = held.removeValue(forKey: control.id) { lift(touch) }
            return
        }
        let radiusPixels = radius * height
        let targetX = center.x * width + vx * radiusPixels
        let targetY = center.y * height + vy * radiusPixels
        if held[control.id] == nil {
            // Touch down at the joystick centre, then drag: dynamic joysticks need the drag.
            held[control.id] = self.down(center)
        }
        if let touch = held[control.id] { move(touch, x: targetX, y: targetY) }
    }

    // MARK: Aim (mouse-look)

    private mutating func aim(control: Control, dx: Double, dy: Double, applyCurve: Bool) {
        guard case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, _) = control.kind, isActive(control) else { return }
        var x = dx, y = dy
        let magnitude = hypot(x, y)
        if applyCurve {
            guard magnitude > deadzone, magnitude > 0 else { return }
            if exponent != 1 {
                let curved = pow(magnitude, exponent)
                x *= curved / magnitude
                y *= curved / magnitude
            }
        }
        let s = adsActive ? ads : sensitivity
        let scale = height / Self.referenceHeight
        var deltaX = x * s.x * scale
        var deltaY = (invertY ? -y : y) * s.y * scale

        let minX = area.minX * width + 1, maxX = area.maxX * width - 1
        let minY = area.minY * height + 1, maxY = area.maxY * height - 1
        if held[control.id] == nil { held[control.id] = down(area.center) }

        // Re-centering: when the drag would leave the camera area, finish the
        // drag at the edge, lift, touch down again at the centre and carry on
        // with the rest of the movement, so the camera turns without limit.
        for _ in 0..<8 {
            guard let touchID = held[control.id], let touch = touches.first(where: { $0.id == touchID }) else { return }
            let targetX = touch.x + deltaX, targetY = touch.y + deltaY
            if (minX...maxX).contains(targetX) && (minY...maxY).contains(targetY) {
                move(touchID, x: targetX, y: targetY)
                return
            }
            var t = 1.0
            if targetX > maxX { t = min(t, (maxX - touch.x) / deltaX) }
            if targetX < minX { t = min(t, (minX - touch.x) / deltaX) }
            if targetY > maxY { t = min(t, (maxY - touch.y) / deltaY) }
            if targetY < minY { t = min(t, (minY - touch.y) / deltaY) }
            t = max(0, min(t, 1))
            move(touchID, x: touch.x + deltaX * t, y: touch.y + deltaY * t)
            lift(touchID)
            held[control.id] = down(area.center)
            deltaX *= 1 - t
            deltaY *= 1 - t
        }
    }

    // MARK: Scheduling

    private mutating func enqueue(_ time: TimeInterval, _ action: Action) {
        scheduleOrder += 1
        schedule.append(Scheduled(time: time, order: scheduleOrder, action: action))
    }

    private mutating func runDue(until now: TimeInterval) {
        while true {
            let due = schedule.enumerated().filter { $0.element.time <= now }
            guard let next = due.min(by: { ($0.element.time, $0.element.order) < ($1.element.time, $1.element.order) }) else { return }
            schedule.remove(at: next.offset)
            let time = next.element.time
            switch next.element.action {
            case .lift(let touch):
                lift(touch)
            case let .move(touch, x, y):
                move(touch, x: x * width, y: y * height)
            case let .repeatTap(controlID, trigger):
                guard pressed.contains(trigger), let control = controls.first(where: { $0.id == controlID }),
                      case let .repeatTap(point, interval) = control.kind, isActive(control) else { continue }
                tap(point, at: time)
                enqueue(time + Double(interval) / 1000, .repeatTap(control: controlID, trigger: trigger))
            case let .macroStep(controlID, index):
                guard let control = controls.first(where: { $0.id == controlID }) else { continue }
                runMacroStep(control, index: index, at: time)
            }
        }
    }

    // MARK: Touches → MotionEvents

    private mutating func down(_ point: NormalizedPoint) -> Int? {
        guard touches.count < KeymapProfile.maxPointers else { return nil }
        flushMoves()
        let used = Set(touches.map(\.pointerID))
        let pointerID = (0..<UInt32(KeymapProfile.maxPointers)).first { !used.contains($0) }!
        let touch = Touch(id: nextTouchID, pointerID: pointerID, x: point.x * width, y: point.y * height)
        nextTouchID += 1
        touches.append(touch)
        emit(touches.count == 1 ? .down : .pointerDown, index: touches.count - 1)
        return touch.id
    }

    private mutating func move(_ touchID: Int, x: Double, y: Double) {
        guard let index = touches.firstIndex(where: { $0.id == touchID }) else { return }
        guard touches[index].x != x || touches[index].y != y else { return }
        touches[index].x = x
        touches[index].y = y
        movedSinceFlush = true
    }

    private mutating func lift(_ touchID: Int) {
        guard let index = touches.firstIndex(where: { $0.id == touchID }) else { return }
        flushMoves()
        emit(touches.count == 1 ? .up : .pointerUp, index: index)
        touches.remove(at: index)
    }

    private mutating func flushMoves() {
        guard movedSinceFlush, !touches.isEmpty else {
            movedSinceFlush = false
            return
        }
        movedSinceFlush = false
        emit(.move, index: 0)
    }

    private mutating func emit(_ action: TouchAction, index: Int) {
        events.append(TouchEvent(displayID: displayID, action: action, actionIndex: UInt8(index),
                                 pointers: touches.map { TouchPointer(id: $0.pointerID, x: Float($0.x), y: Float($0.y)) }))
    }

    private mutating func takeEvents() -> [TouchEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
}

extension Control {
    var stick: GamepadStick? {
        switch kind {
        case let .dpad(_, _, _, _, _, _, stick): stick
        case let .aim(_, _, _, _, _, _, stick): stick
        default: nil
        }
    }
}
