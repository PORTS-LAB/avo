import AppKit
import AvoKeymap
import UniformTypeIdentifiers

/// Transparent editor over a game window (spec §5: "Tekan Cmd+Shift+K di
/// jendela game untuk membuka editor overlay transparan").
///
/// Add a control from the toolbar, drag it into place, then press the key,
/// mouse button or gamepad button it should respond to. Delete removes the
/// selected control. Profiles save per package and can be exported/imported.
@MainActor
final class KeymapOverlayWindow: NSPanel {
    private let editor: KeymapEditorView
    private weak var parentGameWindow: NSWindow?

    var isEditing: Bool { isVisible }

    init(parent: NSWindow, view: DisplayView, package: String, profile: KeymapProfile?,
         onSave: @escaping (KeymapProfile) -> String?) {
        editor = KeymapEditorView(displayRect: { [weak view] in view?.displayRect ?? .zero },
                                  profile: profile ?? KeymapProfile(package: package, name: "My layout", controls: []),
                                  onSave: onSave)
        parentGameWindow = parent
        super.init(contentRect: parent.contentLayoutRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = parent.level
        isReleasedWhenClosed = false
        contentView = editor
        editor.onClose = { [weak self] in self?.close() }
    }

    override var canBecomeKey: Bool { true }

    func show() {
        guard let parent = parentGameWindow else { return }
        setFrame(parent.convertToScreen(parent.contentLayoutRect), display: true)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(editor)
    }

    override func close() {
        parentGameWindow?.removeChildWindow(self)
        super.close()
    }

    /// Key presses routed here while the editor is open.
    func assign(_ trigger: Trigger, down: Bool) -> Bool {
        if down { editor.assign(trigger) }
        return true
    }
}

@MainActor
final class KeymapEditorView: NSView {
    private var profile: KeymapProfile
    private var selected: String?
    private var dragOffset: CGPoint?
    /// Which D-pad direction the next key press assigns, per control.
    private var dpadStep: [String: Int] = [:]
    private let displayRect: () -> CGRect
    private let onSave: (KeymapProfile) -> String?
    var onClose: (() -> Void)?
    private let toolbar = NSStackView()
    private let status = NSTextField(labelWithString: "")

