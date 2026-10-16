import AvoProtocol
import Foundation

/// Translates Mac pointer input into Android touches when no keymap control
/// handles it (spec: "Gestur trackpad diterjemahkan ke gerakan Android:
/// scroll dua jari, pinch untuk zoom, dan swipe").
///
/// - A left-button drag is a one-finger touch.
/// - Precise (trackpad) scrolling becomes a one-finger drag, so Android apps
///   get native fling physics; wheel notches stay AXIS_SCROLL events.
/// - Pinch (magnify) becomes two fingers moving apart or together around the cursor.
///
/// Coordinates are display pixels.
public struct PointerTranslator: Sendable {
    public enum Phase: Sendable { case began, changed, ended }

    public let displayID: UInt32
    public private(set) var width: Double
    public private(set) var height: Double

    private enum Gesture: Sendable, Equatable {
        case none
        case click
        case scroll(x: Double, y: Double)
        case pinch(cx: Double, cy: Double, distance: Double)
    }

    private var gesture = Gesture.none
    /// Distance between the two fingers when a pinch begins, in pixels.
    static let pinchStartDistance = 200.0

    public init(displayID: UInt32, width: Double, height: Double) {
        self.displayID = displayID
        self.width = width
        self.height = height
    }

    public mutating func resize(width: Double, height: Double) -> [TouchEvent] {
        let events = cancel()
        self.width = width
        self.height = height
        return events
    }

    public var isActive: Bool { gesture != .none }

    // MARK: Mouse button

    public mutating func mouseDown(x: Double, y: Double) -> [TouchEvent] {
        var events = cancel()
        gesture = .click
        events.append(touch(.down, [(0, x, y)]))
        return events
    }

    public mutating func mouseDragged(x: Double, y: Double) -> [TouchEvent] {
        guard gesture == .click else { return [] }
        return [touch(.move, [(0, x, y)])]
    }

    public mutating func mouseUp(x: Double, y: Double) -> [TouchEvent] {
        guard gesture == .click else { return [] }
        gesture = .none
        return [touch(.up, [(0, x, y)])]
    }

    // MARK: Trackpad scrolling

    /// `dx`/`dy` are AppKit's scrolling deltas in points times the backing
    /// scale (content moves with the fingers, as on a touchscreen).
    public mutating func scroll(phase: Phase, x: Double, y: Double, dx: Double, dy: Double) -> [TouchEvent] {
        switch phase {
        case .began:
            var events = cancel()
            let start = (clampX(x), clampY(y))
            gesture = .scroll(x: start.0, y: start.1)
            events.append(touch(.down, [(0, start.0, start.1)]))
            if dx != 0 || dy != 0 { events += scroll(phase: .changed, x: x, y: y, dx: dx, dy: dy) }
            return events
        case .changed:
            guard case let .scroll(px, py) = gesture else { return [] }
            let nx = clampX(px + dx), ny = clampY(py + dy)
            gesture = .scroll(x: nx, y: ny)
            return [touch(.move, [(0, nx, ny)])]
        case .ended:
            guard case let .scroll(px, py) = gesture else { return [] }
            gesture = .none
            return [touch(.up, [(0, px, py)])]
        }
    }

    // MARK: Pinch

    /// `magnification` is the cumulative NSEvent.magnification sum for the gesture.
    public mutating func pinch(phase: Phase, centerX: Double, centerY: Double, magnification: Double) -> [TouchEvent] {
        switch phase {
        case .began:
            var events = cancel()
            let cx = clampX(centerX), cy = clampY(centerY)
            let d = Self.pinchStartDistance
            gesture = .pinch(cx: cx, cy: cy, distance: d)
            let (a, b) = fingers(cx: cx, cy: cy, distance: d)
            events.append(touch(.down, [(0, a.0, a.1)]))
            events.append(touch(.pointerDown, [(0, a.0, a.1), (1, b.0, b.1)], actionIndex: 1))
            return events
        case .changed:
            guard case let .pinch(cx, cy, _) = gesture else { return [] }
            let distance = max(20, Self.pinchStartDistance * (1 + magnification))
            gesture = .pinch(cx: cx, cy: cy, distance: distance)
            let (a, b) = fingers(cx: cx, cy: cy, distance: distance)
            return [touch(.move, [(0, a.0, a.1), (1, b.0, b.1)])]
        case .ended:
            guard case let .pinch(cx, cy, distance) = gesture else { return [] }
            gesture = .none
            let (a, b) = fingers(cx: cx, cy: cy, distance: distance)
            return [touch(.pointerUp, [(0, a.0, a.1), (1, b.0, b.1)], actionIndex: 1), touch(.up, [(0, a.0, a.1)])]
        }
    }

    /// Ends whatever gesture is in progress (focus loss, new gesture).
    public mutating func cancel() -> [TouchEvent] {
        switch gesture {
        case .none:
            return []
        case .click:
            gesture = .none
            return [touch(.cancel, [(0, 0, 0)])]
        case let .scroll(x, y):
            gesture = .none
            return [touch(.cancel, [(0, x, y)])]
        case let .pinch(cx, cy, distance):
            gesture = .none
            let (a, b) = fingers(cx: cx, cy: cy, distance: distance)
            return [touch(.cancel, [(0, a.0, a.1), (1, b.0, b.1)])]
        }
    }

    // MARK: Helpers

    private func fingers(cx: Double, cy: Double, distance: Double) -> ((Double, Double), (Double, Double)) {
        let half = distance / 2
        return ((clampX(cx - half), cy), (clampX(cx + half), cy))
    }

    private func clampX(_ x: Double) -> Double { min(max(x, 0), max(width - 1, 0)) }
    private func clampY(_ y: Double) -> Double { min(max(y, 0), max(height - 1, 0)) }

    private func touch(_ action: TouchAction, _ pointers: [(UInt32, Double, Double)], actionIndex: UInt8 = 0) -> TouchEvent {
        TouchEvent(displayID: displayID, action: action, actionIndex: actionIndex,
                   pointers: pointers.map { TouchPointer(id: $0.0, x: Float($0.1), y: Float($0.2)) })
    }
}
