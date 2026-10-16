import AvoKit
import AvoProtocol
import Foundation

/// macOS services the daemon uses but that need AppKit or UserNotifications.
/// The daemon executable provides the real implementations; tests use fakes.

/// Shows Android notifications in Notification Center (spec: "Fitur native tambahan").
public protocol NotificationPresenter: Sendable {
    /// `onOpen` is called with the notification key when the user clicks it.
    func start(onOpen: @escaping @Sendable (_ package: String, _ key: String) -> Void)
    func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?)
    func remove(key: String)
}

/// Two-way clipboard sync.
public protocol ClipboardBridge: Sendable {
    /// `onChange` receives text the user copied on the Mac.
    func start(onChange: @escaping @Sendable (String) -> Void)
    /// Puts text copied in Android on the Mac clipboard without echoing it back.
    func set(_ text: String)
}

/// Opens App Shims (for notification clicks).
public protocol AppLauncher: Sendable {
    func open(shim: URL, arguments: [String]) async throws
}

/// Default no-op implementations so the core runs headless.
public struct NoNotifications: NotificationPresenter {
    public init() {}
    public func start(onOpen: @escaping @Sendable (String, String) -> Void) {}
    public func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?) {}
    public func remove(key: String) {}
}

public struct NoClipboard: ClipboardBridge {
    public init() {}
    public func start(onChange: @escaping @Sendable (String) -> Void) {}
    public func set(_ text: String) {}
}

public struct NoLauncher: AppLauncher {
    public init() {}
    public func open(shim: URL, arguments: [String]) async throws {}
}