    init(displayRect: @escaping () -> CGRect, profile: KeymapProfile, onSave: @escaping (KeymapProfile) -> String?) {
        self.displayRect = displayRect
        self.profile = profile
        self.onSave = onSave
        super.init(frame: .zero)
        buildToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    private func buildToolbar() {
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            return button
        }
        let fps = NSButton(checkboxWithTitle: "FPS mode", target: self, action: #selector(toggleFPS(_:)))
        fps.state = profile.fps == nil ? .off : .on
        for view in [button("+ Tap", #selector(addTap)), button("+ Hold", #selector(addHold)), button("+ D-pad", #selector(addDPad)),
                     button("+ Aim", #selector(addAim)), button("+ Swipe", #selector(addSwipe)), fps,
                     button("Import…", #selector(importProfile)), button("Export…", #selector(exportProfile)),
                     button("Save", #selector(save)), button("Done", #selector(close))] {
            toolbar.addArrangedSubview(view)
        }
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        toolbar.layer?.cornerRadius = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .white
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        addSubview(status)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setStatus("Drag controls into place, select one and press its key. Delete removes it.")
    }

    private func setStatus(_ text: String) {
        status.stringValue = text
    }

    // MARK: Geometry

    private func point(_ p: NormalizedPoint) -> CGPoint {
        let rect = displayRect()
        return CGPoint(x: rect.minX + p.x * rect.width, y: rect.maxY - p.y * rect.height)
    }

    private func normalized(_ p: CGPoint) -> NormalizedPoint {
        let rect = displayRect()
        return NormalizedPoint(min(max((p.x - rect.minX) / rect.width, 0), 1), min(max((rect.maxY - p.y) / rect.height, 0), 1))
    }

    private func anchor(of control: Control) -> NormalizedPoint {
        switch control.kind {
        case .tap(let p), .hold(let p), .ads(let p, _), .repeatTap(let p, _): p
        case let .dpad(center, _, _, _, _, _, _): center
        case let .aim(area, _, _, _, _, _, _): area.center
        case let .swipe(from, _, _): from
        case .macro(let steps):
            steps.lazy.compactMap { if case .tap(let p) = $0 { p } else if case .hold(let p, _) = $0 { p } else { nil } }.first
                ?? NormalizedPoint(0.5, 0.5)
        }
    }

    private func move(_ control: inout Control, to p: NormalizedPoint) {
        switch control.kind {
        case .tap: control.kind = .tap(p)
        case .hold: control.kind = .hold(p)
        case .ads(_, let toggle): control.kind = .ads(p, toggle: toggle)
        case .repeatTap(_, let interval): control.kind = .repeatTap(p, intervalMilliseconds: interval)
        case let .dpad(_, radius, up, down, left, right, stick):
            control.kind = .dpad(center: p, radius: radius, up: up, down: down, left: left, right: right, stick: stick)
        case let .aim(area, s, ads, e, dz, inv, stick):
            let w = area.maxX - area.minX, h = area.maxY - area.minY
            let minX = min(max(p.x - w / 2, 0), 1 - w), minY = min(max(p.y - h / 2, 0), 1 - h)
            control.kind = .aim(area: NormalizedRect(minX, minY, minX + w, minY + h), sensitivity: s, adsSensitivity: ads,
                                exponent: e, deadzone: dz, invertY: inv, stick: stick)
        case let .swipe(from, to, ms):
            let dx = to.x - from.x, dy = to.y - from.y
            control.kind = .swipe(from: p, to: NormalizedPoint(min(max(p.x + dx, 0), 1), min(max(p.y + dy, 0), 1)), milliseconds: ms)
        case .macro: break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        for control in profile.controls {
            let isSelected = control.id == selected
            let color = isSelected ? NSColor.systemYellow : NSColor(calibratedRed: 0.85, green: 0.91, blue: 0.65, alpha: 1)
            switch control.kind {
            case let .aim(area, _, _, _, _, _, _):
                let a = point(NormalizedPoint(area.minX, area.minY)), b = point(NormalizedPoint(area.maxX, area.maxY))
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
                path.setLineDash([8, 6], count: 2, phase: 0)
                path.lineWidth = 2
                color.setStroke()
                path.stroke()
                label("Mouse aim", at: CGPoint(x: rect.midX, y: rect.midY), color: color)
            case let .dpad(center, radius, up, down, left, right, _):
                let c = point(center)
                let r = radius * displayRect().height
                circle(at: c, radius: r, color: color, filled: false)
                label(short(up), at: CGPoint(x: c.x, y: c.y + r * 0.7), color: color)
                label(short(down), at: CGPoint(x: c.x, y: c.y - r * 0.7), color: color)
                label(short(left), at: CGPoint(x: c.x - r * 0.7, y: c.y), color: color)
                label(short(right), at: CGPoint(x: c.x + r * 0.7, y: c.y), color: color)
            case let .swipe(from, to, _):
                let a = point(from), b = point(to)
                let path = NSBezierPath()
                path.move(to: a)
                path.line(to: b)
                path.lineWidth = 3
                color.setStroke()
                path.stroke()
                circle(at: a, radius: 18, color: color, filled: true)
                label(control.triggers.map(short).joined(separator: " "), at: a, color: .black)
            default:
                let c = point(anchor(of: control))
                circle(at: c, radius: 20, color: color, filled: true)
                let text = control.triggers.isEmpty ? "?" : control.triggers.map(short).joined(separator: " ")
                label(text, at: c, color: .black)
            }
        }
    }

    private func circle(at center: CGPoint, radius: CGFloat, color: NSColor, filled: Bool) {
        let path = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if filled {
            color.withAlphaComponent(0.9).setFill()
            path.fill()
        }
        path.lineWidth = 2
        color.setStroke()
        path.stroke()
    }

    private func label(_ text: String, at center: CGPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }

    private func short(_ trigger: Trigger) -> String {
        switch trigger {
        case .key(let key): key.rawValue
        case .mouse(.left): "LMB"
        case .mouse(.right): "RMB"
        case .mouse(let button): button.rawValue
        case .scrollUp: "Wheel↑"
        case .scrollDown: "Wheel↓"
        case .gamepad(let button): "Pad " + button.rawValue
        }
    }

    // MARK: Editing

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        selected = profile.controls.last { hypot(point(anchor(of: $0)).x - p.x, point(anchor(of: $0)).y - p.y) < 28 }?.id
        if let id = selected, let control = profile.controls.first(where: { $0.id == id }) {
            let a = point(anchor(of: control))
            dragOffset = CGPoint(x: a.x - p.x, y: a.y - p.y)
            setStatus("Press the key or button for “\(id)”.")
        } else {
            dragOffset = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = selected, let offset = dragOffset, let index = profile.controls.firstIndex(where: { $0.id == id }) else { return }
        let p = convert(event.locationInWindow, from: nil)
        move(&profile.controls[index], to: normalized(CGPoint(x: p.x + offset.x, y: p.y + offset.y)))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { assign(.mouse(.right)) }
    override func otherMouseDown(with event: NSEvent) {
        if let button = MouseButton(buttonNumber: event.buttonNumber) { assign(.mouse(button)) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x33 || event.keyCode == 0x75, let id = selected { // Delete / Forward Delete
            profile.controls.removeAll { $0.id == id }
            selected = nil
            needsDisplay = true
            return
        }
        if event.keyCode == 0x35 && selected == nil { // Esc closes the editor
            close()
            return
        }
        if let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) { assign(.key(key)) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0 else { return }
        assign(event.scrollingDeltaY > 0 ? .scrollUp : .scrollDown)
    }

    func assign(_ trigger: Trigger) {
        guard let id = selected, let index = profile.controls.firstIndex(where: { $0.id == id }) else { return }
        // A trigger belongs to one control: move it if it was bound elsewhere.
        for i in profile.controls.indices where i != index { profile.controls[i].triggers.removeAll { $0 == trigger } }
        if case let .dpad(center, radius, up, down, left, right, stick) = profile.controls[index].kind {
            // D-pads take four presses in order: up, left, down, right.
            var keys = [up, left, down, right]
            let step = dpadStep[id, default: 0]
            keys[step] = trigger
            profile.controls[index].kind = .dpad(center: center, radius: radius, up: keys[0], down: keys[2],
                                                 left: keys[1], right: keys[3], stick: stick)
            dpadStep[id] = (step + 1) % 4
            setStatus("D-pad: the next press sets \(["left", "down", "right", "up"][step]).")
        } else {
            profile.controls[index].triggers = [trigger]
            setStatus("“\(id)” responds to \(short(trigger)).")
        }
        needsDisplay = true
    }

    private func add(_ kind: Control.Kind, prefix: String, layer: ControlLayer? = nil) {
        var n = 1
        while profile.controls.contains(where: { $0.id == "\(prefix)-\(n)" }) { n += 1 }
        let id = "\(prefix)-\(n)"
        profile.controls.append(Control(id: id, kind: kind, layer: layer))
        selected = id
        setStatus("Press the key or button for “\(id)”.")
        needsDisplay = true
    }

    @objc private func addTap() { add(.tap(NormalizedPoint(0.5, 0.5)), prefix: "tap") }
    @objc private func addHold() { add(.hold(NormalizedPoint(0.5, 0.5)), prefix: "hold") }
    @objc private func addSwipe() {
        add(.swipe(from: NormalizedPoint(0.5, 0.6), to: NormalizedPoint(0.5, 0.4), milliseconds: 150), prefix: "swipe")
    }

    @objc private func addDPad() {
        add(.dpad(center: NormalizedPoint(0.15, 0.7), radius: 0.12, up: .key(.w), down: .key(.s), left: .key(.a), right: .key(.d),
                  stick: .left), prefix: "move")
    }

    @objc private func addAim() {
        guard !profile.controls.contains(where: { if case .aim = $0.kind { true } else { false } }) else {
            setStatus("This profile already has an aim area.")
            return
        }
        add(.aim(area: NormalizedRect(0.45, 0.05, 1.0, 0.75), sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 0.6, y: 0.6),
                 exponent: 1, deadzone: 0, invertY: false, stick: .right), prefix: "camera")
    }

    @objc private func toggleFPS(_ sender: NSButton) {
        if sender.state == .on {
            guard let aim = profile.controls.first(where: { if case .aim = $0.kind { true } else { false } }) else {
                sender.state = .off
                setStatus("Add an aim area first; FPS mode moves it with the mouse.")
                return
            }
            profile.fps = FPSSettings(aimControl: aim.id)
            setStatus("FPS mode: click in the game to capture the mouse, Option toggles the cursor.")
        } else {
            profile.fps = nil
        }
    }

    @objc private func save() {
        let problems = profile.validate()
        guard problems.isEmpty else {
            setStatus(problems.first ?? "This profile has problems.")
            return
        }
        if let error = onSave(profile) { setStatus("Could not save: \(error)") } else { setStatus("Saved.") }
    }

    @objc private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.package).json"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? profile.encoded() else { return }
        try? data.write(to: url)
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            var imported = try KeymapProfile.decode(data)
            imported.package = profile.package
            let problems = imported.validate()
            guard problems.isEmpty else {
                setStatus(problems.first ?? "This profile has problems.")
                return
            }
            profile = imported
            needsDisplay = true
            setStatus("Imported “\(imported.name)”. Save to use it.")
        } catch {
            setStatus("Not a keymap profile: \(error.localizedDescription)")
        }
    }

    @objc private func close() { onClose?() }
}
