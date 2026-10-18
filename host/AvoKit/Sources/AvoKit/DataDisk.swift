import Foundation

/// Android's storage: the data disk on the Mac and what Android made of it
/// (Settings › Storage).
///
/// Android creates its storage on a new data disk at its first start: it
/// formats the disk (f2fs) and encrypts it with keys only Android holds.
/// From then on the size stays. A bigger disk image would not give Android
/// more room: f2fs cannot grow while mounted, and growing it offline moves
/// file data, which this encryption does not survive. So changing the size
/// erases Android's data, and the next start creates the storage again.
public struct DataDiskStatus: Codable, Equatable, Sendable {
    /// Android has created its storage on the disk (the disk exists and was
    /// written); its size is fixed from then on.
    public var created: Bool
    /// The disk image's size: what Android sees as its data partition.
    public var diskBytes: Int64
    /// The storage as Android last reported it (nil before it ran with this Avo).
    public var android: AndroidStorage?

    public init(created: Bool, diskBytes: Int64, android: AndroidStorage? = nil) {
        self.created = created
        self.diskBytes = diskBytes
        self.android = android
    }
}

/// Android's own view of its storage, from `statfs` in Android.
public struct AndroidStorage: Codable, Equatable, Sendable {
    /// The data partition (/data): its size and what apps can still write.
    public var dataBytes: Int64
    public var freeBytes: Int64
    /// The system partition, which Settings › Storage counts as well.
    public var systemBytes: Int64
    public var checkedAt: Date

    public init(dataBytes: Int64, freeBytes: Int64, systemBytes: Int64, checkedAt: Date = Date()) {
        self.dataBytes = dataBytes
        self.freeBytes = freeBytes
        self.systemBytes = systemBytes
        self.checkedAt = checkedAt
    }

    /// The total Settings › Storage shows ("64 GB"), in bytes.
    public var settingsTotalBytes: Int64 { VMConfig.androidStorageSize(dataBytes + systemBytes) }
    /// The same in GB, as `VMConfig.dataDiskGiB` counts.
    public var settingsTotalGB: Int { Int(settingsTotalBytes / 1_000_000_000) }

    /// The command that prints what `parse` reads: for /data, then /system,
    /// "<total blocks> <blocks free to apps> <block size>".
    public static let statCommand = "stat -f -c '%b %a %S' /data /system"

    /// Reads `statCommand`'s output.
    public static func parse(_ output: String, at date: Date = Date()) -> AndroidStorage? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.split(separator: " ").compactMap { Int64($0) } }
        guard lines.count >= 2, lines[0].count == 3, lines[1].count == 3,
              lines[0][2] > 0, lines[1][2] > 0, lines[0][0] > 0 else { return nil }
        return AndroidStorage(dataBytes: lines[0][0] * lines[0][2], freeBytes: lines[0][1] * lines[0][2],
                              systemBytes: lines[1][0] * lines[1][2], checkedAt: date)
    }
}
