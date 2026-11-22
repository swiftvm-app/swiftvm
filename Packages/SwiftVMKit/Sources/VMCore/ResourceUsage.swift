import Darwin

/// What a running machine takes of this Mac, as the process its engine runs it in uses it.
public struct ResourceUsage: Sendable, Hashable {
    /// Processor time, in percent of one of this Mac's cores, as Activity Monitor counts it: a guest
    /// that keeps two cores busy is at 200.
    public var cpuPercent: Double
    /// This Mac's memory that the process holds: its physical footprint, guest memory included as far
    /// as the guest has touched it.
    public var memoryBytes: UInt64

    public init(cpuPercent: Double, memoryBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }

    /// The use between two readings of one process. `nil` if they are of different processes (one ended
    /// and another got its ID) or no time passed between them.
    public init?(from earlier: ProcessCounters, to later: ProcessCounters) {
        guard earlier.processStart == later.processStart, later.takenAt > earlier.takenAt,
              later.cpuTime >= earlier.cpuTime
        else { return nil }
        let busy = Double(later.cpuTime - earlier.cpuTime)
        let elapsed = Double(later.takenAt - earlier.takenAt)
        self.init(cpuPercent: busy / elapsed * 100, memoryBytes: later.memoryBytes)
    }
}

/// The counters of one process at one moment, which two readings of tell its use in between.
public struct ProcessCounters: Sendable, Hashable {
    /// Processor time it has used, user and system together, in nanoseconds.
    public var cpuTime: UInt64
    public var memoryBytes: UInt64
    /// When they were read, in nanoseconds of a clock that doesn't jump.
    public var takenAt: UInt64
    /// When the process started, which tells it from a later one that has been given the same ID.
    public var processStart: UInt64

    public init(cpuTime: UInt64, memoryBytes: UInt64, takenAt: UInt64, processStart: UInt64) {
        self.cpuTime = cpuTime
        self.memoryBytes = memoryBytes
        self.takenAt = takenAt
        self.processStart = processStart
    }

    /// Reads them for process `pid`, which has to be the current user's. `nil` if it isn't there.
    public static func read(pid: pid_t) -> ProcessCounters? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // The times are in the units of the machine's clock, which aren't nanoseconds on Apple silicon.
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ProcessCounters(
            cpuTime: nanoseconds(fromTicks: ticks),
            memoryBytes: info.ri_phys_footprint,
            takenAt: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            processStart: info.ri_proc_start_abstime
        )
    }

    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        let (product, overflow) = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !overflow else { return ticks / UInt64(timebase.denom) * UInt64(timebase.numer) }
        return product / UInt64(timebase.denom)
    }
}
