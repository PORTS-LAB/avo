import Foundation

/// The Control Panel's notification list, one group per app, so one chatty
/// app does not flood it (as Notification Center stacks them).
public struct NotificationGroup: Identifiable, Equatable, Sendable {
    public var package: String
    public var appName: String
    /// Newest first; never empty.
    public var notifications: [AndroidNotification]

    public var id: String { package }
    public var newest: AndroidNotification { notifications[0] }

    /// `list` newest first (as the daemon sends it): groups in the order of
    /// their newest notification, each newest first.
    public static func grouping(_ list: [AndroidNotification]) -> [NotificationGroup] {
        var groups: [NotificationGroup] = []
        var index: [String: Int] = [:]
        for notification in list {
            if let at = index[notification.package] {
                groups[at].notifications.append(notification)
            } else {
                index[notification.package] = groups.count
                groups.append(NotificationGroup(package: notification.package, appName: notification.appName,
                                                notifications: [notification]))
            }
        }
        return groups
    }
}
