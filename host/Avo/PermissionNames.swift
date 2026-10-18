import Foundation

/// Human names for Android permissions shown before installing and in App Info.
enum PermissionNames {
    private static let labels: [String: String] = [
        "android.permission.CAMERA": String(localized: "Camera"),
        "android.permission.RECORD_AUDIO": String(localized: "Microphone"),
        "android.permission.ACCESS_FINE_LOCATION": String(localized: "Precise location"),
        "android.permission.ACCESS_COARSE_LOCATION": String(localized: "Approximate location"),
        "android.permission.ACCESS_BACKGROUND_LOCATION": String(localized: "Location in the background"),
        "android.permission.READ_CONTACTS": String(localized: "Contacts"),
        "android.permission.WRITE_CONTACTS": String(localized: "Change contacts"),
        "android.permission.READ_CALENDAR": String(localized: "Calendar"),
        "android.permission.WRITE_CALENDAR": String(localized: "Change calendar"),
        "android.permission.READ_EXTERNAL_STORAGE": String(localized: "Files and media"),
        "android.permission.WRITE_EXTERNAL_STORAGE": String(localized: "Change files and media"),
        "android.permission.READ_MEDIA_IMAGES": String(localized: "Photos"),
        "android.permission.READ_MEDIA_VIDEO": String(localized: "Videos"),
        "android.permission.READ_MEDIA_AUDIO": String(localized: "Music and audio"),
        "android.permission.POST_NOTIFICATIONS": String(localized: "Notifications"),
        "android.permission.READ_PHONE_STATE": String(localized: "Phone status"),
        "android.permission.CALL_PHONE": String(localized: "Make phone calls"),
        "android.permission.SEND_SMS": String(localized: "Send SMS"),
        "android.permission.READ_SMS": String(localized: "Read SMS"),
        "android.permission.BODY_SENSORS": String(localized: "Body sensors"),
        "android.permission.ACTIVITY_RECOGNITION": String(localized: "Physical activity"),
        "android.permission.BLUETOOTH_CONNECT": String(localized: "Nearby devices"),
        "android.permission.NEARBY_WIFI_DEVICES": String(localized: "Nearby Wi-Fi devices"),
        "android.permission.SYSTEM_ALERT_WINDOW": String(localized: "Draw over other apps"),
        "android.permission.REQUEST_INSTALL_PACKAGES": String(localized: "Install other apps"),
        "android.permission.QUERY_ALL_PACKAGES": String(localized: "See all installed apps"),
        "android.permission.MANAGE_EXTERNAL_STORAGE": String(localized: "All files"),
    ]

    static func label(for permission: String, fallback: String = "") -> String {
        labels[permission] ?? (fallback.isEmpty ? shortName(permission) : fallback)
    }

    /// Permissions worth showing in the install sheet, deduplicated by label.
    static func notable(_ permissions: [String]) -> [String] {
        var seen = Set<String>()
        return permissions.compactMap { labels[$0] }.filter { seen.insert($0).inserted }
    }

    private static func shortName(_ permission: String) -> String {
        let last = permission.split(separator: ".").last.map(String.init) ?? permission
        return last.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
