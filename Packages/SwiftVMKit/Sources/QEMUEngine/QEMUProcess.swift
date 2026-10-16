import Darwin
import Foundation

/// A QEMU that runs one machine: the process, and what it prints.
///
/// QEMU is handed the ends of the lines the app talks to it over (its machine protocol, the network,
/// the guest's agent) as open descriptors, numbered from 3 in the order they are given. Nothing else
/// of the app's is open in it.
///
/// A copy of the app that ends without stopping its machines leaves their QEMUs running, with nothing
/// at the other end of those lines. Each writes down its process ID in its machine's bundle, so that the
/// next start of that machine finds and ends it first.
final class QEMUProcess: @unchecked Sendable {
    let pid: pid_t
    /// Called once, on no particular thread, when the process has ended, with what `waitpid` said.
    var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { exitHandler } }
        set {
            let status: Int32? = lock.withLock {
                exitHandler = newValue
                return exitStatus
            }
            if let status { newValue?(status) }
        }
    }

    private let lock = NSLock()
    private var exitHandler: (@Sendable (Int32) -> Void)?
    private var exitStatus: Int32?
    private var exitSource: (any DispatchSourceProcess)?
    private var recentOutput = Data()
    private let pidFile: URL

    /// The first descriptor number the handed-over lines get in QEMU.
    static let firstDescriptor: Int32 = 3
    /// How much of what QEMU printed last is kept, to say why it stopped.
    private static let keptOutput = 8 * 1024

    private init(pid: pid_t, pidFile: URL) {
        self.pid = pid
        self.pidFile = pidFile
    }

    /// Starts `program` with `arguments`. What it prints goes to `log`, and its process ID to `pidFile`.
    ///
    /// - Parameter descriptors: Open descriptors that QEMU gets as 3, 4, 5 and so on. The caller keeps its
    ///   own and closes them once QEMU has started.
    static func launch(program: URL, arguments: [String], descriptors: [Int32], log: URL, pidFile: URL, environment: [String: String] = [:]) throws -> QEMUProcess {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var output: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw QEMUError.didNotStart(String(cString: strerror(errno))) }
        defer { close(output[1]) }

        // A descriptor whose number is among those being handed out would be overwritten before its
        // turn. Such a one is moved out of the way first.
        let highest = firstDescriptor + Int32(descriptors.count)
        var moved: [Int32] = []
        defer { moved.forEach { close($0) } }
        let sources = descriptors.map { descriptor -> Int32 in
            guard descriptor < highest else { return descriptor }
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, highest + 64)
            moved.append(copy)
            return copy
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir(&actions, log.deletingLastPathComponent().path)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, output[1], 2)
        for (index, source) in sources.enumerated() {
            posix_spawn_file_actions_adddup2(&actions, source, firstDescriptor + Int32(index))
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only what was named above is open in QEMU. Signals are as a new program has them, whatever
        // the app ignores or holds back, and a signal meant for the app's process group isn't QEMU's.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let argv = ([program.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let values = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        let envp = values.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        let result = posix_spawn(&pid, program.path, &actions, &attributes, argv, envp)
        guard result == 0 else {
            close(output[0])
            throw QEMUError.didNotStart(String(cString: strerror(result)))
        }

        let process = QEMUProcess(pid: pid, pidFile: pidFile)
        try? Data("\(pid)\n".utf8).write(to: pidFile, options: .atomic)
        process.record(output: output[0], to: log)
        process.watchExit()
        return process
    }

    /// What QEMU printed last, for saying why it stopped.
    var lastOutput: String {
        let text = String(decoding: lock.withLock { recentOutput }, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last line QEMU printed that says what went wrong, without QEMU's name in front.
    var complaint: String? {
        let lines = lastOutput.split(separator: "\n").map(String.init)
        guard let line = lines.last(where: { !$0.contains("warning:") }) ?? lines.last else { return nil }
        let parts = line.components(separatedBy: ": ")
        let reason = parts.first?.hasPrefix("qemu-system") == true ? parts.dropFirst().joined(separator: ": ") : line
        return reason.isEmpty ? nil : reason
    }

    var hasExited: Bool { lock.withLock { exitStatus != nil } }

    /// Asks QEMU to end, the way a signal from the system would: the guest stops where it is.
    func terminate() {
        guard !hasExited else { return }
        kill(pid, SIGTERM)
    }

    /// Ends QEMU at once.
    func forceKill() {
        guard !hasExited else { return }
        kill(pid, SIGKILL)
    }

    /// Waits until the process has ended, for `timeout` at most. Returns whether it has.
    func waitForExit(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !hasExited {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func record(output descriptor: Int32, to log: URL) {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let file = try? FileHandle(forWritingTo: log)
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                let bytes = Data(buffer[0..<count])
                try? file?.write(contentsOf: bytes)
                self?.keep(bytes)
            }
            try? file?.close()
            close(descriptor)
        }
    }

    private func keep(_ bytes: Data) {
        lock.withLock {
            recentOutput.append(bytes)
            if recentOutput.count > Self.keptOutput {
                recentOutput = Data(recentOutput.suffix(Self.keptOutput))
            }
        }
    }

    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.reap(waiting: true) }
        lock.withLock { exitSource = source }
        source.resume()
        // It may have ended before the source was there to see it.
        reap(waiting: false)
    }

    /// Collects the ended process and says so, once. Without `waiting`, only if it has ended already.
    private func reap(waiting: Bool) {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, waiting ? 0 : WNOHANG)
        } while result < 0 && errno == EINTR
        // Someone else collected it first: the source and the check above can both get here.
        guard result == pid else { return }
        try? FileManager.default.removeItem(at: pidFile)
        let handler = lock.withLock { () -> (@Sendable (Int32) -> Void)? in
            exitStatus = status
            exitSource?.cancel()
            exitSource = nil
            return exitHandler
        }
        handler?(status)
    }

    // MARK: Left behind

    /// Ends the QEMU that a copy of the app left running for a machine, if one is: the process that
    /// `pidFile` names, as long as it is a QEMU running the machine with `machineID`. Waits until it is
    /// gone.
    ///
    /// The process is told by what it was started with, not by the program it runs: a copy of the app
    /// that was replaced since leaves a QEMU behind whose program is gone, and a process ID that was
    /// written down long ago may have been given to something else by now, another machine's QEMU too.
    static func endLeftover(pidFile: URL, machineID: UUID) async {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
        else { return }
        if let arguments = arguments(of: pid), isQEMU(arguments, runningMachine: machineID) {
            kill(pid, SIGKILL)
            for _ in 0..<250 where kill(pid, 0) == 0 {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Whether a process started with `arguments` is a QEMU that runs the machine with `machineID`.
    static func isQEMU(_ arguments: [String], runningMachine machineID: UUID) -> Bool {
        guard let program = arguments.first, URL(fileURLWithPath: program).lastPathComponent == "qemu-system-aarch64",
              let flag = arguments.firstIndex(of: "-uuid"), arguments.indices.contains(flag + 1)
        else { return false }
        return arguments[flag + 1].lowercased() == machineID.uuidString.lowercased()
    }

    /// What a process was started with, as the system keeps it (`KERN_PROCARGS2`): the number of
    /// arguments, the path of the program, and the arguments, each ending in a zero byte.
    private static func arguments(of pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // After the count: the program's path, padding of zero bytes, then the arguments.
        var strings: [String] = []
        var index = MemoryLayout<Int32>.size
        // The program's path, which isn't one of the arguments.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        while index < size, strings.count < Int(count) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return strings.count == Int(count) ? strings : nil
    }
}
