import AvoKit
import Foundation
import IOSurface

/// Receives IOSurface swapchains and present notifications from the daemon
/// (XPC queue) and hands them to the window that shows the display.
///
/// Frames can arrive before the window knows its display id (the engine
/// starts drawing while `openDisplay` is still returning), so the newest
/// swapchain and frame of an unknown display are kept until it registers.
final class FrameRouter: DaemonClient.FrameReceiver, @unchecked Sendable {
    private struct Pending {
        var surfaces: [IOSurface]?
        var present: (index: Int, sequence: UInt64)?
    }

    private let lock = NSLock()
    private var views: [UInt32: DisplayView] = [:]
    private var pending: [UInt32: Pending] = [:]
    /// Displays their window let go of (the daemon never reuses an id):
    /// frames still on their way are dropped, not kept for a window that never comes.
    private var closed: Set<UInt32> = []

    func register(_ view: DisplayView, for displayID: UInt32) {
        // Handed over under the lock: a newer swapchain arriving meanwhile
        // finds the view only afterwards, so the older one never replaces it.
        lock.withLock {
            views[displayID] = view
            let early = pending.removeValue(forKey: displayID)
            if let surfaces = early?.surfaces { view.renderer.setSurfaces(surfaces) }
            if let present = early?.present { view.renderer.present(index: present.index, sequence: present.sequence) }
        }
    }

    func unregister(_ displayID: UInt32) {
        lock.withLock {
            views[displayID] = nil
            pending[displayID] = nil
            closed.insert(displayID)
        }
    }

    func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {
        let view = lock.withLock { () -> DisplayView? in
            if let view = views[displayID] { return view }
            if !closed.contains(displayID) { pending[displayID, default: Pending()] = Pending(surfaces: surfaces, present: nil) }
            return nil
        }
        view?.renderer.setSurfaces(surfaces)
    }

    func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {
        let view = lock.withLock { () -> DisplayView? in
            if let view = views[displayID] { return view }
            if !closed.contains(displayID) { pending[displayID, default: Pending()].present = (surfaceIndex, sequence) }
            return nil
        }
        // Rendering happens on the renderer's own queue, not the main thread,
        // so a busy UI never delays a frame.
        view?.renderer.present(index: surfaceIndex, sequence: sequence)
    }
}
