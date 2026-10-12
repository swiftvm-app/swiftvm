import Foundation
import GuestChannel

/// A command that runs for whoever drives this system from the Mac: what it prints goes there as it
/// comes, what arrives from there is its input, and how it exits ends the job. When the Mac hangs up,
/// whoever wanted the command is gone, and the command is called off.
enum CommandJob {
    /// How long a command that was called off gets to end by itself before it is ended.
    static let killGrace: TimeInterval = 3
    /// How long an output pipe may stay idle once the command has ended. Something it left running
    /// in the background can hold the pipe open for good; time spent sending to the Mac doesn't count.
    static let outputGrace: TimeInterval = 2

    /// Where a command looks for programs: where macOS has them, and where people put their own.
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Carries the job out on its connection. Returns when it is over; the connection stays open.
    static func run(_ exec: GuestJob.Exec, on descriptor: Int32, system: any AgentSystem) {
        let account: AgentAccount
        do {
            guard let program = exec.arguments.first, !program.isEmpty, !exec.arguments.contains(where: { $0.contains("\0") }) else {
                throw AgentFailure("The request has no command.")
            }
            guard (exec.environment ?? [:]).allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !($0.key + $0.value).contains("\0") }) else {
                throw AgentFailure("The command's environment has to be names and values.")
            }
            account = try system.account(named: exec.user)
        } catch {
            GuestJobLine.answer(.refusal((error as? AgentFailure)?.message ?? error.localizedDescription), on: descriptor)
            return
        }
        GuestJobLine.answer(GuestJobAnswer(ok: true), on: descriptor)

        let line = JobConnection(descriptor)
        let launch = system.launch(exec.arguments, as: account)
        let process = Process()
        let (input, output, errors) = (Pipe(), Pipe(), Pipe())
        process.executableURL = URL(fileURLWithPath: launch[0])
        process.arguments = Array(launch.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: exec.directory ?? account.home, isDirectory: true)
        process.environment = environment(of: account).merging(exec.environment ?? [:]) { _, asked in asked }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // A command that has stopped reading must not end this process.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            // 126 is what a shell says for a command it can't run.
            line.end(.failure("The command couldn't be started: \(error.localizedDescription)", status: 126))
            return
        }

        let watch = HangUpWatch()
        let printing = DispatchGroup()
        for (pipe, kind) in [(output, JobFrame.Kind.output), (errors, .errorOutput)] {
            let source = dup(pipe.fileHandleForReading.fileDescriptor)
            printing.enter()
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: JobFrame.maximumPayloadLength)
                var idleSince: ContinuousClock.Instant?
                while source >= 0 {
                    var waiting = pollfd(fd: source, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&waiting, 1, 250)
                    if ready == 0 {
                        if !process.isRunning {
                            let now = ContinuousClock.now
                            if let idleSince, now - idleSince >= .seconds(outputGrace) { break }
                            if idleSince == nil { idleSince = now }
                        }
                        continue
                    }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    let count = read(source, &buffer, buffer.count)
                    if count > 0 {
                        guard line.send(kind, Data(buffer[0..<count])) else { break }
                        idleSince = nil
                    } else if count == 0 || errno != EINTR {
                        break
                    }
                }
                if source >= 0 {
                    close(source)
                }
                printing.leave()
            }
        }
        let feed = input.fileHandleForWriting
        // Asked for once, while the handle is open: a closed one answers with an exception that
        // nothing here could catch.
        let feedDescriptor = feed.fileDescriptor
        // This thread reads for as long as the Mac sends, which can be longer than the job lasts. It
        // has a number of its own for the connection, and closes that itself: the job's own number is
        // closed when the job is over, and given to the next connection.
        let reading = dup(descriptor)
        Thread.detachNewThread {
            defer {
                if reading >= 0 {
                    close(reading)
                }
            }
            var takesInput = true
            // What the Mac sends is the command's input, and an empty frame the end of it. Once the
            // job is over, whoever hangs up reads from the connection too: what was being read here
            // at that moment may be torn, and none of it is the command's any more.
            while !line.isOver, let frame = try? JobFrame.read(from: reading) {
                guard frame.kind == .input, takesInput, !line.isOver else { continue }
                if frame.payload.isEmpty {
                    takesInput = false
                    try? feed.close()
                } else if !ByteRelay.writeAll(ArraySlice(frame.payload), to: feedDescriptor) {
                    // The command has stopped reading, or has ended.
                    takesInput = false
                }
            }
        }
        let watching = DispatchGroup()
        watching.enter()
        Thread.detachNewThread {
            defer { watching.leave() }
            guard watch.waitForHangUp(of: descriptor) else { return }
            // The Mac is gone, and with it whoever wanted this. The parent may take TERM while a
            // child ignores it, so it is the whole group that gets this long to end, not just its head.
            signalGroup(process, SIGTERM)
            let deadline = ContinuousClock.now + .seconds(killGrace)
            while signalGroup(process, 0) {
                if ContinuousClock.now >= deadline {
                    signalGroup(process, SIGKILL)
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        exited.wait()
        // What the command printed last is still on its way. Only an idle pipe times out, never a
        // thread waiting for the Mac to take a frame, and the end follows all of those frames.
        printing.wait()
        watch.stop()
        watching.wait()
        line.end(process.terminationReason == .uncaughtSignal ? JobEnd(signal: process.terminationStatus) : JobEnd(status: process.terminationStatus))
    }

    /// What a command that runs as `account` finds in its environment: what a login would give it.
    static func environment(of account: AgentAccount) -> [String: String] {
        [
            "HOME": account.home, "USER": account.name, "LOGNAME": account.name,
            "SHELL": account.shell.isEmpty ? "/bin/sh" : account.shell, "PATH": path, "LANG": "en_US.UTF-8",
        ]
    }

    /// Sends a signal to a command and everything it started, which is one process group where the
    /// command was started as its head. Where it wasn't, the command alone gets it while still running.
    @discardableResult
    private static func signalGroup(_ process: Process, _ signal: Int32) -> Bool {
        let identifier = process.processIdentifier
        if kill(-identifier, signal) == 0 { return true }
        return process.isRunning && kill(identifier, signal) == 0
    }
}

/// A job's connection, as the threads of a command share it: frames go out whole, one at a time, and
/// none after the one that ends the job. From then on the connection may be closed and its number
/// given to another job, which must never get a frame of this one.
final class JobConnection: @unchecked Sendable {
    private let descriptor: Int32
    /// Held for as long as a frame takes to send, which is as long as the Mac takes to read it.
    private let sending = NSLock()
    /// Held for a moment only: whoever asks whether the job is over doesn't wait for a frame.
    private let state = NSLock()
    private var hasEnded = false

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Whether the frame that ends the job has been sent.
    var isOver: Bool {
        state.withLock { hasEnded }
    }

    /// Sends what may be long as frames. Returns `false` when the connection failed, or the job is over.
    func send(_ kind: JobFrame.Kind, _ payload: Data) -> Bool {
        sending.withLock { !isOver && JobFrame.write(kind, payload, to: descriptor) }
    }

    /// Sends the frame that ends the job, once.
    func end(_ end: JobEnd) {
        sending.withLock {
            guard !isOver else { return }
            JobFrame.write(.end, JobFrame.end(end).payload, to: descriptor)
            state.withLock { hasEnded = true }
        }
    }
}

/// Tells when the other side of a connection has hung up, whoever else is reading from it and whether
/// or not they are: by the line itself, not by what arrives on it.
final class HangUpWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false

    /// Waits until the other side of `descriptor` has said it sends no more, and returns `true`. Returns
    /// `false` once ``stop()`` was called.
    func waitForHangUp(of descriptor: Int32) -> Bool {
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        // Told once about what arrives, not for as long as it lies there unread.
        var change = kevent(ident: UInt(descriptor), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return false }
        while !lock.withLock({ isStopped }) {
            var event = kevent()
            var patience = timespec(tv_sec: 0, tv_nsec: 250_000_000)
            let count = kevent(queue, nil, 0, &event, 1, &patience)
            if count < 0, errno != EINTR { return false }
            if count > 0, Int32(event.flags) & EV_EOF != 0 {
                return !lock.withLock { isStopped }
            }
        }
        return false
    }

    func stop() {
        lock.withLock { isStopped = true }
    }
}
