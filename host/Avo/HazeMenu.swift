import AppKit
import SwiftUI

// A menu in the haze, for what the system's context menu did on app icons
// (AppTileInteraction.swift): near black with a breath of Avo's green, icons,
// separators, the item under the pointer or the keyboard lit (in the haze's
// red for a destructive one), and a small spring as it opens. It is a
// borderless panel at the pointer, which takes the keyboard: arrows, Return
// and Space, Escape, and typing an item's first letters. A click elsewhere,
// another app, or scrolling closes it, as with a menu.
//
// Free of Avo-only types (like HazeTheme.swift), so other targets can use it.

/// One row of a haze menu.
struct HazeMenuItem: Identifiable {
    enum Role {
        case normal
        case destructive
    }

    let id = UUID()
    var title: String
    var symbol: String?
    var role: Role = .normal
    var isEnabled = true
    /// A key hint shown at the trailing edge ("⌘I").
    var shortcut: String?
    var action: @MainActor () -> Void
}

enum HazeMenuEntry: Identifiable {
    case item(HazeMenuItem)
    case separator(UUID = UUID())

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .separator(let id): id
        }
    }
}

/// What sits above the items: an icon and a name (the app the menu is for).
struct HazeMenuHeader {
    var title: String
    var icon: NSImage?
}

/// Shows one haze menu at a time.
@MainActor
final class HazeMenuPresenter {
    static let shared = HazeMenuPresenter()

    private var panel: HazeMenuPanel?
    private var state: HazeMenuState?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// The event that opened the menu: the outside-click watch lets it pass.
    private var openingEvent: TimeInterval?

    var isShown: Bool { panel != nil }

    /// Shows `entries` with its top-leading corner at `point` (screen
    /// coordinates), turned to fit on its screen. `event`: the click that
    /// opened it, if any; `byKeyboard`: the first item starts lit.
    func show(_ entries: [HazeMenuEntry], header: HazeMenuHeader? = nil, at point: NSPoint, for event: NSEvent? = nil,
              byKeyboard: Bool = false) {
        close(animated: false)
        guard entries.contains(where: { if case .item = $0 { true } else { false } }) else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        let state = HazeMenuState(entries: entries)
        state.onClose = { [weak self] in self?.close() }
        if byKeyboard { state.highlightFirst() }
        let host = NSHostingView(rootView: HazeMenuView(state: state, header: header))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let margin = HazeMenuView.margin
        // Down and to the right of the pointer, like a menu; up or to the
        // left where the screen ends.
        let flipsUp = point.y - size.height + margin < visible.minY
        let flipsLeft = point.x + size.width - margin > visible.maxX
        var origin = NSPoint(x: flipsLeft ? point.x - size.width + margin : point.x - margin,
                             y: flipsUp ? point.y - margin : point.y - size.height + margin)
        origin.x = min(max(origin.x, visible.minX - margin), visible.maxX - size.width + margin)
        origin.y = min(max(origin.y, visible.minY - margin), visible.maxY - size.height + margin)
        state.anchor = UnitPoint(x: flipsLeft ? 1 : 0, y: flipsUp ? 1 : 0)

        let panel = HazeMenuPanel(contentRect: NSRect(origin: origin, size: size))
        panel.contentView = host
        panel.onKey = { [weak state] event in state?.handle(event) ?? false }
        panel.onResignKey = { [weak self] in self?.close() }
        self.panel = panel
        self.state = state
        openingEvent = event?.timestamp
        panel.makeKeyAndOrderFront(nil)
        // After its first frame, so it springs open.
        Task { @MainActor in state.shown = true }
        watchForDismissal()
    }

    func close(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        state?.onClose = nil
        state = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        panel.onResignKey = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func watchForDismissal() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.scrollWheel), handler: { [weak self] event in
            self?.outside(event) ?? event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.close()
        }) {
            monitors.append(global)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    /// A click in another window closes the menu. A left click is used up by
    /// it, as with a menu; a right click goes on (it may open another menu).
    private func outside(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window !== panel, event.timestamp != openingEvent else { return event }
        close()
        return event.type == .leftMouseDown ? nil : event
    }
}

/// What the menu shows and which item is lit.
@MainActor
@Observable
final class HazeMenuState {
    let entries: [HazeMenuEntry]
    var highlighted: UUID?
    /// The item that was chosen, lit for a moment before the menu goes.
    var chosen: UUID?
    var shown = false
    /// The corner the menu opens from.
    var anchor = UnitPoint.topLeading
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var typedAt = Date.distantPast

    init(entries: [HazeMenuEntry]) {
        self.entries = entries
    }

    private var items: [HazeMenuItem] {
        entries.compactMap { if case .item(let item) = $0, item.isEnabled { item } else { nil } }
    }

    func highlightFirst() {
        highlighted = items.first?.id
    }

