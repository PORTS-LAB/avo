import AvoKit
import Foundation
import IOSurface

/// Receives IOSurface swapchains and present notifications from the daemon
/// (XPC queue) and hands them to the window that shows the display.
final class FrameRouter: DaemonClient.FrameReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var views: [UInt32: DisplayView] = [:]

    func register(_ view: DisplayView, for displayID: UInt32) {
        lock.withLock { views[displayID] = view }
    }

    func unregister(_ displayID: UInt32) {
        _ = lock.withLock { views.removeValue(forKey: displayID) }
    }

    private func view(_ displayID: UInt32) -> DisplayView? {
        lock.withLock { views[displayID] }
    }

    func setSurfaces(_ displayID: UInt32, surfaces: [IOSurface]) {
        view(displayID)?.renderer.setSurfaces(surfaces)
    }

    func present(_ displayID: UInt32, surfaceIndex: Int, sequence: UInt64) {
        // Rendering happens on the renderer's own queue, not the main thread,
        // so a busy UI never delays a frame.
        view(displayID)?.renderer.present(index: surfaceIndex, sequence: sequence)
    }
}
