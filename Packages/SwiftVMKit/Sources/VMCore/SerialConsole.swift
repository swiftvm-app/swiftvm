import Foundation

/// A machine's serial console: a line to the guest that carries text both ways.
///
/// It belongs to the machine rather than to one run of it, like a cable that stays plugged in when the
/// computer restarts: whoever is listening keeps listening across restarts, and what the guest printed is
/// kept in a log file and a short transcript.
public final class SerialConsole: @unchecked Sendable {
    public enum Event: Sendable {
        /// Bytes the guest printed.
        case output(Data)
        /// The guest was plugged in (it is starting) or unplugged (it has stopped).
        case connectionChanged(isConnected: Bool)
    }

    /// The two ends the engine needs for a guest that is about to start.
    public struct GuestEnd {
        /// The engine reads what is typed to the guest from this.
        public let input: FileHandle
        /// The engine writes what the guest prints to this.
        public let output: FileHandle
    }

    private let logURL: URL?
    private let lock = NSLock()
    private var listeners: [UUID: @Sendable (Event) -> Void] = [:]
    private var recent = Data()
    private var toGuest: FileHandle?
    private var fromGuest: FileHandle?
    private var log: FileHandle?
    private var loggedBytes = 0
    /// Where a read from the guest lands before it is passed on. Used with the lock held.
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    /// How much of the guest's output is kept in memory for someone who starts listening later.
    static let transcriptLimit = 256 * 1024
    /// The log file starts over when it reaches this size; the previous one is kept next to it.
    static let logLimit = 4 * 1024 * 1024

    /// - Parameter logURL: Where the guest's output is written, or `nil` to keep no log.
    public init(logURL: URL? = nil) {
        self.logURL = logURL
    }

    deinit {
        fromGuest?.readabilityHandler = nil
    }

    // MARK: The guest's end

    /// Plugs the console into a guest that is about to start.
    ///
    /// - Parameter continuing: The guest is resumed rather than booted, so the log carries on instead of
    ///   starting over.
    public func connect(continuing: Bool = false) -> GuestEnd {
        disconnect()
        let input = Pipe()
        let output = Pipe()
        // Typing to a guest that has gone, or that isn't reading, must neither end this process nor hold
        // it up.
        let writeDescriptor = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(writeDescriptor, F_SETFL, fcntl(writeDescriptor, F_GETFL) | O_NONBLOCK)
        // Reading doesn't wait either: the line is read when it has something, and once more when the
        // guest is unplugged, by whichever of the two gets there first.
        let line = output.fileHandleForReading
        _ = fcntl(line.fileDescriptor, F_SETFL, fcntl(line.fileDescriptor, F_GETFL) | O_NONBLOCK)

        lock.withLock {
            toGuest = input.fileHandleForWriting
            fromGuest = line
            if !continuing {
                // A machine that boots starts with a clean slate; one that resumes still shows its last screen.
                recent.removeAll()
            }
            openLog(continuing: continuing)
        }
        line.readabilityHandler = { [weak self] handle in
            if self?.lineHasOutput(handle) != true {
                // The engine closed its end, or the console has been unplugged from this line.
                handle.readabilityHandler = nil
            }
        }
        notify(.connectionChanged(isConnected: true))
        return GuestEnd(input: input.fileHandleForReading, output: output.fileHandleForWriting)
    }

    /// Unplugs the console from a guest that has stopped. Listeners stay.
    ///
    /// What the guest printed last is still taken in: its final lines are often on their way when it
    /// stops, and they are the ones that say why.
    public func disconnect() {
        let wasConnected = lock.withLock {
            guard toGuest != nil else { return false }
            if let fromGuest {
                fromGuest.readabilityHandler = nil
                // A guest that has stopped prints nothing more, but this doesn't count on it: the rounds
                // are enough to empty a full pipe many times over, and then it is over.
                var rounds = 0
                while rounds < 64, read(from: fromGuest) == .output {
                    rounds += 1
                }
            }
            // The reading end isn't closed here but when its handle is released: a call that is on its
            // way on another thread keeps the handle alive until it is done, where closing would pull
            // the descriptor out from under it.
            try? toGuest?.close()
            try? log?.close()
            toGuest = nil
            fromGuest = nil
            log = nil
            return true
        }
        if wasConnected {
            notify(.connectionChanged(isConnected: false))
        }
    }