    /// Arrows, Return and Space, Escape, and the first letters of an item.
    func handle(_ event: NSEvent) -> Bool {
        let items = items
        let index = items.firstIndex { $0.id == highlighted }
        switch event.keyCode {
        case 125: // down
            highlighted = items.isEmpty ? nil : items[index.map { ($0 + 1) % items.count } ?? 0].id
        case 126: // up
            highlighted = items.isEmpty ? nil : items[index.map { ($0 + items.count - 1) % items.count } ?? items.count - 1].id
        case 115: // home
            highlighted = items.first?.id
        case 119: // end
            highlighted = items.last?.id
        case 36, 76, 49: // return, enter, space
            if let index { choose(items[index]) }
        case 53: // escape
            onClose?()
        default:
            guard event.modifierFlags.isDisjoint(with: [.command, .control]),
                  let characters = event.charactersIgnoringModifiers?.lowercased(), characters.allSatisfy({ $0.isLetter || $0.isNumber })
            else { return false }
            typed = Date().timeIntervalSince(typedAt) < 0.9 ? typed + characters : characters
            typedAt = Date()
            if let match = items.first(where: { $0.title.lowercased().hasPrefix(typed) }) { highlighted = match.id }
        }
        return true
    }

    func choose(_ item: HazeMenuItem) {
        guard item.isEnabled, chosen == nil else { return }
        chosen = item.id
        highlighted = item.id
        // Lit a moment, like a menu item, then the menu goes and the action runs.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            self.onClose?()
            item.action()
        }
    }
}

/// A borderless panel that takes the keyboard and hands its keys to the menu.
final class HazeMenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityRole(.menu)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// The menu itself.
struct HazeMenuView: View {
    /// Room around the menu for its shadow (inside the panel).
    static let margin: CGFloat = 22

    let state: HazeMenuState
    let header: HazeMenuHeader?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            if let header {
                HStack(spacing: 8) {
                    if let icon = header.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text(verbatim: header.title)
                        .font(.mona(12, 600))
                        .foregroundStyle(Haze.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
                divider
            }
            ForEach(state.entries) { entry in
                switch entry {
                case .item(let item): row(item)
                case .separator: divider
                }
            }
        }
        .padding(5)
        .frame(minWidth: 214, alignment: .leading)
        .fixedSize()
        .background {
            ZStack {
                shape.fill(Color(haze: 0x121810).opacity(0.97))
                HazeBackground(glows: [HazeGlow(x: .fraction(1), y: .fraction(-0.1), rx: 180, ry: 110, color: 0xD8E8A7, alpha: 0.13)])
                    .clipShape(shape)
            }
        }
        .overlay { shape.strokeBorder(Haze.text.opacity(0.09)) }
        .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
        .scaleEffect(state.shown || reduceMotion ? 1 : 0.94, anchor: state.anchor)
        .opacity(state.shown ? 1 : 0)
        .offset(y: state.shown || reduceMotion ? 0 : (state.anchor.y == 0 ? -4 : 4))
        .animation(Haze.Motion.animation(.spring(response: 0.26, dampingFraction: 0.84), reduceMotion: reduceMotion), value: state.shown)
        .animation(Haze.Motion.animation(.spring(response: 0.2, dampingFraction: 0.9), reduceMotion: reduceMotion), value: state.highlighted)
        .padding(Self.margin)
        // A click around the menu (its shadow is in the panel) closes it.
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { state.onClose?() } }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Haze.text.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }

    private func row(_ item: HazeMenuItem) -> some View {
        let lit = state.highlighted == item.id && item.isEnabled
        let destructive = item.role == .destructive
        let tint = destructive ? Haze.danger : (lit ? Haze.accentText : Haze.text)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { state.choose(item) } label: {
            HStack(spacing: 10) {
                Group {
                    if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .symbolEffect(.bounce, value: state.chosen == item.id)
                    }
                }
                .frame(width: 18)
                .foregroundStyle(destructive ? Haze.danger : (lit ? Haze.accent : Haze.textSecondary))
                Text(verbatim: item.title)
                    .font(.mona(13, lit ? 600 : 500))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 18)
                if let shortcut = item.shortcut {
                    Text(verbatim: shortcut)
                        .font(.mona(11.5))
                        .foregroundStyle(Haze.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                if lit {
                    shape.fill(destructive ? Haze.dangerFill : Haze.selection)
                        .overlay { shape.strokeBorder((destructive ? Haze.danger : Haze.accent).opacity(0.12)) }
                        .matchedGeometryEffect(id: reduceMotion ? AnyHashable(item.id) : AnyHashable("highlight"), in: highlight)
                }
            }
            .contentShape(shape)
            .opacity(item.isEnabled ? 1 : 0.38)
        }
        .buttonStyle(HazeMenuRowStyle())
        .disabled(!item.isEnabled)
        .onHover { inside in
            if inside, item.isEnabled { state.highlighted = item.id } else if !inside, state.highlighted == item.id { state.highlighted = nil }
        }
        .accessibilityLabel(Text(verbatim: item.title))
    }
}

/// A menu row gives a touch under a click.
private struct HazeMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Haze.Motion.press, value: configuration.isPressed)
    }
}
