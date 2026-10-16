import Foundation

/// Facts about the Mac that bound the VM configuration.
public struct HostInfo: Codable, Equatable, Sendable {
    public var physicalMemoryBytes: UInt64
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var isAppleSilicon: Bool
    public var macOSVersion: String

    public init(physicalMemoryBytes: UInt64, performanceCores: Int, efficiencyCores: Int,
                isAppleSilicon: Bool, macOSVersion: String) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.isAppleSilicon = isAppleSilicon
        self.macOSVersion = macOSVersion
    }

    public var totalCores: Int { performanceCores + efficiencyCores }

    /// macOS keeps at least 4 GB (or a quarter of RAM) for itself; the spec
    /// caps the guest at 16 GB.
    public var maxGuestMemoryMiB: Int {
        let totalMiB = Int(physicalMemoryBytes / 1_048_576)
        let reserve = max(4096, totalMiB / 4)
        let available = max(totalMiB - reserve, VMConfig.memoryRangeMiB.lowerBound)
        return min(available / 256 * 256, VMConfig.memoryRangeMiB.upperBound)
    }

    /// Reads the running Mac.
    public static func current() -> HostInfo {
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        }
        let info = ProcessInfo.processInfo
        let performance = sysctlInt("hw.perflevel0.physicalcpu") ?? info.activeProcessorCount
        let efficiency = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        let arm64 = sysctlInt("hw.optional.arm64") == 1
        let os = info.operatingSystemVersion
        return HostInfo(physicalMemoryBytes: info.physicalMemory,
                        performanceCores: performance,
                        efficiencyCores: efficiency,
                        isAppleSilicon: arm64,
                        macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}
