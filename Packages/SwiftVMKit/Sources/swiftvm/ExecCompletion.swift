import Foundation
import GuestChannel
import Synchronization
import VMControl

/// Separate from the guest's byte streams and the CLI's exit status, which can have the same values.
struct ExecCompletion: Encodable {
    enum Completion: String, Encodable {
        case exited, signaled, unknown
    }

    let schemaVersion = 1
    let machine: String
    let machineID: UUID?
    let completion: Completion
    let status: Int32?
    let signal: Int32?

    init(machine: String, machineID: UUID?, end: JobEnd?) {
        self.machine = machine
        self.machineID = machineID
        // An error or an ambiguous/malformed end is not evidence of guest completion.
        if let end, end.error == nil, let status = end.status, end.signal == nil {
            completion = .exited
            self.status = status
            signal = nil
        } else if let end, end.error == nil, end.status == nil, let signal = end.signal, (1...127).contains(signal) {
            completion = .signaled
            status = nil
            self.signal = signal
        } else {
            completion = .unknown
            status = nil
            signal = nil
        }
    }
}

/// Owns a duplicate so the receipt never accidentally uses a subsequently opened job connection.
final class ExecCompletionWriter: Sendable {
    struct InvalidDescriptor: Error, LocalizedError {
        var errorDescription: String? { "--result-fd needs an open, writable descriptor greater than 2." }
    }

    private let descriptor: Int32?
    private struct State {
        var deadline: DispatchTime?
        var seconds: Double = 0
        var machineID: UUID?
        var connection: Int32?
        var finishing = false
        var timedOut = false
        var status: Int32 = GuestJobs.failedStatus
        var recordWritten = false
    }

    private struct Finish {
        var completion: ExecCompletion
        var status: Int32
        var diagnostic: String?
        var timeoutSeconds: Double? = nil
    }

    // Select an outcome under the lock, but never hold it during caller-controlled I/O.
    private let state = Mutex(State())
    static let reportingGraceMilliseconds = 50

    init(descriptor: Int32?) throws {
        guard let descriptor else {
            self.descriptor = nil
            return
        }
        guard descriptor > STDERR_FILENO else { throw InvalidDescriptor() }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE != O_RDONLY else { throw InvalidDescriptor() }
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard owned >= 0 else { throw InvalidDescriptor() }
        self.descriptor = owned
        _ = fcntl(owned, F_SETNOSIGPIPE, 1)
    }

    deinit {
        if let descriptor { close(descriptor) }
    }

    /// A caller must read a whole line before trusting it; a failed write can leave a partial record.
    func write(_ completion: ExecCompletion) throws {
        guard let descriptor else { return }
        try ControlSocket.writeLine(JSONEncoder().encode(completion), to: descriptor)
    }

    /// One uptime-based deadline covers setup, dispatch and streams. A second callback only bounds
    /// reporting after expiry: blocked caller descriptors must not trap the deadline callback itself.
    func armDeadline(_ seconds: Double, machine: String) {
        let deadline = DispatchTime.now() + seconds
        state.withLock { $0.deadline = deadline; $0.seconds = seconds }
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            let (connection, finish) = self.state.withLock { state -> (Int32?, Finish?) in
                guard !state.finishing else { return (state.connection, nil) }
                state.finishing = true
                state.timedOut = true
                state.status = GuestJobs.timedOutStatus
                return (state.connection, Self.timeout(machine: machine, state: state))
            }
            if let connection { shutdown(connection, SHUT_RDWR) }
            if let finish { self.publish(finish) }
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: deadline + .milliseconds(Self.reportingGraceMilliseconds)) {
            let status = self.state.withLock { state -> Int32 in
                guard state.finishing else { return GuestJobs.timedOutStatus }
                if self.descriptor != nil, !state.recordWritten, !state.timedOut {
                    return GuestJobs.failedStatus
                }
                return state.status
            }
            // No stdio flushing or teardown that could wait on another blocked reporting thread.
            _exit(status)
        }
    }

    func connected(to connection: Int32, machineID: UUID?) {
        let expired = state.withLock { state -> Bool in
            guard !state.finishing else { return true }
            state.connection = connection
            state.machineID = machineID
            return false
        }
        if expired { shutdown(connection, SHUT_RDWR) }
    }

    func finish(_ completion: ExecCompletion, status: Int32, diagnostic: String? = nil) -> Never {
        let finish = state.withLock { state -> Finish? in
            guard !state.finishing else { return nil }
            state.finishing = true
            if let deadline = state.deadline, DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
                state.timedOut = true
                state.status = GuestJobs.timedOutStatus
                return Self.timeout(machine: completion.machine, state: state)
            }
            state.status = status
            return Finish(completion: completion, status: status, diagnostic: diagnostic)
        }
        guard let finish else {
            // The winning reporter exits, or the fixed reporting grace ends the process.
            while true { pause() }
        }
        publish(finish)
    }

    private static func timeout(machine: String, state: State) -> Finish {
        Finish(completion: ExecCompletion(machine: machine, machineID: state.machineID, end: nil), status: GuestJobs.timedOutStatus,
               diagnostic: nil, timeoutSeconds: state.seconds)
    }

    private func publish(_ finish: Finish) -> Never {
        do {
            try write(finish.completion)
        } catch {
            state.withLock { $0.status = GuestJobs.failedStatus }
            fail("Couldn't write the exec completion record.", status: GuestJobs.failedStatus)
        }
        state.withLock { $0.recordWritten = true }
        let diagnostic = finish.timeoutSeconds.map {
            "The exec operation didn't finish in \($0.formatted()) seconds; guest completion is unknown."
        } ?? finish.diagnostic
        if let diagnostic {
            FileHandle.standardError.write(Data("swiftvm: \(diagnostic)\n".utf8))
        }
        exit(finish.status)
    }
}
