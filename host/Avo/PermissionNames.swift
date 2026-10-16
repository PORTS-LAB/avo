import Foundation

/// Human names for Android permissions shown before installing and in App Info.
enum PermissionNames {
    private static let labels: [String: String] = [
        "android.permission.CAMERA": "Camera",
        "android.permission.RECORD_AUDIO": "Microphone",
        "android.permission.ACCESS_FINE_LOCATION": "Precise location",
        "android.permission.ACCESS_COARSE_LOCATION": "Approximate location",
        "android.permission.ACCESS_BACKGROUND_LOCATION": "Location in the background",
        "android.permission.READ_CONTACTS": "Contacts",
        "android.permission.WRITE_CONTACTS": "Change contacts",
        "android.permission.READ_CALENDAR": "Calendar",
        "android.permission.WRITE_CALENDAR": "Change calendar",
        "android.permission.READ_EXTERNAL_STORAGE": "Files and media",
        "android.permission.WRITE_EXTERNAL_STORAGE": "Change files and media",
        "android.permission.READ_MEDIA_IMAGES": "Photos",
        "android.permission.READ_MEDIA_VIDEO": "Videos",
        "android.permission.READ_MEDIA_AUDIO": "Music and audio",
        "android.permission.POST_NOTIFICATIONS": "Notifications",
        "android.permission.READ_PHONE_STATE": "Phone status",
        "android.permission.CALL_PHONE": "Make phone calls",
        "android.permission.SEND_SMS": "Send SMS",
        "android.permission.READ_SMS": "Read SMS",
        "android.permission.BODY_SENSORS": "Body sensors",
        "android.permission.ACTIVITY_RECOGNITION": "Physical activity",
        "android.permission.BLUETOOTH_CONNECT": "Nearby devices",
        "android.permission.NEARBY_WIFI_DEVICES": "Nearby Wi-Fi devices",
        "android.permission.SYSTEM_ALERT_WINDOW": "Draw over other apps",
        "android.permission.REQUEST_INSTALL_PACKAGES": "Install other apps",
        "android.permission.QUERY_ALL_PACKAGES": "See all installed apps",
        "android.permission.MANAGE_EXTERNAL_STORAGE": "All files",
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