    public var isConnected: Bool {
        lock.withLock { toGuest != nil }
    }

    // MARK: The host's end

    /// Types `data` to the guest. Dropped if no guest is connected or the guest isn't reading.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        // The lock is held while writing so that the line can't be closed, and its descriptor number given
        // to some other file, in the middle of it. The write never waits: the descriptor doesn't block.
        lock.withLock {
            guard let descriptor = toGuest?.fileDescriptor else { return }
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if errno != EINTR {
                        // Full (the guest isn't reading) or closed.
                        return
                    }
                }
            }
        }
    }

    /// The most recent output, up to ``transcriptLimit`` bytes.
    public var transcript: Data {
        lock.withLock { Data(recent.suffix(Self.transcriptLimit)) }
    }

    /// Starts listening and returns a token for ``removeListener(_:)``.
    ///
    /// The listener is called on a background thread, in order, and must return quickly without calling
    /// back into the console: the guest's output waits for it.
    public func addListener(_ listener: @escaping @Sendable (Event) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { listeners[token] = listener }
        return token
    }

    public func removeListener(_ token: UUID) {
        lock.withLock { listeners[token] = nil }
    }

    // MARK: Private

    private enum LineState {
        /// Bytes were read and passed on.
        case output
        /// Nothing is waiting right now.
        case quiet
        /// The other end is closed, or the line can't be read.
        case closed
    }

    /// Called when the line from the guest has something to read. Returns `false` when this line is
    /// finished with.
    private func lineHasOutput(_ line: FileHandle) -> Bool {
        lock.withLock {
            // Unplugged while this call was on its way. `disconnect` has taken in what was left.
            guard fromGuest === line else { return false }
            return read(from: line) != .closed
        }
    }

    /// Reads what is waiting on the line, up to one buffer of it, and passes it on. Never waits. The lock
    /// must be held, which is also what keeps the output in order when two threads read.
    private func read(from line: FileHandle) -> LineState {
        while true {
            let count = Darwin.read(line.fileDescriptor, &readBuffer, readBuffer.count)
            if count > 0 {
                receive(Data(readBuffer[0..<count]))
                return .output
            }
            if count == 0 {
                return .closed
            }
            if errno != EINTR {
                return errno == EAGAIN ? .quiet : .closed
            }
        }
    }

    /// Records output and passes it to the listeners. The lock must be held: listeners are called with it
    /// so that they see output in order.
    private func receive(_ data: Data) {
        recent.append(data)
        if recent.count > 2 * Self.transcriptLimit {
            // A fresh copy of the tail, not a slice: a slice would keep everything before it alive,
            // and the console of a machine that runs for weeks would hold all it ever printed.
            recent = Data(recent.suffix(Self.transcriptLimit))
        }
        writeToLog(data)
        for listener in listeners.values {
            listener(.output(data))
        }
    }

    private func notify(_ event: Event) {
        lock.withLock {
            for listener in listeners.values {
                listener(event)
            }
        }
    }

    private func openLog(continuing: Bool) {
        guard let logURL else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !continuing || !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        log = try? FileHandle(forWritingTo: logURL)
        loggedBytes = Int((try? log?.seekToEnd()) ?? 0)
    }

    private func writeToLog(_ data: Data) {
        guard let logURL, log != nil else { return }
        if loggedBytes + data.count > Self.logLimit {
            try? log?.close()
            let previous = logURL.deletingPathExtension().appendingPathExtension("previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: logURL, to: previous)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try? FileHandle(forWritingTo: logURL)
            loggedBytes = 0
        }
        try? log?.write(contentsOf: data)
        loggedBytes += data.count
    }
}
