import Foundation

/// What the host can offer, and sensible defaults for new machines.
public enum HostResources {
    public static let gibibyte: UInt64 = 1 << 30

    public static var cpuCount: Int { ProcessInfo.processInfo.processorCount }
    public static var memorySize: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Default virtual CPU count: half the host cores, between 2 and 4.
    public static func recommendedCPUCount(for family: GuestFamily) -> Int {
        min(max(cpuCount / 2, 2), 4)
    }

    /// Default guest memory: 8 GB on hosts with at least 16 GB, otherwise 4 GB.
    public static func recommendedMemorySize(for family: GuestFamily) -> UInt64 {
        memorySize >= 16 * gibibyte ? 8 * gibibyte : 4 * gibibyte
    }

    /// Default disk capacity. Disks are sparse, so this is an upper bound rather than space used.
    public static func recommendedDiskCapacity(for family: GuestFamily) -> UInt64 {
        switch family {
        case .macOS: 128 * gibibyte
        case .linux: 64 * gibibyte
        case .windows: 128 * gibibyte
        }
    }

    /// The largest disk that can be asked for, in GB. Disks are sparse, so this isn't about space on the
    /// host; it catches a size typed in the wrong unit, which can't be undone because disks don't shrink.
    public static let maximumDiskGigabytes = 8192

    /// The largest memory size offered in the UI, leaving headroom for the host.
    public static var maximumGuestMemorySize: UInt64 {
        max(memorySize - 4 * gibibyte, 2 * gibibyte)
    }
}
