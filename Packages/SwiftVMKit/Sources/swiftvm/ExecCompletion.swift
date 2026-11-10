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
    // The watchdog and the reader can finish together. Write and exit under the same lock.
    private let finishing = Mutex(())

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

    func finish(_ completion: ExecCompletion, status: Int32, diagnostic: String? = nil) -> Never {
        finishing.withLock { _ in
            if let diagnostic {
                FileHandle.standardError.write(Data("swiftvm: \(diagnostic)\n".utf8))
            }
            do {
                try write(completion)
            } catch {
                // Do not pass along a guest success after losing its separate completion record.
                fail("Couldn't write the exec completion record.", status: GuestJobs.failedStatus)
            }
            exit(status)
        }
    }
}
