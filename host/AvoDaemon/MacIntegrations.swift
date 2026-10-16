import AppKit
import AvoDaemonCore
import AvoKit
import AvoProtocol
import os
import UserNotifications

/// Android notifications in Notification Center; clicking one opens the app's
/// window (spec: "meng-klik notifikasi akan membuka jendela aplikasinya").
final class UserNotificationPresenter: NSObject, NotificationPresenter, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let lock = NSLock()
    private var onOpen: (@Sendable (String, String) -> Void)?
    private var authorized: Bool?
    private let iconDirectory = FileManager.default.temporaryDirectory.appending(path: "avo-notification-icons")

    func start(onOpen: @escaping @Sendable (String, String) -> Void) {
        lock.withLock { self.onOpen = onOpen }
        center.delegate = self
    }

    func post(_ notification: Avo_V1_Notification, appName: String, icon: Data?) {
        guard !notification.ongoing else { return } // progress bars and media sessions stay in Android
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = notification.title.isEmpty ? appName : notification.title
            content.subtitle = notification.title.isEmpty ? "" : appName
            content.body = notification.body
            content.threadIdentifier = notification.package
            content.userInfo = ["package": notification.package, "key": notification.key]
            if !notification.silent { content.sound = .default }
            if let attachment = attachment(icon: notification.largeIconPng.isEmpty ? icon : notification.largeIconPng,
                                           package: notification.package) {
                content.attachments = [attachment]
            }
            let request = UNNotificationRequest(identifier: notification.key, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    func remove(key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    private func ensureAuthorized() async -> Bool {
        if let authorized = lock.withLock({ authorized }) { return authorized }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        lock.withLock { authorized = granted }
        return granted
    }

    private func attachment(icon: Data?, package: String) -> UNNotificationAttachment? {
        guard let icon else { return nil }
        try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
        let url = iconDirectory.appending(path: "\(package)-\(UUID().uuidString).png")
        guard (try? icon.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: url)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let package = info["package"] as? String, let key = info["key"] as? String else { return }
        lock.withLock { onOpen }?(package, key)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// Two-way clipboard sync. macOS has no pasteboard change notification, so
/// the change count is polled (cheap, and the contents are only read on change).
final class PasteboardBridge: ClipboardBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start(onChange: @escaping @Sendable (String) -> Void) {
        DispatchQueue.main.async { [self] in
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                let count = pasteboard.changeCount
                let changed = self.lock.withLock { () -> Bool in
                    defer { self.lastChangeCount = count }
                    return count != self.lastChangeCount
                }
                guard changed, let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
                onChange(text)
            }
        }
    }

    func set(_ text: String) {
        DispatchQueue.main.async { [self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lock.withLock { lastChangeCount = pasteboard.changeCount }
        }
    }
}

struct WorkspaceLauncher: AppLauncher {
    func open(shim: URL, arguments: [String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: shim, configuration: configuration)
    }
}
