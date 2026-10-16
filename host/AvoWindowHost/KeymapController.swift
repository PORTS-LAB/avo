import AppKit
import AvoKeymap
import AvoKit
import AvoProtocol
import GameController
import os

/// Runs the keymapping profile for one window (spec §5 and §5a): keys,
/// mouse buttons and gamepads become touches, FPS mode captures the pointer
/// and reads raw mouse movement.
@MainActor
final class KeymapController {
    private let package: String
    private let displayID: UInt32
    private weak var view: DisplayView?
    private let send: (InputRecord) -> Void
    private let userProfileURL: URL
    private let bundledProfileURL: URL?
    private(set) var profile: KeymapProfile?
    private var engine: KeymapEngine?
    private var displayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var overlay: KeymapOverlayWindow?
    private(set) var isPointerLocked = false
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Keymap")

    init(package: String, displayID: UInt32, view: DisplayView, hostApplication: URL?, send: @escaping (InputRecord) -> Void) {
        self.package = package
        self.displayID = displayID
        self.view = view
        self.send = send
        userProfileURL = AvoPaths().keymap(for: package)
        bundledProfileURL = hostApplication?.appending(path: "Contents/Resources/profiles/keymaps/\(package).json")
        load()
        observeGamepads()
    }

    /// The user's profile wins over the community profile shipped with Avo.
    private func load() {
        for url in [userProfileURL, bundledProfileURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let profile = try KeymapProfile.decode(data)
                let problems = profile.validate()
                guard problems.isEmpty else {
                    logger.error("ignoring \(url.lastPathComponent, privacy: .public): \(problems.joined(separator: "; "), privacy: .public)")
                    continue
                }
                apply(profile)
                return
            } catch {
                logger.error("cannot read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func apply(_ profile: KeymapProfile?) {
        if var engine { emit(engine.reset()); self.engine = engine }
        unlockPointer()
        self.profile = profile
        guard let profile, let view else {
            engine = nil
            stopTicking()
            return
        }
        let size = view.displaySize
        engine = KeymapEngine(profile: profile, displayID: displayID, width: size.width, height: size.height)
        startTicking()
    }

    func save(_ profile: KeymapProfile) throws {
        try FileManager.default.createDirectory(at: userProfileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try profile.encoded().write(to: userProfileURL, options: .atomic)
        apply(profile)
    }

    // MARK: Input from DisplayView (returns true when consumed)

    func key(_ key: KeyName, down: Bool, isRepeat: Bool) -> Bool {
        if overlay?.isEditing == true { return overlay?.assign(.key(key), down: down) ?? false }
        guard !isRepeat else { return engine?.profile.controls.contains { $0.allTriggers.contains(.key(key)) } == true }
        return handle(down ? .keyDown(key) : .keyUp(key))
    }

    func mouse(_ button: MouseButton, down: Bool) -> Bool {
        guard let engine, overlay?.isEditing != true else { return false }
        // FPS profiles capture the pointer on the first click into the window.
        if engine.profile.fps != nil, !isPointerLocked, down, button == .left, !hasCursorLayerBinding(.mouse(.left)) {
            lockPointer()
            return true
        }
        return handle(down ? .mouseDown(button) : .mouseUp(button))
    }

    func scroll(_ deltaY: Double) -> Bool {
        guard engine != nil, deltaY != 0 else { return false }
        return handle(.scroll(dy: deltaY))
    }

    func resize(width: Double, height: Double) {
        guard var engine else { return }
        emit(engine.resize(width: width, height: height))
        self.engine = engine
    }

    func focusLost() {
        unlockPointer()
        guard var engine else { return }
        emit(engine.reset())
        self.engine = engine
    }

    func stop() {
        focusLost()
        stopTicking()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        overlay?.close()
    }

    private func hasCursorLayerBinding(_ trigger: Trigger) -> Bool {
        profile?.controls.contains { $0.layer == .cursor && $0.allTriggers.contains(trigger) } == true
    }

    private func handle(_ input: KeymapEngine.Input) -> Bool {
        guard var engine else { return false }
        let output = engine.handle(input, at: CACurrentMediaTime())
        self.engine = engine
        emit(output.events)
        if let lock = output.pointerLock {
            if lock { lockPointer() } else { unlockPointer() }
        }
        return output.consumed
    }

    private func emit(_ events: [TouchEvent]) {
        for event in events { send(.touch(event)) }
    }

    // MARK: Timing

    private func startTicking() {
        guard displayLink == nil, let view else { return }
        let link = view.displayLink(target: TickTarget { [weak self] in self?.tick() }, selector: #selector(TickTarget.fire))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick() {
        guard var engine else { return }
        emit(engine.tick(at: CACurrentMediaTime()))
        self.engine = engine
    }

    // MARK: Pointer lock (FPS mode)

    private func lockPointer() {
        guard !isPointerLocked, let view, let window = view.window else { return }
        isPointerLocked = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        // Park the hidden cursor over the window so clicks keep landing here.
        let center = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        if let screen = window.screen {
            CGWarpMouseCursorPosition(CGPoint(x: center.x, y: screen.frame.maxY - center.y))
        }
        // Raw, unaccelerated deltas (spec §5a: "gerakan mouse mentah").
        GCMouse.current?.mouseInput?.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated { _ = self?.handle(.mouseMoved(dx: Double(dx), dy: Double(-dy))) }
        }
        if var engine {
            emit(engine.setPointerLocked(true))
            self.engine = engine
        }
    }

    private func unlockPointer() {
        guard isPointerLocked else { return }
        isPointerLocked = false
        GCMouse.current?.mouseInput?.mouseMovedHandler = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        if var engine {
            emit(engine.setPointerLocked(false))
            self.engine = engine
        }
    }

    // MARK: Gamepads (GameController.framework)

    private func observeGamepads() {
        for controller in GCController.controllers() { attach(controller) }
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue; GCController is not Sendable.
            nonisolated(unsafe) let controller = note.object as? GCController
            MainActor.assumeIsolated {
                guard let controller else { return }
                self?.attach(controller)
            }
        })
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let buttons: [(GCControllerButtonInput, GamepadButton)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftTrigger, .leftTrigger), (pad.rightTrigger, .rightTrigger),
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown), (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
            (pad.buttonMenu, .menu),
        ]
        for (input, button) in buttons {
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.gamepadButton(button, pressed: pressed) }
            }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { _ = self?.handle(.gamepadStick(.left, x: Double(x), y: Double(y))) }
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { _ = self?.handle(.gamepadStick(.right, x: Double(x), y: Double(y))) }
        }
    }

    private func gamepadButton(_ button: GamepadButton, pressed: Bool) {
        guard view?.window?.isKeyWindow == true else { return }
        _ = handle(.gamepadButton(button, pressed: pressed))
    }

    // MARK: Editor (Cmd+Shift+K)

    func toggleEditor(over window: NSWindow?) {
        guard let window, let view else { return }
        if let overlay, overlay.isVisible {
            overlay.close()
            self.overlay = nil
            return
        }
        focusLost()
        let overlay = KeymapOverlayWindow(parent: window, view: view, package: package, profile: profile) { [weak self] profile in
            do {
                try self?.save(profile)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        self.overlay = overlay
        overlay.show()
    }
}

/// CADisplayLink needs an Objective-C target.
private final class TickTarget: NSObject {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor @objc func fire() { action() }
}
