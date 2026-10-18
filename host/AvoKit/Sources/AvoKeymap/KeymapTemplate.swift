import Foundation

/// Ready-made starting layouts for common kinds of landscape games, inserted
/// from the key mapping editor. The positions are guesses at a typical HUD:
/// the player drags each control onto the game's own button afterwards.
public enum KeymapTemplate: String, CaseIterable, Sendable {
    case fps, moba, racing, platformer

    /// What a template brings: its controls plus FPS mode for the eye. The
    /// hero point is not part of a layout: it is where the game's camera keeps
    /// the character, which the player sets for their game.
    public struct Layout: Sendable {
        public var controls: [Control]
        public var fps: FPSSettings?
    }

    /// The template for a display of `aspect` (width / height). Positions
    /// are fractions of the screen, so today's layouts fit any aspect.
    public func layout(aspect: Double) -> Layout {
        func tap(_ id: String, _ x: Double, _ y: Double, _ triggers: [Trigger], layer: ControlLayer? = nil,
                 size: Double? = nil) -> Control {
            Control(id: id, kind: .tap(NormalizedPoint(x, y)), triggers: triggers, layer: layer, size: size)
        }
        func dpad(up: KeyName, down: KeyName, left: KeyName, right: KeyName) -> Control {
            Control(id: "move", kind: .dpad(center: NormalizedPoint(0.14, 0.72), radius: Control.defaultJoystickRadius,
                                            up: .key(up), down: .key(down), left: .key(left), right: .key(right), stick: .left))
        }
        func skill(_ id: String, _ x: Double, _ y: Double, _ key: KeyName) -> Control {
            Control(id: id, kind: .smartCast(NormalizedPoint(x, y), radius: Control.defaultCastRadius, reach: Control.defaultCastReach),
                    triggers: [.key(key)], size: 0.045)
        }
        switch self {
        case .fps:
            // The camera swipes over most of the right side at full height,
            // from the area's centre, which no button below sits on.
            let eye = Control(id: "eye", kind: .aim(area: Control.defaultEyeArea,
                                                    sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 0.6, y: 0.6),
                                                    exponent: 1, deadzone: 0, invertY: false, stick: .right))
            // Fire and aim-down-sights act while the mouse is locked, so a
            // click on a free cursor still reaches the game's menus.
            return Layout(controls: [
                dpad(up: .w, down: .s, left: .a, right: .d),
                eye,
                tap("fire", 0.86, 0.6, [.mouse(.left)], layer: .locked, size: 0.05),
                Control(id: "ads", kind: .ads(NormalizedPoint(0.93, 0.42), toggle: false), triggers: [.mouse(.right)], layer: .locked),
                tap("jump", 0.93, 0.74, [.key(.space)]),
                tap("crouch", 0.86, 0.9, [.key(.c)]),
                tap("reload", 0.76, 0.9, [.key(.r)]),
            ], fps: FPSSettings(aimControl: eye.id))
        case .moba:
            // A Mobile Legends / Arena of Valor style HUD: the joystick on the
            // left, the basic attack in the bottom right corner with the
            // skills in an arc around it, spell and recall to their left.
            return Layout(controls: [
                Control(id: "move", kind: .mobaMove(center: NormalizedPoint(0.14, 0.72), radius: Control.defaultJoystickRadius),
                        triggers: [.mouse(.right)]),
                tap("attack", 0.89, 0.8, [.key(.space)], size: 0.07),
                skill("skill-1", 0.74, 0.87, .q),
                skill("skill-2", 0.77, 0.68, .w),
                skill("skill-3", 0.86, 0.58, .e),
                skill("skill-4", 0.95, 0.52, .r),
                tap("spell", 0.64, 0.89, [.key(.f)]),
                tap("recall", 0.53, 0.89, [.key(.b)]),
            ])
        case .racing:
            // Steering buttons on the left, pedals on the right; the arrow
            // keys work as well as WASD.
            return Layout(controls: [
                tap("steer-left", 0.08, 0.76, [.key(.a), .key(.left)], size: 0.06),
                tap("steer-right", 0.22, 0.76, [.key(.d), .key(.right)], size: 0.06),
                tap("accelerate", 0.9, 0.76, [.key(.w), .key(.up)], size: 0.06),
                tap("brake", 0.77, 0.8, [.key(.s), .key(.down)], size: 0.05),
                tap("nitro", 0.84, 0.55, [.key(.space)]),
            ])
        case .platformer:
            return Layout(controls: [
                dpad(up: .w, down: .s, left: .a, right: .d),
                tap("jump", 0.9, 0.76, [.key(.space)], size: 0.05),
                tap("action-1", 0.79, 0.84, [.key(.j)]),
                tap("action-2", 0.83, 0.6, [.key(.k)]),
            ])
        }
    }

    /// The result of inserting a template.
    public struct Insertion: Sendable {
        public var profile: KeymapProfile
        /// IDs of the template's controls that went in.
        public var added: [String]
        /// Added controls left without a trigger, because the profile already
        /// used theirs; the player gives them a key in the editor.
        public var unbound: [String]
        /// Template controls left out: an eye when the profile has one, or a
        /// D-pad whose keys are in use.
        public var skipped: [String]
    }

    /// Puts the template into `profile`. Replacing swaps every control (and
    /// the FPS settings) for the template's; adding keeps every existing
    /// control exactly as it is, and the template's controls give way
    /// wherever they would clash with them. Either way the player's hero
    /// point stays.
    public func insert(into profile: KeymapProfile, replacing: Bool, aspect: Double) -> Insertion {
        let layout = layout(aspect: aspect)
        var result = profile
        if replacing {
            result.controls = layout.controls
            result.fps = layout.fps
            return Insertion(profile: result, added: layout.controls.map(\.id), unbound: [], skipped: [])
        }

        var used = Set(profile.controls.flatMap(\.allTriggers))
        if let toggle = profile.fps?.cursorToggle { used.insert(toggle) }
        let hasEye = profile.controls.contains { if case .aim = $0.kind { true } else { false } }
        var added: [String] = [], unbound: [String] = [], skipped: [String] = []
        var eyeID: String?
        for var control in layout.controls {
            let isEye = { if case .aim = control.kind { true } else { false } }()
            let isDPad = { if case .dpad = control.kind { true } else { false } }()
            // One eye per layout (FPS mode drives one aim control), and a
            // D-pad cannot drop a direction.
            if (isEye && hasEye) || (isDPad && control.allTriggers.contains(where: used.contains)) {
                skipped.append(control.id)
                continue
            }
            var n = 1
            let base = control.id
            while result.controls.contains(where: { $0.id == control.id }) {
                n += 1
                control.id = "\(base)-\(n)"
            }
            control.triggers.removeAll(where: used.contains)
            if control.triggers.isEmpty, !isEye, !isDPad { unbound.append(control.id) }
            used.formUnion(control.allTriggers)
            if isEye { eyeID = control.id }
            added.append(control.id)
            result.controls.append(control)
        }
        if result.fps == nil, let fps = layout.fps, let eyeID {
            // The usual key that locks the mouse, or the first free fallback.
            let toggle = [fps.cursorToggle, .key(.grave), .key(.f9), .key(.f10)].first { !used.contains($0) } ?? fps.cursorToggle
            result.fps = FPSSettings(cursorToggle: toggle, aimControl: eyeID)
        }
        return Insertion(profile: result, added: added, unbound: unbound, skipped: skipped)
    }
}
