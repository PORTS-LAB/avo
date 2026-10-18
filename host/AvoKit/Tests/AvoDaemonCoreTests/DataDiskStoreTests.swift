import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct DataDiskStoreTests {
    private func store() throws -> (DataDiskStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "avo-disk-\(UUID().uuidString.prefix(8))")
        let paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
        try paths.createDirectories()
        return (DataDiskStore(paths: paths), root)
    }

    private func size(_ url: URL) throws -> Int64 { DataDiskStore.size(url) }

    /// A new disk is sparse and sized so Android shows the chosen size; one
    /// Android never wrote to follows the setting up and down.
    @Test func createsAndResizesAnUnusedDisk() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.ensure(gb: 32)
        #expect(try size(store.disk) == VMConfig.dataDiskBytes(gb: 32))
        #expect(!DataDiskStore.isWritten(store.disk))
        #expect(store.status() == DataDiskStatus(created: false, diskBytes: VMConfig.dataDiskBytes(gb: 32)))
        try store.ensure(gb: 64)
        #expect(try size(store.disk) == VMConfig.dataDiskBytes(gb: 64))
        try store.ensure(gb: 16)
        #expect(try size(store.disk) == VMConfig.dataDiskBytes(gb: 16))
    }

    /// Once Android formatted the disk, a new setting never touches it:
    /// a bigger file would not give Android more room.
    @Test func keepsTheSizeAndroidCreatedItsStorageWith() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.ensure(gb: 32)
        let handle = try FileHandle(forWritingTo: store.disk)
        try handle.seek(toOffset: 1 << 20)
        try handle.write(contentsOf: Data(repeating: 7, count: 4096))
        try handle.close()
        for gb in [64, 16] {
            try store.ensure(gb: gb)
            #expect(try size(store.disk) == VMConfig.dataDiskBytes(gb: 32))
        }
        #expect(store.status().created)
        // A disk an older Avo grew keeps its size as well (80 GiB here).
        let grown = try FileHandle(forWritingTo: store.disk)
        try grown.truncate(atOffset: 80 << 30)
        try grown.close()
        try store.ensure(gb: 32)
        #expect(try size(store.disk) == 80 << 30)
    }

    /// A new data disk starts without the old data's metadata, misc and frp
    /// disks (a kept frp disk stopped Android at every boot after a reset);
    /// once Android wrote to the data they stay with it.
    @Test func aNewDiskDropsTheDisksOfTheOldData() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try #require(store.dataBoundDisks.first).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        let writeBound = { for url in store.dataBoundDisks { try Data(repeating: 1, count: 512).write(to: url) } }
        try writeBound()
        try store.ensure(gb: 32)
        #expect(store.dataBoundDisks.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let handle = try FileHandle(forWritingTo: store.disk)
        try handle.write(contentsOf: Data(repeating: 7, count: 4096))
        try handle.close()
        try writeBound()
        try store.ensure(gb: 32)
        #expect(store.dataBoundDisks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Every start clears the frp disk, written or not; the data's other
    /// disks stay.
    @Test func everyStartClearsFactoryResetProtection() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: store.frpDisk.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in store.dataBoundDisks { try Data(repeating: 1, count: 512).write(to: url) }
        store.clearFactoryResetProtection()
        #expect(!FileManager.default.fileExists(atPath: store.frpDisk.path))
        #expect(store.dataBoundDisks.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
            == ["metadata.img", "misc.img"])
        store.clearFactoryResetProtection()
    }

    @Test func remembersWhatAndroidSaidUntilReset() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.ensure(gb: 32)
        let seen = AndroidStorage(dataBytes: 30_000_000_000, freeBytes: 29_000_000_000, systemBytes: 940_990_464,
                                  checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        store.remember(seen)
        // Shown only for a disk Android created its storage on.
        #expect(store.status().android == nil)
        try FileHandle(forWritingTo: store.disk).write(contentsOf: Data([1]))
        #expect(store.status().android == seen)
        #expect(store.status().android?.settingsTotalGB == 32)
        store.forget()
        #expect(store.status().android == nil)
    }

    @Test func refusesSizeChangesOnceCreated() {
        let old = VMConfig(dataDiskGiB: 32)
        var new = old
        new.dataDiskGiB = 80
        let fresh = DataDiskStatus(created: false, diskBytes: 30 << 30)
        #expect(DataDiskStore.sizeChangeIssue(from: old, to: new, status: fresh) == nil)
        let created = DataDiskStatus(created: true, diskBytes: 80 << 30,
                                     android: AndroidStorage(dataBytes: 34_357_641_216, freeBytes: 1, systemBytes: 940_990_464))
        let issue = DataDiskStore.sizeChangeIssue(from: old, to: new, status: created)
        #expect(issue?.field == "dataDiskGiB" && issue?.severity == .error)
        #expect(issue?.message.contains("64 GB") == true)
        #expect(DataDiskStore.sizeChangeIssue(from: old, to: old, status: created) == nil)
    }

    /// The cap Android runs at (verified in the test VM: glbench 60 → 30 fps
    /// on display 0 and on a hot-plugged display, and back; on 120 Hz
    /// displays 120, 60 and 30 fps). Games are held at 60 by Android only
    /// on 60 Hz displays.
    @Test func frameRateCapIsAndroidsPeakRefreshRate() {
        let games = " && setprop debug.graphics.game_default_frame_rate.disabled"
        #expect(HostAgent.refreshRateCommand(fps: 30, displayRate: 60) == "settings put system peak_refresh_rate 30" + games + " false")
        #expect(HostAgent.refreshRateCommand(fps: 60, displayRate: 60) == "settings delete system peak_refresh_rate" + games + " false")
        #expect(HostAgent.refreshRateCommand(fps: 120, displayRate: 60) == "settings delete system peak_refresh_rate" + games + " false")
        #expect(HostAgent.refreshRateCommand(fps: 45, displayRate: 60) == "settings put system peak_refresh_rate 30" + games + " false")
        #expect(HostAgent.refreshRateCommand(fps: 120, displayRate: 120) == "settings delete system peak_refresh_rate" + games + " true")
        #expect(HostAgent.refreshRateCommand(fps: 60, displayRate: 120) == "settings put system peak_refresh_rate 60" + games + " true")
        #expect(HostAgent.refreshRateCommand(fps: 90, displayRate: 90) == "settings delete system peak_refresh_rate" + games + " true")
        // A 75 Hz screen's own rate (test VM: hzbench, a game, at 75.1 fps).
        #expect(HostAgent.refreshRateCommand(fps: 75, displayRate: 75) == "settings delete system peak_refresh_rate" + games + " true")
        #expect(HostAgent.refreshRateCommand(fps: 75, displayRate: 120) == "settings put system peak_refresh_rate 75" + games + " true")
    }
}
