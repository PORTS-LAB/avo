import AvoKit
import AvoPackages
import Foundation

/// An engine that can say how big Android's storage is (VMMEngine, through
/// HostAgent's `statfs` in Android).
public protocol GuestStorageEngine: VMEngine {
    /// Android's storage now, or nil while Android is not ready.
    func androidStorage() async -> AndroidStorage?
}

/// The data disk on the Mac, and what Android last said about it
/// (DataDiskStatus). Android's figures are kept beside the disk, so
/// Settings › Storage shows them while Android is stopped.
struct DataDiskStore {
    let disk: URL
    let record: URL
    /// avo-vmm's disks that belong to the data, not to the image: metadata
    /// (the key to Android's encrypted data), misc (bootloader messages) and
    /// frp (factory reset protection). A new data disk starts without them.
    let dataBoundDisks: [URL]
    var frpDisk: URL { dataBoundDisks[2] }

    init(paths: AvoPaths) {
        disk = paths.dataDisk
        record = paths.data.appending(path: "data-disk.json")
        // Next to the data disk, wherever Android's data is (they travel with it).
        dataBoundDisks = ["metadata.img", "misc.img", "frp.img"].map { paths.dataDisks.appending(path: $0) }
    }

    /// Creates the sparse disk for `gb` (VMConfig.dataDiskBytes) when there is
    /// none, and sizes one Android never wrote to (up or down). A disk Android
    /// created its storage on keeps its size: growing the file would not grow
    /// Android's file system (DataDiskStatus says why). Until Android writes
    /// to the disk, the disks bound to the data go too (`dataBoundDisks`).
    /// True when Android never wrote to it: its next boot is a first boot.
    @discardableResult
    func ensure(gb: Int) throws -> Bool {
        let size = UInt64(VMConfig.dataDiskBytes(gb: gb))
        let manager = FileManager.default
        if !manager.fileExists(atPath: disk.path) {
            manager.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else if Self.isWritten(disk) {
            return false
        }
        for bound in dataBoundDisks { try? manager.removeItem(at: bound) }
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        if try handle.seekToEnd() != size { try handle.truncate(atOffset: size) }
        return true
    }

    /// Avo has no factory reset protection: every start begins with a blank
    /// frp disk, which Android formats with the default secret (FRP off).
    /// A kept one says FRP is active whenever it does not match Android's
    /// data (the data erased or replaced: a reset, a backup, another copy),
    /// which only Google's setup could lift; system_server then stops at
    /// every boot instead ("SecurityException: FRP is active"). Lost with
    /// it: Developer options' OEM unlocking switch, meaningless here.
    func clearFactoryResetProtection() {
        try? FileManager.default.removeItem(at: frpDisk)
    }

    /// Whether anything was ever written to `url` (a fresh sparse file has
    /// no blocks); Android writes to a new disk as soon as it starts.
    /// (stat, not URL resource values: those are cached per URL.) On a
    /// drive without sparse files the start of the disk tells instead.
    static func isWritten(_ url: URL) -> Bool {
        AndroidDataFolder.isWritten(url)
    }

    static func size(_ url: URL) -> Int64 {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int64(info.st_size) : 0
    }

    func status() -> DataDiskStatus {
        let size = Self.size(disk)
        let created = size > 0 && Self.isWritten(disk)
        return DataDiskStatus(created: created, diskBytes: size, android: created ? lastSeen() : nil)
    }

    func lastSeen() -> AndroidStorage? {
        guard let data = try? Data(contentsOf: record) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AndroidStorage.self, from: data)
    }

    func remember(_ storage: AndroidStorage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(storage).write(to: record, options: .atomic)
    }

    /// Reset Android: the next disk is a new one.
    func forget() {
        try? FileManager.default.removeItem(at: record)
    }

    /// Why a size change is refused once Android created its storage, or nil.
    static func sizeChangeIssue(from old: VMConfig, to new: VMConfig, status: DataDiskStatus) -> ConfigIssue? {
        guard new.dataDiskGiB != old.dataDiskGiB, status.created else { return nil }
        let current = status.android.map { "\($0.settingsTotalGB) GB" }
            ?? ByteCountFormatter.string(fromByteCount: status.diskBytes, countStyle: .decimal)
        return ConfigIssue(field: "dataDiskGiB", severity: .error,
                           message: String(localized: "Android’s storage is already created (\(current)). Its size changes only when Android’s data is erased: use Change Size… in Settings › Storage.",
                                           bundle: .avoKit))
    }
}
