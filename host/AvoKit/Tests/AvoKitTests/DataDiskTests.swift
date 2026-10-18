import Foundation
import Testing
@testable import AvoKit

@Suite struct DataDiskTests {
    /// Android's FileUtils.roundStorageSize, from its own tests and from the
    /// 32 GiB disk that showed "64 GB total" in Android's Settings.
    @Test func roundsLikeAndroidSettings() {
        #expect(VMConfig.androidStorageSize(1) == 1)
        #expect(VMConfig.androidStorageSize(1_000) == 1_000)
        #expect(VMConfig.androidStorageSize(1_001) == 2_000)
        #expect(VMConfig.androidStorageSize(15_000_000_000) == 16_000_000_000)
        #expect(VMConfig.androidStorageSize(32_000_000_000) == 32_000_000_000)
        #expect(VMConfig.androidStorageSize(32_000_000_001) == 64_000_000_000)
        #expect(VMConfig.androidStorageSize(600_000_000_000) == 1_000_000_000_000)
        // The old 32 GiB data disk with Cuttlefish's 0.94 GB system partition.
        #expect(VMConfig.androidStorageSize(34_357_641_216 + 940_990_464) == 64_000_000_000)
    }

    /// Every size Settings › Storage offers is the size Android then shows,
    /// with room for a system partition up to 2 GB.
    @Test(arguments: VMConfig.dataDiskChoices) func newDisksShowTheChosenSize(gb: Int) {
        let disk = VMConfig.dataDiskBytes(gb: gb)
        #expect(disk % (1 << 20) == 0)
        let shown = Int64(gb) * 1_000_000_000
        for system: Int64 in [940_990_464, 1_999_000_000] {
            #expect(VMConfig.androidStorageSize(disk + system) == shown)
        }
        // Not much of it goes to "System": a phone of that size has less free.
        #expect(Double(disk) / Double(shown) > 0.84)
    }

    @Test func smallDisksStayUsable() {
        #expect(VMConfig.dataDiskBytes(gb: 8) == 6_000_000_000 / (1 << 20) * (1 << 20))
        #expect(VMConfig.dataDiskBytes(gb: 1) == 4 << 30)
    }

    /// `stat -f -c '%b %a %S' /data /system` in the test VM.
    @Test func readsAndroidsStatfs() throws {
        let output = "8388096 8215955 4096\n229741 0 4096\n"
        let storage = try #require(AndroidStorage.parse(output, at: Date(timeIntervalSince1970: 0)))
        #expect(storage.dataBytes == 8_388_096 * 4096)
        #expect(storage.freeBytes == 8_215_955 * 4096)
        #expect(storage.systemBytes == 229_741 * 4096)
        #expect(storage.settingsTotalGB == 64)
        #expect(AndroidStorage.parse("") == nil)
        #expect(AndroidStorage.parse("stat: /data: Permission denied\n229741 0 4096") == nil)
        #expect(AndroidStorage.parse("0 0 4096\n1 0 4096") == nil)
    }

    @Test func statusRoundTripsAndOlderSnapshotsHaveNone() throws {
        let status = DataDiskStatus(created: true, diskBytes: 30 << 30,
                                    android: AndroidStorage(dataBytes: 1, freeBytes: 1, systemBytes: 1, checkedAt: Date(timeIntervalSince1970: 5)))
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(DataDiskStatus.self, from: data) == status)
        let snapshot = ConfigurationSnapshot(config: VMConfig(), host: macBook16, profiles: [], pendingRestart: false)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object["dataDisk"] = nil
        let older = try JSONDecoder().decode(ConfigurationSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.dataDisk == nil)
    }
}
