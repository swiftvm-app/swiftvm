import Darwin
import Testing
@testable import VMCore

struct ResourceUsageTests {
    @Test func countsTheProcessorTimeBetweenTwoReadingsInPercentOfOneCore() throws {
        let earlier = ProcessCounters(cpuTime: 1_000_000_000, memoryBytes: 1 << 30, takenAt: 10_000_000_000, processStart: 7)
        // Two seconds later, with three seconds of processor time used: one and a half cores.
        let later = ProcessCounters(cpuTime: 4_000_000_000, memoryBytes: 3 << 30, takenAt: 12_000_000_000, processStart: 7)
        let usage = try #require(ResourceUsage(from: earlier, to: later))
        #expect(usage.cpuPercent == 150)
        #expect(usage.memoryBytes == 3 << 30)
    }

    /// A process that ended and another that was given its ID are told apart by when they started.
    @Test func tellsNothingOfTwoDifferentProcesses() {
        let earlier = ProcessCounters(cpuTime: 1_000_000_000, memoryBytes: 1, takenAt: 1, processStart: 7)
        let later = ProcessCounters(cpuTime: 2_000_000_000, memoryBytes: 1, takenAt: 2, processStart: 8)
        #expect(ResourceUsage(from: earlier, to: later) == nil)
        #expect(ResourceUsage(from: earlier, to: earlier) == nil)
    }

    /// The system counts processor time in the ticks of the machine's clock, which on Apple silicon are
    /// not nanoseconds: counted in ticks, a thread kept busy would be at a few percent. The whole
    /// process is read, and other tests run beside this one, so there is no upper bound.
    @Test func readsAProcessInNanosecondsOfProcessorTime() throws {
        let earlier = try #require(ProcessCounters.read(pid: getpid()))
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var spin: UInt64 = 0
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start < 300_000_000 {
            spin &+= 1
        }
        #expect(spin > 0)
        let later = try #require(ProcessCounters.read(pid: getpid()))
        let usage = try #require(ResourceUsage(from: earlier, to: later))
        #expect(usage.cpuPercent > 40)
        #expect(usage.memoryBytes > 0)
    }
}
