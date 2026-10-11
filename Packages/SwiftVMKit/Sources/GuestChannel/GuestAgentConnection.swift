import Foundation

/// One open line to the agent in a guest: sends the app's messages and hands out the agent's as they
/// arrive.
///
/// The line is a file descriptor, whatever is behind it. Nobody who uses this waits on it: reading happens
/// when there is something to read, and what can't be written at once is written from a queue of its own
/// as the agent takes it in. An agent that takes nothing in for a while has stopped listening, which
/// closes the line.
public final class GuestAgentConnection: @unchecked Sendable {
    /// What the agent sends, in order, from the moment the line opens. Answers to requests aren't among
    /// them: they go to whoever asked. The sequence ends when the line is closed, by either side.
    public let messages: AsyncStream<AgentMessage>

    private let handle: FileHandle
    private let queue = DispatchQueue(label: "SwiftVM guest agent connection")
    /// Where what didn't fit at once is written. Never the queue that reads: an agent that waits for
    /// its own words to be taken before it listens again would wait for good.
    private let writeQueue = DispatchQueue(label: "SwiftVM guest agent connection, writing")
    private let source: any DispatchSourceRead
    private let incoming: AsyncStream<AgentMessage>.Continuation
    private let lock = NSLock()
    /// Used on `queue` only.
    private var framer = GuestMessageFramer()
    /// The rest is used with the lock held.
    private var nextRequestID = 1
    private var waiting: [Int: CheckedContinuation<GuestRequestResult?, Never>] = [:]
    private var isClosed = false
    /// What has been sent and not yet fitted into the line, in order.
    private var unwritten = Data()
    private var isWritingLater = false

    /// How many messages wait for whoever reads ``messages`` before the oldest are dropped.
    static let backlogLimit = 256
    /// How much may wait to be written before the agent counts as gone: a few of the longest messages.
    static let unwrittenLimit = 4 * GuestProtocol.maximumLineLength
    /// How long the agent may go without taking any of it in.
    static let writeTimeout: Duration = .seconds(5)

