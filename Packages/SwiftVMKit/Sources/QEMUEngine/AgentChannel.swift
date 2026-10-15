import Foundation
import GuestChannel

/// The app's end of the serial line that a Windows guest's agent talks over, with the connections the
/// app has opened on it.
///
/// It stands in for the socket device that QEMU on a Mac doesn't have: ``connect(port:timeout:)`` gives
/// a socket, as connecting over a socket device does, and what goes over it travels in
/// ``ChannelFrame``s. Each connection has a pair of sockets, one end for whoever connected and the other
/// for the channel, which passes bytes between it and the line.
final class AgentChannel: @unchecked Sendable {
    enum ChannelError: Error, LocalizedError {
        /// No agent has said hello on the line since it was last opened.
        case noAgent
        /// The agent has nothing listening on that port.
        case refused(UInt32)
        case timedOut
        case closed

        var errorDescription: String? {
            switch self {
            case .noAgent: "The guest tools don't answer."
            case .refused(let port): "Nothing listens on port \(port) in the guest."
            case .timedOut: "The guest tools didn't answer in time."
            case .closed: "The line to the guest is gone."
            }
        }
    }

    private let descriptor: Int32
    private let lock = NSLock()
    /// Frames go onto the line one whole at a time.
    private let writeLock = NSLock()
    private var reader = ChannelFrame.Reader()
    private var isClosed = false
    /// The descriptor has been closed. Used with the write lock held, as the descriptor is.
    private var isLineClosed = false
    /// An agent has said hello since the line was last opened in the guest.
    private var hasAgent = false
    private var nextConnection: UInt32 = 1
    private var connections: [UInt32: Connection] = [:]
    private var opening: [UInt32: Opening] = [:]

    /// Called on the channel's thread when an agent has said hello on the line.
    var onAgent: (@Sendable () -> Void)?

    /// Takes over `descriptor`, the app's end of the socket QEMU has as the agent's serial port.
    init(descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    }

