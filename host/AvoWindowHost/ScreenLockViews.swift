import AppKit
import AvoKit
import SwiftUI

// Android's screen lock (VMStatus.screenLock): the form that unlocks it,
// shared by the Control Panel's unlock sheet and App Shim windows, and the
// lock over each App Shim window while Android is locked.

/// Android's screen lock, entered as on Android: the pattern on a 3 × 3 grid
/// (dots 1–9 left to right, top to bottom), or the PIN or password in a
/// secure field. `unlock` passes it to the daemon and returns once Android is
/// unlocked. The credential lives in this view's state only, and is cleared
/// as soon as it has been sent.
public struct ScreenLockForm: View {
    private let lock: AndroidScreenLock
    private let cancel: (() -> Void)?
    private let unlock: @MainActor (String) async throws -> Void

    @State private var dots: [Int] = []
    @State private var text = ""
    @State private var busy = false
    /// A wrong pattern stays red for a moment.
    @State private var wrong = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    public init(lock: AndroidScreenLock, cancel: (() -> Void)? = nil, unlock: @escaping @MainActor (String) async throws -> Void) {
        self.lock = lock
        self.cancel = cancel
        self.unlock = unlock
    }

    public var body: some View {
        VStack(spacing: 14) {
            prompt.font(.headline)
            switch lock.credential {
            case .pattern:
                PatternGrid(dots: $dots, wrong: wrong, enabled: !busy) {
                    submit()
                } tooShort: {
                    problem = String(localized: "Connect at least \(AndroidScreenLock.Credential.minimumPatternDots) dots.", bundle: .windowHost)
                    dots = []
                } started: {
                    wrong = false
                    problem = nil
                }
                .frame(width: 210, height: 210)
                .focused($focused)
            case .pin, .password:
                SecureField(text: $text, prompt: fieldPrompt) { fieldPrompt }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .focused($focused)
                    .disabled(busy)
                    .onSubmit(submit)
                    .onChange(of: text) { problem = nil }
            }
            status
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(minHeight: 34, alignment: .top)
            HStack(spacing: 12) {
                if let cancel {
                    Button(action: cancel) { Text("Cancel", bundle: .windowHost) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(action: submit) { Text("Unlock", bundle: .windowHost) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !lock.credential.accepts(entered))
            }
        }
        .onAppear { focused = true }
    }

    private var prompt: Text {
        switch lock.credential {
        case .pattern: Text("Draw your Android pattern", bundle: .windowHost)
        case .pin: Text("Enter your Android PIN", bundle: .windowHost)
        case .password: Text("Enter your Android password", bundle: .windowHost)
        }
    }

    private var fieldPrompt: Text {
        lock.credential == .pin ? Text("PIN", bundle: .windowHost) : Text("Password", bundle: .windowHost)
    }

    @ViewBuilder private var status: some View {
        if busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Unlocking…", bundle: .windowHost)
            }
            .foregroundStyle(.secondary)
        } else if let problem {
            Text(problem).foregroundStyle(.red)
        } else if lock.credential == .pin, !text.isEmpty, !text.allSatisfy({ $0.isASCII && $0.isNumber }) {
            Text("A PIN has digits only.", bundle: .windowHost).foregroundStyle(.secondary)
        } else {
            Text("Avo passes it to Android and keeps it nowhere.", bundle: .windowHost).foregroundStyle(.secondary)
        }
    }

    private var entered: String {
        lock.credential == .pattern ? AndroidScreenLock.patternText(dots) : text
    }

    private func submit() {
        let credential = entered
        guard !busy, lock.credential.accepts(credential) else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                try await unlock(credential)
                text = ""
                dots = []
            } catch {
                show(error)
                focused = true
            }
        }
    }

    private func show(_ error: any Error) {
        switch error as? AvoError {
        case .screenLockRejected(throttled: false)?:
            problem = switch lock.credential {
            case .pattern: String(localized: "Wrong pattern. Try again.", bundle: .windowHost)
            case .pin: String(localized: "Wrong PIN. Try again.", bundle: .windowHost)
            case .password: String(localized: "Wrong password. Try again.", bundle: .windowHost)
            }
            text = ""
            if lock.credential == .pattern {
                wrong = true
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if wrong {
                        wrong = false
                        dots = []
                    }
                }
            }
        default:
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            text = ""
            dots = []
        }
    }
}

/// The 3 × 3 pattern grid. Dragging over the dots joins them (a dot the line
/// passes straight over joins too, as on Android); typing their numbers does
/// the same, Delete takes the last one back and Return finishes.
struct PatternGrid: View {
    @Binding var dots: [Int]
    var wrong: Bool
    var enabled: Bool
    /// Let go with enough dots.
    var finished: () -> Void
    /// Let go too early.
    var tooShort: () -> Void
    /// A new pattern begins.
    var started: () -> Void