    /// Takes over `handle`, which is closed when the line is.
    public init(handle: FileHandle) {
        self.handle = handle
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        // Writing to an agent that has gone must not end this process.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        // An agent has little to say. One that says a lot faster than it is listened to loses its oldest
        // words rather than fill this Mac's memory with them.
        (messages, incoming) = AsyncStream.makeStream(of: AgentMessage.self, bufferingPolicy: .bufferingNewest(Self.backlogLimit))
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readWhatHasArrived() }
        // The descriptor may only be closed once nothing is watching it or writing to it any more. The
        // line is marked closed before this runs, so whatever is still being written is the last of it.
        source.setCancelHandler { [handle, writeQueue] in
            writeQueue.sync {}
            try? handle.close()
        }
        source.resume()
    }

    deinit {
        close()
    }

    /// Sends a message. Returns `false` if the line is closed, or was closed because the agent isn't
    /// taking anything in.
    @discardableResult
    public func send(_ message: HostMessage) -> Bool {
        send(line: GuestMessageCoding.line(for: message))
    }

    /// Sends a line that ``GuestMessageCoding`` made. Returns as ``send(_:)`` does.
    @discardableResult
    public func send(line: Data) -> Bool {
        let isSent = lock.withLock { () -> Bool? in
            guard !isClosed else { return nil }
            if unwritten.isEmpty {
                guard let written = writeWhatFits(of: line) else { return false }
                guard written < line.count else { return true }
                unwritten = Data(line.dropFirst(written))
            } else {
                // Behind what is already waiting. An agent that lets this much pile up is as good as gone.
                guard unwritten.count + line.count <= Self.unwrittenLimit else { return false }
                unwritten.append(line)
            }
            if !isWritingLater {
                isWritingLater = true
                writeQueue.async { [weak self] in self?.writeTheRest() }
            }
            return true
        }
        if isSent == false {
            close()
        }
        return isSent == true
    }

    /// Sends a request and waits for the agent's answer.
    ///
    /// - Parameter message: Makes the request from the `id` it has to carry.
    /// - Returns: The answer, or `nil` if none came in time or the line closed first.
    public func request(timeout: Duration = .seconds(5), _ message: @Sendable (Int) -> HostMessage) async -> GuestRequestResult? {
        let id = lock.withLock {
            defer { nextRequestID += 1 }
            return nextRequestID
        }
        let request = message(id)
        return await withCheckedContinuation { (continuation: CheckedContinuation<GuestRequestResult?, Never>) in
            let isWaiting = lock.withLock {
                guard !isClosed else { return false }
                waiting[id] = continuation
                return true
            }
            guard isWaiting else {
                continuation.resume(returning: nil)
                return
            }
            guard send(request) else {
                // Closing the line has answered everyone who was waiting, this request included.
                return
            }
            let components = timeout.components
            let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))) { [weak self] in
                self?.answer(id, with: nil)
            }
        }
    }

    /// Whether the line has been closed, by either side.
    var isClosedNow: Bool {
        lock.withLock { isClosed }
    }

    /// Hangs up. Everyone waiting for an answer gets none, and ``messages`` ends.
    public func close() {
        let unanswered: [CheckedContinuation<GuestRequestResult?, Never>]? = lock.withLock {
            guard !isClosed else { return nil }
            isClosed = true
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        guard let unanswered else { return }
        source.cancel()
        incoming.finish()
        for continuation in unanswered {
            continuation.resume(returning: nil)
        }
    }

    // MARK: Private

    /// Writes as much of `bytes` as the line takes right now and returns how much that was, or `nil`
    /// when the line is broken. Called with the lock held.
    private func writeWhatFits(of bytes: Data) -> Int? {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(handle.fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN {
                    break
                } else if errno != EINTR {
                    return nil
                }
            }
            return offset
        }
    }

    /// Called on `writeQueue`. Writes what is waiting as the agent makes room for it, and gives the
    /// agent up when it makes none.
    private func writeTheRest() {
        var lastProgress = ContinuousClock.now
        while true {
            var room = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            // Never for long: the line may have been closed in the meantime, and its descriptor is
            // only let go once this has returned.
            _ = poll(&room, 1, 50)
            let isBroken = lock.withLock { () -> Bool? in
                guard !isClosed else {
                    isWritingLater = false
                    return nil
                }
                guard let written = writeWhatFits(of: unwritten) else {
                    isWritingLater = false
                    return true
                }
                if written > 0 {
                    unwritten = Data(unwritten.dropFirst(written))
                    lastProgress = .now
                }
                if unwritten.isEmpty {
                    isWritingLater = false
                    return nil
                }
                return ContinuousClock.now - lastProgress > Self.writeTimeout ? true : false
            }
            switch isBroken {
            case nil:
                return
            case true?:
                lock.withLock { isWritingLater = false }
                close()
                return
            case false?:
                continue
            }
        }
    }

    private func answer(_ id: Int, with result: GuestRequestResult?) {
        lock.withLock { waiting.removeValue(forKey: id) }?.resume(returning: result)
    }

    /// Called on `queue` when the descriptor has something to read, or has reached its end.
    private func readWhatHasArrived() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                guard let lines = try? framer.receive(Data(buffer[0..<count])) else {
                    close()
                    return
                }
                for line in lines {
                    // A line that isn't a message is skipped rather than held against the agent.
                    guard let message = GuestMessageCoding.message(AgentMessage.self, from: line) else { continue }
                    if case .result(let result) = message {
                        answer(result.id, with: result)
                    } else {
                        incoming.yield(message)
                    }
                }
            } else if count == 0 {
                close()
                return
            } else if errno == EAGAIN {
                return
            } else if errno != EINTR {
                close()
                return
            }
        }
    }
}