    /// Starts reading, and says hello. An agent that was running all along, in a guest that was
    /// resumed, believes its connections are still open: it hears the hello and says its own.
    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "app.swiftvm.agent-channel"
        thread.start()
        send(.hello)
    }

    /// Opens a connection to `port` in the guest and returns the app's end of it. The connection
    /// closes when the handle is released.
    func connect(port: UInt32, timeout: TimeInterval = 5) async throws -> FileHandle {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for end in ends {
            _ = fcntl(end, F_SETNOSIGPIPE, 1)
        }
        let (callerEnd, channelEnd) = (ends[0], ends[1])
        let id: UInt32
        do {
            id = try lock.withLock {
                guard !isClosed else { throw ChannelError.closed }
                guard hasAgent else { throw ChannelError.noAgent }
                let id = nextConnection
                nextConnection = nextConnection == UInt32.max ? 1 : nextConnection + 1
                return id
            }
        } catch {
            Darwin.close(callerEnd)
            Darwin.close(channelEnd)
            throw error
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { opening[id] = Opening(continuation: continuation, local: channelEnd, port: port) }
                if !send(.open(id, port: port)) {
                    finishOpening(id, with: .failure(ChannelError.closed))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finishOpening(id, with: .failure(ChannelError.timedOut))
                }
            }
        } catch {
            Darwin.close(callerEnd)
            throw error
        }
        return FileHandle(fileDescriptor: callerEnd, closeOnDealloc: true)
    }

    /// Hangs up on the guest and drops every connection.
    func close() {
        let shouldClose = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        dropEverything(because: ChannelError.closed)
        writeLock.withLock {
            if !isLineClosed {
                shutdown(descriptor, SHUT_RDWR)
            }
        }
    }

    /// The agent's side of the line was closed in the guest: whatever was open is gone, what the agent
    /// was sending may have stopped half way through a frame, and nothing new is opened until an agent
    /// says hello.
    func agentLeft() {
        lock.withLock { reader.reset() }
        dropEverything(because: ChannelError.noAgent)
    }

    /// The agent's side of the line was opened in the guest. The agent says hello, and is asked to
    /// again: one that came before the app had let go of the last would go unheard.
    func agentArrived() {
        send(.hello)
    }

    // MARK: Opening

    private struct Opening {
        var continuation: CheckedContinuation<Void, any Error>
        /// The channel's end of the new connection.
        var local: Int32
        var port: UInt32
    }

    /// Ends the wait for an answer to an open, once: with the agent's answer, the timeout, or the line
    /// going away, whichever comes first.
    private func finishOpening(_ id: UInt32, with result: Result<Void, any Error>) {
        guard let waiting = lock.withLock({ opening.removeValue(forKey: id) }) else { return }
        switch result {
        case .success:
            let connection = Connection(id: id, local: waiting.local)
            let isStillOpen = lock.withLock { () -> Bool in
                guard !isClosed else { return false }
                connections[id] = connection
                return true
            }
            guard isStillOpen else {
                Darwin.close(waiting.local)
                waiting.continuation.resume(throwing: ChannelError.closed)
                return
            }
            startPump(for: connection)
            waiting.continuation.resume()
        case .failure(let error):
            Darwin.close(waiting.local)
            // The agent may yet take a connection that was given up on: it is told it is closed.
            if case ChannelError.timedOut = error {
                _ = send(ChannelFrame(.close, connection: id))
            }
            waiting.continuation.resume(throwing: error)
        }
    }

    // MARK: Connections

    private final class Connection: @unchecked Sendable {
        let id: UInt32
        let local: Int32
        /// What the guest sends goes out to the local end in order, without holding up the line.
        let output: DispatchQueue
        let lock = NSLock()
        var localHasEnded = false
        var guestHasEnded = false
        var isDropped = false
        /// The pump that reads the local end, and the channel that writes to it. The descriptor is
        /// closed when both have let go, so that neither uses its number after it is given to another.
        private var holders = 2

        init(id: UInt32, local: Int32) {
            self.id = id
            self.local = local
            output = DispatchQueue(label: "app.swiftvm.agent-channel.\(id)")
        }

        func letGo() {
            let isLast = lock.withLock {
                holders -= 1
                return holders == 0
            }
            if isLast {
                Darwin.close(local)
            }
        }
    }

    /// Passes what the local end sends on to the guest, until it has no more.
    private func startPump(for connection: Connection) {
        let thread = Thread { [self] in
            defer { connection.letGo() }
            var buffer = [UInt8](repeating: 0, count: ChannelFrame.maximumPayloadLength)
            while true {
                let count = read(connection.local, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count > 0 {
                    guard send(ChannelFrame(.data, connection: connection.id, payload: Data(buffer[0..<count]))) else {
                        drop(connection, tellingGuest: false)
                        return
                    }
                    continue
                }
                if count < 0 {
                    drop(connection, tellingGuest: true)
                    return
                }
                // The local end has no more to send. It may still be listening.
                let isDone = connection.lock.withLock { () -> Bool in
                    connection.localHasEnded = true
                    return connection.guestHasEnded || connection.isDropped
                }
                if isDone {
                    drop(connection, tellingGuest: true)
                } else {
                    _ = send(ChannelFrame(.end, connection: connection.id))
                }
                return
            }
        }
        thread.name = "app.swiftvm.agent-channel.pump"
        thread.start()
    }

    /// Lets go of a connection: tells the guest unless it was the guest's doing, and closes the local
    /// end once what the guest sent before has gone out to it.
    private func drop(_ connection: Connection, tellingGuest: Bool) {
        let wasDropped = connection.lock.withLock {
            defer { connection.isDropped = true }
            return connection.isDropped
        }
        guard !wasDropped else { return }
        lock.withLock { _ = connections.removeValue(forKey: connection.id) }
        if tellingGuest {
            _ = send(ChannelFrame(.close, connection: connection.id))
        }
        connection.output.async {
            // Whoever is still reading the other end learns that nothing more is coming, and so does
            // the pump, which is waiting for the local end.
            shutdown(connection.local, SHUT_RDWR)
            connection.letGo()
        }
    }

    private func dropEverything(because error: any Error) {
        let (open, waiting) = lock.withLock { () -> ([Connection], [UInt32]) in
            hasAgent = false
            defer { connections = [:] }
            return (Array(connections.values), Array(opening.keys))
        }
        for connection in open {
            drop(connection, tellingGuest: false)
        }
        for id in waiting {
            finishOpening(id, with: .failure(error))
        }
    }

    // MARK: The line

    @discardableResult
    private func send(_ frame: ChannelFrame) -> Bool {
        let bytes = frame.encoded
        return writeLock.withLock { !isLineClosed && ByteRelay.writeAll(ArraySlice(bytes), to: descriptor) }
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let (frames, isLost) = lock.withLock { () -> ([ChannelFrame], Bool) in
                let frames = reader.receive(Data(buffer[0..<count]))
                return (frames, reader.isLost)
            }
            if isLost {
                // What came isn't frames. Until the next hello nothing on the line can be trusted,
                // and the agent is asked for one.
                dropEverything(because: ChannelError.noAgent)
                send(.hello)
            }
            for frame in frames {
                handle(frame)
            }
        }
        close()
        writeLock.withLock {
            isLineClosed = true
            Darwin.close(descriptor)
        }
    }

    private func handle(_ frame: ChannelFrame) {
        switch frame.kind {
        case .hello:
            // An agent says hello when it opens the line and when it hears the app's. Either way, what
            // was open before is gone.
            dropEverything(because: ChannelError.noAgent)
            let handler = lock.withLock { () -> (@Sendable () -> Void)? in
                hasAgent = true
                return onAgent
            }
            handler?()
        case .accept:
            finishOpening(frame.connection, with: .success(()))
        case .refuse:
            let port = lock.withLock { opening[frame.connection]?.port } ?? 0
            finishOpening(frame.connection, with: .failure(ChannelError.refused(port)))
        case .data:
            guard let connection = lock.withLock({ connections[frame.connection] }) else { return }
            connection.output.async { [self] in
                if !ByteRelay.writeAll(ArraySlice(frame.payload), to: connection.local) {
                    // Nobody listens at the local end any more.
                    drop(connection, tellingGuest: true)
                }
            }
        case .end:
            guard let connection = lock.withLock({ connections[frame.connection] }) else { return }
            let isDone = connection.lock.withLock { () -> Bool in
                connection.guestHasEnded = true
                return connection.localHasEnded
            }
            if isDone {
                drop(connection, tellingGuest: true)
            } else {
                connection.output.async { shutdown(connection.local, SHUT_WR) }
            }
        case .close:
            guard let connection = lock.withLock({ connections[frame.connection] }) else { return }
            drop(connection, tellingGuest: false)
        case .open:
            // Only the app opens connections.
            _ = send(ChannelFrame(.refuse, connection: frame.connection))
        }
    }
}