    @State private var pointer: CGPoint?
    @State private var lastPoint: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Canvas { context, _ in draw(in: &context, side: side) }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(drag(side: side))
        }
        .aspectRatio(1, contentMode: .fit)
        .focusable(enabled)
        .onKeyPress(phases: .down) { press in key(press) }
        .accessibilityElement()
        .accessibilityLabel(Text("Pattern", bundle: .windowHost))
        .accessibilityValue(Text(dots.map(String.init).joined(separator: ", ")))
        .accessibilityHint(Text("Type the numbers of the dots, 1 to 9 from left to right and top to bottom, then press Return.",
                                bundle: .windowHost))
    }

    private static func center(of dot: Int, side: CGFloat) -> CGPoint {
        let cell = side / 3
        return CGPoint(x: (CGFloat((dot - 1) % 3) + 0.5) * cell, y: (CGFloat((dot - 1) / 3) + 0.5) * cell)
    }

    private func draw(in context: inout GraphicsContext, side: CGFloat) {
        let cell = side / 3
        let tint: Color = wrong ? .red : .accentColor
        if let first = dots.first {
            var line = Path()
            line.move(to: Self.center(of: first, side: side))
            for dot in dots.dropFirst() { line.addLine(to: Self.center(of: dot, side: side)) }
            if let pointer { line.addLine(to: pointer) }
            context.stroke(line, with: .color(tint.opacity(0.55)),
                           style: StrokeStyle(lineWidth: cell * 0.07, lineCap: .round, lineJoin: .round))
        }
        for dot in 1...9 {
            let center = Self.center(of: dot, side: side)
            let joined = dots.contains(dot)
            if joined {
                let halo = cell * 0.2
                context.fill(Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
                             with: .color(tint.opacity(0.18)))
            }
            let radius = joined ? cell * 0.09 : cell * 0.06
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: joined ? .color(tint) : .style(.secondary))
        }
    }

    private func drag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard enabled else { return }
                if lastPoint == nil {
                    // A new pattern each time the pointer goes down.
                    started()
                    dots = []
                    lastPoint = value.startLocation
                    hit(value.startLocation, side: side)
                }
                // Every few points between two events, so a quick stroke misses no dot.
                if let from = lastPoint {
                    let distance = hypot(value.location.x - from.x, value.location.y - from.y)
                    let steps = max(1, Int(distance / (side / 24)))
                    for step in 1...steps {
                        let t = CGFloat(step) / CGFloat(steps)
                        hit(CGPoint(x: from.x + (value.location.x - from.x) * t, y: from.y + (value.location.y - from.y) * t), side: side)
                    }
                }
                lastPoint = value.location
                pointer = dots.isEmpty ? nil : value.location
            }
            .onEnded { _ in
                guard lastPoint != nil else { return }
                lastPoint = nil
                pointer = nil
                if dots.count >= AndroidScreenLock.Credential.minimumPatternDots {
                    finished()
                } else if !dots.isEmpty {
                    tooShort()
                }
            }
    }

    /// The dot under `point`, within most of its cell.
    private func hit(_ point: CGPoint, side: CGFloat) {
        let cell = side / 3
        let column = Int((point.x / cell).rounded(.down))
        let row = Int((point.y / cell).rounded(.down))
        guard (0..<3).contains(column), (0..<3).contains(row) else { return }
        let dot = row * 3 + column + 1
        let center = Self.center(of: dot, side: side)
        guard hypot(point.x - center.x, point.y - center.y) <= cell * 0.38 else { return }
        dots = AndroidScreenLock.pattern(dots, adding: dot)
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard enabled else { return .ignored }
        if press.key == .return || press.key == KeyEquivalent("\u{3}") {
            if dots.count >= AndroidScreenLock.Credential.minimumPatternDots { finished() } else if !dots.isEmpty { tooShort() }
            return .handled
        }
        if press.key == .delete || press.key == .deleteForward {
            if !dots.isEmpty { dots.removeLast() }
            return .handled
        }
        guard let digit = press.characters.first?.wholeNumberValue, (1...9).contains(digit), press.characters.count == 1 else {
            return .ignored
        }
        if dots.isEmpty { started() }
        dots = AndroidScreenLock.pattern(dots, adding: digit)
        return .handled
    }
}

/// Over an App Shim window while Android is locked, in place of the app:
/// what happened and the screen lock's form. One unlock (here, in another
/// window or in the Control Panel) takes every window's lock away.
final class ScreenLockOverlay: NSView {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var shown: AndroidScreenLock??

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isShowing: Bool { !isHidden }

    /// Where typing goes while the lock shows.
    var focusTarget: NSView { hosting }

    /// `lock` nil: Android said it is locked, but not yet how (its status is
    /// on the way). False when that lock shows already: it keeps its form,
    /// and what is being typed into it.
    @discardableResult
    func show(lock: AndroidScreenLock?, appName: String, icon: NSImage?, unlock: @escaping @MainActor (String) async throws -> Void) -> Bool {
        isHidden = false
        guard shown != .some(lock) else { return false }
        shown = .some(lock)
        hosting.rootView = AnyView(ScreenLockOverlayContent(lock: lock, appName: appName, icon: icon, unlock: unlock))
        return true
    }

    func hide() {
        isHidden = true
        shown = nil
        // The form and anything typed into it go with it.
        hosting.rootView = AnyView(EmptyView())
    }

    // Nothing behind it takes clicks while it shows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}

private struct ScreenLockOverlayContent: View {
    let lock: AndroidScreenLock?
    let appName: String
    let icon: NSImage?
    let unlock: @MainActor (String) async throws -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        if let icon {
                            Image(nsImage: icon).resizable().frame(width: 72, height: 72)
                        }
                        Image(systemName: "lock.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 6, y: 6)
                    }
                    Text("Android is locked", bundle: .windowHost).font(.title2.weight(.semibold))
                    Text("Unlock it to open \(appName). One unlock opens all your Android apps.", bundle: .windowHost)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if let lock {
                        ScreenLockForm(lock: lock, unlock: unlock)
                            .padding(.top, 6)
                    } else {
                        ProgressView().controlSize(.small).padding(.top, 6)
                    }
                }
                .padding(28)
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
