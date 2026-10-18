import AppKit

/// A short message over the game that fades away (mouse lock and the like),
/// optionally with one button ("Show in Finder" after a screenshot).
final class NoticeView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var perform: (() -> Void)?
    private var hiding: DispatchWorkItem?
    /// Whether the button may take a click now. False while the key mapping
    /// is in charge (Game Mode): then every click on the game belongs to it.
    var acceptsClicks: () -> Bool = { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The button is drawn for the dark plate in light mode too.
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 10
        alphaValue = 0
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        // Typing stays with the Android display.
        button.refusesFirstResponder = true
        button.target = self
        button.action = #selector(performAction)
        button.isHidden = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Never in the way of clicks on the game, except on the button while it shows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard perform != nil, alphaValue > 0, acceptsClicks(), let hit = super.hitTest(point) else { return nil }
        return hit === button || hit.isDescendant(of: button) ? hit : nil
    }

    /// Shows `text`; with `action`, a button that runs `perform` (the notice
    /// then stays a little longer, and while the pointer is over it).
    func show(_ text: String, action: String? = nil, perform: (() -> Void)? = nil) {
        label.stringValue = text
        // While the game takes the clicks, only the text: a button there
        // would be one that clicks cannot reach. (`hitTest` still checks, as
        // Game Mode can come on while it shows.)
        self.perform = action != nil && acceptsClicks() ? perform : nil
        button.title = action ?? ""
        button.isHidden = self.perform == nil
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        hide(after: self.perform == nil ? 3 : 6)
    }

    private func hide(after seconds: Double) {
        hiding?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
            self?.perform = nil
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func performAction() {
        let action = perform
        hide(after: 0)
        action?()
    }

    override func mouseEntered(with event: NSEvent) {
        // Reaching for the button keeps it there.
        if perform != nil { hiding?.cancel() }
    }

    override func mouseExited(with event: NSEvent) {
        if perform != nil { hide(after: 1.5) }
    }
}
