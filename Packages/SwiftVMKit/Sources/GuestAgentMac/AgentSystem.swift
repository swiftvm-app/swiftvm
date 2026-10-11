import Foundation
import GuestChannel

/// A request can't be carried out. Its text goes back to the app.
struct AgentFailure: Error, Sendable, Equatable {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

/// What the agent knows about the system it runs in, and what it does to it.
protocol AgentSystem: Sendable {
    func describe() -> GuestSystem
    func hostName() -> String?
    /// The network cards that hold an address, with their addresses.
    func interfaces() -> [GuestInterface]
    /// Sets the clock to this time, in nanoseconds since 1970.
    func setClock(nanoseconds: Int64) throws
    /// Gives the system the time zone with this name in the time zone database.
    func setTimeZone(_ identifier: String) throws
    func shutDown() throws
}

/// macOS itself. Changing the clock, the time zone or the power takes root.
struct MacSystem: AgentSystem {
    /// A clock that is this close to the Mac's is left to the system's own time service.
    static let clockToleranceInNanoseconds: Int64 = 20_000_000

    init() {}

    func describe() -> GuestSystem {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var names = utsname()
        uname(&names)
        return GuestSystem(
            id: "macos",
            name: "macOS",
            version: number,
            prettyName: "macOS \(number)",
            build: Self.systemText("kern.osversion"),
            kernel: Self.text(of: &names.release),
            architecture: Self.text(of: &names.machine)
        )
    }

    func hostName() -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        let isKnown = buffer.withUnsafeMutableBytes { bytes in
            gethostname(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), bytes.count - 1) == 0
        }
        let name = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return isKnown && !name.isEmpty ? name : nil
    }

    func interfaces() -> [GuestInterface] {
        NetworkInterfaces.current()
    }

    func setClock(nanoseconds: Int64) throws {
        let difference = nanoseconds - GuestProtocol.currentTimeInNanoseconds()
        guard abs(difference) > Self.clockToleranceInNanoseconds else { return }
        var time = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
        guard clock_settime(CLOCK_REALTIME, &time) == 0 else {
            throw AgentFailure("The clock couldn't be set: \(String(cString: strerror(errno))).")
        }
        let seconds = String(format: "%.3f", Double(abs(difference)) / 1e9)
        AgentLog.note("The clock was \(seconds) s \(difference > 0 ? "behind" : "ahead") and has been set.")
    }

    func setTimeZone(_ identifier: String) throws {
        guard TimeZoneName.isValid(identifier), TimeZone(identifier: identifier) != nil else {
            throw AgentFailure("“\(identifier.prefix(64))” isn't the name of a time zone.")
        }
        guard Self.currentTimeZone() != identifier else { return }
        // It grumbles on its error output even when it succeeds; its exit status tells the two apart.
        try Self.run("/usr/sbin/systemsetup", ["-settimezone", identifier], timeout: 20)
        AgentLog.note("The time zone is now \(identifier).")
    }

    func shutDown() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
        process.arguments = ["-h", "now"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AgentFailure("The system couldn't be told to shut down: \(error.localizedDescription)")
        }
        // Nobody waits for it: it doesn't come back, and takes this agent down with everything else
        // within the second. The app has to have its answer before that.
        AgentLog.note("Shutting down at the app's request.")
    }

    // MARK: Private

    /// The time zone the system is in, by the name its clock file is linked under.
    static func currentTimeZone() -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime"),
              let range = target.range(of: "/zoneinfo/")
        else { return nil }
        return String(target[range.upperBound...])
    }

    /// Runs a command to its end. Fails with what it printed if it exits with an error or takes too long.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw AgentFailure("\(name) couldn't be run: \(error.localizedDescription)")
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw AgentFailure("\(name) didn't finish in \(Int(timeout)) seconds.")
        }
        guard process.terminationStatus == 0 else {
            // These tools say little; what they say fits in the pipe without anyone reading meanwhile.
            let said = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentFailure(said.isEmpty ? "\(name) failed with status \(process.terminationStatus)." : String(said.prefix(500)))
        }
    }

    private static func systemText(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func text<Field>(of field: inout Field) -> String {
        withUnsafeBytes(of: &field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Names of time zones, as far as they can be told from their spelling.
enum TimeZoneName {
    /// Whether `identifier` is spelled like a name in the time zone database, such as `Europe/Berlin`,
    /// and nothing that a command would read as anything else.
    static func isValid(_ identifier: String) -> Bool {
        guard let first = identifier.first, first.isASCII, first.isLetter, identifier.utf8.count <= 64 else { return false }
        return !identifier.contains("..")
            && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/_+-".contains($0)) }
    }
}
