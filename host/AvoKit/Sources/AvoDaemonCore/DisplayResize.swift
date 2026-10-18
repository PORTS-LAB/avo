import Foundation

/// The size and density of one Android display: the one the window wants,
/// or the one Android has.
struct DisplayMode: Equatable, Sendable {
    var width: UInt32
    var height: UInt32
    /// 0 leaves Android's own density (the window did not ask for one).
    var dpi: UInt32
}

/// What a display still needs before Android has the mode the window wants.
enum ResizeStep: Equatable, Sendable {
    /// Unplug the display and plug it in again at the new size. The density
    /// is set once, after the plug: set before it, it would be set on a
    /// display that is about to go away and again on the new one.
    case replug(DisplayMode)
    /// Same size, new density: Android applies it live, without a re-plug.
    case density(UInt32)
    case done

    static func next(wanted: DisplayMode, applied: DisplayMode) -> ResizeStep {
        if wanted.width != applied.width || wanted.height != applied.height { return .replug(wanted) }
        if wanted.dpi > 0, wanted.dpi != applied.dpi { return .density(wanted.dpi) }
        return .done
    }
}

/// HostAgent's resize loop, apart from adb and the engine so tests can run it.
///
/// One loop runs per display at a time and always works toward the newest
/// mode. A resize that arrives while the loop runs waits for it to end, so
/// every resize reply means "Android has the newest size and density, and
/// the app is back on the display" (the window holds its last frame until then).
protocol DisplayResizing: Actor {
    /// Displays whose loop is running.
    var resizing: Set<UInt32> { get set }
    /// Resize requests waiting for a display's loop (or its launch) to end.
    var resizeWaiters: [UInt32: [CheckedContinuation<Void, Never>]] { get set }
    /// The mode the window wants and the one Android has; nil while Android
    /// has not added the display yet, and once it is closed.
    func modes(of id: UInt32) -> (wanted: DisplayMode, applied: DisplayMode)?
    /// Re-plugs the display in `mode`, sets its density and brings the app
    /// back; records what Android then has. Returns quietly when the
    /// display closed meanwhile.
    func replug(_ id: UInt32, to mode: DisplayMode) async throws
    /// Sets a display's density live and records it, whether or not Android
    /// took it, so the loop never retries forever.
    func applyDensity(_ id: UInt32, _ dpi: UInt32) async
}

extension DisplayResizing {
    /// Gives Android the newest mode of display `id` (see the protocol).
    func applySize(_ id: UInt32) async throws {
        guard !resizing.contains(id) else {
            await waitForResize(id)
            return
        }
        resizing.insert(id)
        defer {
            resizing.remove(id)
            finishResize(id)
        }
        while let (wanted, applied) = modes(of: id) {
            switch ResizeStep.next(wanted: wanted, applied: applied) {
            case .replug(let mode): try await replug(id, to: mode)
            case .density(let dpi): await applyDensity(id, dpi)
            case .done: return
            }
        }
    }

    /// Suspends until display `id`'s running loop, or its launch, ends.
    func waitForResize(_ id: UInt32) async {
        await withCheckedContinuation { resizeWaiters[id, default: []].append($0) }
    }

    /// Lets the requests waiting on display `id` reply.
    func finishResize(_ id: UInt32) {
        for waiter in resizeWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
}
