import Foundation

/// One open line to the agent in a guest: sends the app's messages and hands out the agent's as they
/// arrive.
///
/// The line is a file descriptor, whatever is behind it. Nothing here waits on it: reading happens when
/// there is something to read, and a message that can't be written at once means the agent has stopped
/// listening, which closes the line.
public final class GuestAgentConnection: @unchecked Sendable {
    /// What the agent sends, in order, from the moment the line opens. Answers to requests aren't among
    /// them: they go to whoever asked. The sequence ends when the line is closed, by either side.
    public let messages: AsyncStream<AgentMessage>

    private let handle: FileHandle
    private let queue = DispatchQueue(label: "SwiftVM guest agent connection")
    private let source: any DispatchSourceRead
    private let incoming: AsyncStream<AgentMessage>.Continuation
    private let lock = NSLock()
    /// Used on `queue` only.
    private var framer = GuestMessageFramer()
    /// The rest is used with the lock held.
    private var nextRequestID = 1
    private var waiting: [Int: CheckedContinuation<GuestRequestResult?, Never>] = [:]
    private var isClosed = false

    /// How many messages wait for whoever reads ``messages`` before the oldest are dropped.
    static let backlogLimit = 256

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
        // The descriptor may only be closed once nothing is watching it any more, which is here.
        source.setCancelHandler { [handle] in try? handle.close() }
        source.resume()
    }

    deinit {
        close()
    }

    /// Sends a message. Returns `false` if the line is closed, or was closed because the agent isn't
    /// taking anything in.
    @discardableResult
    public func send(_ message: HostMessage) -> Bool {
        let line = GuestMessageCoding.line(for: message)
        let isSent = lock.withLock { () -> Bool? in
            guard !isClosed else { return nil }
            return line.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(handle.fileDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if errno != EINTR {
                        // Full or broken. Messages are a few hundred bytes; an agent that lets them
                        // pile up is as good as gone, and half a message can't be taken back.
                        return false
                    }
                }
                return true
            }
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
