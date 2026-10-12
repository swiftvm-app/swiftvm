import Foundation
import GuestChannel

/// What the half of the agent that runs as root tells the half in a user's session when there is a job
/// for it: to come and get it, by this name.
struct SessionJobNotice: Codable, Sendable, Equatable {
    static let kind = "job"

    var type = SessionJobNotice.kind
    var token: String

    init(token: String) {
        self.token = token
    }
}

/// The jobs the agent does for whoever drives this system from the Mac (``GuestJob``), each on a
/// connection and in a thread of its own.
///
/// Commands run here, in the half of the agent that runs as root. The screen, the mouse and the
/// keyboard belong to whoever is logged in, where root can't reach them: those jobs are handed to the
/// agent's half in that session. That half is told the job's name, connects for it on a socket of its
/// own, and from there speaks to the Mac itself, through this half, which only passes bytes on.
final class AgentJobs: @unchecked Sendable {
    /// How long a job's first line may take to arrive.
    var requestTimeout: TimeInterval = 10
    /// How long the session's half gets to come for a job it was told about.
    var handoverTimeout: TimeInterval = 5

    private let system: any AgentSystem
    private let version: String
    /// Tells the session's half that there is a job for it under this name. `false` when no such half
    /// is there to tell: nobody is logged in.
    private let announce: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var handovers: [String: Handover] = [:]

    /// A job that waits for the session's half to come for it.
    private final class Handover: @unchecked Sendable {
        let arrived = DispatchSemaphore(value: 0)
        var session: Int32?
    }

    init(system: any AgentSystem, version: String, announce: @escaping @Sendable (String) -> Bool) {
        self.system = system
        self.version = version
        self.announce = announce
    }

    /// Serves a job on a connection the Mac has made. Takes the connection over, and returns at once.
    func serve(_ descriptor: Int32) {
        // Whoever hangs up in the middle of a job must not end this process.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { [self] in
            carryOut(on: descriptor)
            GuestJobLine.hangUp(descriptor)
        }
    }

    /// The session's half has connected for a job. Its first line says which. Takes the connection
    /// over, and returns at once.
    func serveSession(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { [self] in
            let handover: Handover? = GuestJobLine.read(from: descriptor, timeout: handoverTimeout)
                .flatMap { GuestMessageCoding.message(SessionJobNotice.self, from: $0) }
                .flatMap { notice in
                    lock.withLock {
                        // Taken and given its connection in one go, so that a job that is just giving
                        // up either finds the connection or leaves it to be closed here.
                        let handover = handovers.removeValue(forKey: notice.token)
                        handover?.session = descriptor
                        return handover
                    }
                }
            guard let handover else {
                // Nothing waits under that name, or not any more.
                close(descriptor)
                return
            }
            handover.arrived.signal()
        }
    }

    // MARK: Private

    private func carryOut(on descriptor: Int32) {
        guard let line = GuestJobLine.read(from: descriptor, timeout: requestTimeout) else { return }
        guard let job = GuestMessageCoding.message(GuestJob.self, from: line) else {
            GuestJobLine.answer(.refusal("That isn't a job."), on: descriptor)
            return
        }
        switch job {
        case .exec(let exec):
            CommandJob.run(exec, on: descriptor, system: system)
        case .screenshot, .pointer, .keys, .tree, .element:
            handOver(line, on: descriptor)
        case .unknown(let type):
            GuestJobLine.answer(.refusal("This agent (\(version)) doesn't know what “\(type.prefix(64))” is."), on: descriptor)
        }
    }

    /// Has the session's half do a job, and passes everything on between it and the Mac until the job
    /// is over.
    private func handOver(_ request: Data, on descriptor: Int32) {
        let token = UUID().uuidString
        let handover = Handover()
        lock.withLock { handovers[token] = handover }
        guard announce(token) else {
            lock.withLock { handovers[token] = nil }
            GuestJobLine.answer(.refusal("Nobody is logged in at this Mac's screen, or the guest tools haven't started in their session yet. The screen, the mouse and the keyboard are those of whoever is logged in."), on: descriptor)
            return
        }
        _ = handover.arrived.wait(timeout: .now() + handoverTimeout)
        // If it comes after this, nothing waits for it any more.
        let session: Int32? = lock.withLock {
            handovers[token] = nil
            return handover.session
        }
        guard let session else {
            GuestJobLine.answer(.refusal("The guest tools in the session of whoever is logged in at this Mac's screen didn't answer."), on: descriptor)
            return
        }
        var line = request
        line.append(UInt8(ascii: "\n"))
        if ByteRelay.writeAll(ArraySlice(line), to: session) {
            ByteRelay.runAndWait(between: descriptor, and: session)
        }
        close(session)
    }
}
