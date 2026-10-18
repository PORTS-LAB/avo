import Foundation

/// Shorter mixer periods for Cuttlefish's audio HAL (HostAgent, "Audio").
///
/// The HAL (hardware/interfaces/audio/aidl/default, `ModulePrimary`) gives
/// every stream that is not MMAP a nominal latency of 85 ms, "considering
/// 4096 frames @ 48 kHz" (`kStandardLatencyMs`, chosen so that the virtual
/// device passes CTS on Google's servers), and refuses buffers below it. No
/// property or configuration file changes it. AudioFlinger's mixer then
/// takes 4096 frames from every track per cycle, so a game that sizes its
/// AAudio or OpenSL ES buffer from the burst it is given (20 ms, 960 frames;
/// Oboe and many engines use two bursts) can never fill a cycle: its track
/// underruns every 85 ms, and over half of its sound becomes silence. Every
/// other app hears 85 ms more delay than it needs.
///
/// On the image Avo uses, the constant is one instruction (`mov w0, #85` in
/// `ModulePrimary::getNominalLatencyMs`). Every boot a copy of the HAL with
/// it set to 20 is bind-mounted over the image's file (the image stays as it
/// is), only when the binary is exactly the known build: the HAL then mixes
/// in 1024-frame (21 ms) periods. Its ALSA periods are a quarter of that by
/// default (256 frames, a 1024-frame ring), too fine for a VM;
/// `ro.hardware.audio.tinyalsa.period_size_multiplier` (alsa_utils'
/// `profile_fill_builtin_device_info`) doubles them: four periods of 512
/// frames. A larger ring only added delay (its start threshold and the
/// engine's lead-in grow with it). Both are set before audioserver restarts,
/// which restarts the HAL. Measured on Avo's test VM (a game's write to the
/// Mac playing it): about 255 to 82 ms with AAudio's default buffer, and no
/// underruns for a two-burst AAudio stream (11 a second before).
enum GuestAudioHal {
    /// On: proven with the engine's playback clock (sound.rs), 0 xruns.
    static let enabled = true

    /// The binary init starts as `vendor.audio-hal-aidl`.
    static let binary = "/apex/com.android.hardware.audio/bin/hw/android.hardware.audio.service-aidl.example"
    /// The patched copy, apart from GuestAudioPolicy's staging (cleared each boot).
    static let staging = "/data/local/tmp/avo-audio-hal"
    static let staged = staging + "/hal"
    /// The SELinux type of the file it covers: init starts the HAL from it.
    static let label = "u:object_r:hal_audio_default_exec:s0"
    static let periodProperty = "ro.hardware.audio.tinyalsa.period_size_multiplier"
    /// 2 × the HAL's 1024 frames / 4 periods: 512-frame ALSA periods.
    static let periodMultiplier = 2

    /// One known build of the HAL and the word that sets its latency.
    struct Build: Equatable {
        let sha256: String
        let patchedSHA256: String
        /// File offset of the instruction.
        let offset: Int
        let original: UInt32
        let replacement: UInt32
    }

    static let builds = [
        // AOSP Cuttlefish 16373615 (aosp_cf_arm64_only_phone-userdebug, Android 17).
        Build(sha256: "fd219b1058eccc701de685cf59d6578e887c11182d877bb4e6c3a78bfd73e279",
              patchedSHA256: "0cf1e05d7b1466c89c56486178baf432518a210b768c67745109030aeec51982",
              offset: 0x9bc24,
              original: movW0(85),
              replacement: movW0(20)),
    ]

    /// `movz w0, #value` (A64).
    static func movW0(_ value: UInt16) -> UInt32 {
        0x5280_0000 | UInt32(value) << 5
    }

    enum Installed: Equatable {
        /// A known build, still as the image has it.
        case stock(Build)
        /// The patched copy is in place already (the daemon came back to a running Android).
        case patched
        /// Another build: left as it is.
        case unknown
    }

    /// From `sha256sum <binary>`.
    static func installed(sumOutput: String) -> Installed {
        let sum = sumOutput.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if let build = builds.first(where: { $0.sha256 == sum }) { return .stock(build) }
        if builds.contains(where: { $0.patchedSHA256 == sum }) { return .patched }
        return .unknown
    }

    /// `printf` octal escapes for `word`, little endian.
    static func escapes(_ word: UInt32) -> String {
        (0..<4).map { String(format: "\\%03o", (word >> ($0 * 8)) & 0xff) }.joined()
    }

    /// Run as root: the patched copy, checked against its hash, mounted, then
    /// the property. Fails (and leaves the HAL as it was) when any step does.
    /// The property goes only with the patched HAL: with the image's
    /// 4096-frame buffer it would ask ALSA for periods longer than the driver
    /// allows, and nothing would play.
    static func installScript(_ build: Build) -> String {
        [
            "set -e",
            "rm -rf \(staging)",
            "mkdir -p \(staging)",
            "cp \(binary) \(staged)",
            "printf '\(escapes(build.replacement))' | dd of=\(staged) bs=1 seek=\(build.offset) conv=notrunc 2>/dev/null",
            "[ \"$(sha256sum \(staged) | cut -d ' ' -f 1)\" = \(build.patchedSHA256) ]",
            "chown root:shell \(staged)",
            "chmod 755 \(staged)",
            "chcon \(label) \(staged)",
            "mount -o bind \(staged) \(binary)",
            // A read-only property takes one value per boot.
            "setprop \(periodProperty) \(periodMultiplier) 2>/dev/null || true",
            "[ \"$(getprop \(periodProperty))\" = \(periodMultiplier) ] || { umount \(binary); exit 1; }",
        ].joined(separator: "\n")
    }
}
