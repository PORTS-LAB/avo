import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct GuestAudioHalTests {
    let build = GuestAudioHal.builds[0]

    @Test func theLatencyIsOneInstruction() {
        // `mov w0, #0x55` and `mov w0, #0xa` as llvm-objdump shows them in
        // ModulePrimary::getNominalLatencyMs (85 ms, and 10 ms for MMAP).
        #expect(GuestAudioHal.movW0(85) == 0x5280_0AA0)
        #expect(GuestAudioHal.movW0(10) == 0x5280_0140)
        #expect(build.original == GuestAudioHal.movW0(85))
        #expect(build.replacement == GuestAudioHal.movW0(20))
        #expect(GuestAudioHal.escapes(build.replacement) == #"\200\002\200\122"#)
    }

    @Test func onlyTheKnownBuildIsPatched() {
        let path = GuestAudioHal.binary
        #expect(GuestAudioHal.installed(sumOutput: "\(build.sha256)  \(path)\n") == .stock(build))
        #expect(GuestAudioHal.installed(sumOutput: "\(build.patchedSHA256)  \(path)\n") == .patched)
        #expect(GuestAudioHal.installed(sumOutput: "\(String(repeating: "0", count: 64))  \(path)\n") == .unknown)
        #expect(GuestAudioHal.installed(sumOutput: "") == .unknown)
        #expect(GuestAudioHal.installed(sumOutput: "sha256sum: \(path): No such file or directory") == .unknown)
    }

    @Test func theScriptChecksTheCopyBeforeAnythingChanges() throws {
        let lines = GuestAudioHal.installScript(build).split(separator: "\n").map(String.init)
        #expect(lines.first == "set -e")
        let patch = try #require(lines.firstIndex { $0.contains("dd of=\(GuestAudioHal.staged) bs=1 seek=\(0x9bc24) conv=notrunc") })
        #expect(lines[patch].hasPrefix(#"printf '\200\002\200\122'"#))
        let check = try #require(lines.firstIndex { $0.contains(build.patchedSHA256) })
        let mount = try #require(lines.firstIndex { $0 == "mount -o bind \(GuestAudioHal.staged) \(GuestAudioHal.binary)" })
        let property = try #require(lines.firstIndex { $0.hasPrefix("setprop \(GuestAudioHal.periodProperty) 2") })
        #expect(patch < check && check < mount && mount < property, "nothing is mounted unchecked, no property without the mount")
        #expect(lines.contains("chcon u:object_r:hal_audio_default_exec:s0 \(GuestAudioHal.staged)"))
        // Without the property the patched HAL comes off again.
        #expect(lines.last == "[ \"$(getprop \(GuestAudioHal.periodProperty))\" = 2 ] || { umount \(GuestAudioHal.binary); exit 1; }")
        // Not where GuestAudioPolicy stages its files (cleared every boot).
        #expect(!GuestAudioHal.staging.hasPrefix(GuestAudioPolicy.staging + "/") && GuestAudioHal.staging != GuestAudioPolicy.staging)
    }

    @Test func thePatchedCopyMatchesItsHash() throws {
        // The patch applied to a stand-in for the binary changes exactly the
        // four bytes the script writes.
        var data = Data(repeating: 0, count: build.offset + 8)
        withUnsafeBytes(of: build.original.littleEndian) { data.replaceSubrange(build.offset..<build.offset + 4, with: $0) }
        let escapes = GuestAudioHal.escapes(build.replacement).split(separator: "\\").map { UInt8($0, radix: 8)! }
        data.replaceSubrange(build.offset..<build.offset + 4, with: escapes)
        let word = data[build.offset..<build.offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        #expect(word == build.replacement)
    }
}
