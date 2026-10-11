import Foundation
import GuestChannel

/// One open line to someone who speaks the protocol: the app at the far end of the socket device, or the
/// agent's other half in this system.
///
/// Everything about a line happens on the queue it was made for, which is what makes it safe to hand
/// around. Reading happens when there is something to read. Writing waits for the other side to take it
/// in, but not for long: whoever takes nothing in has stopped listening, and the line ends.
final class AgentLine: @unchecked Sendable {
    /// Called with every line that arrives, without its line break.
    var onLine: ((Data) -> Void)?
    /// Called once when the other side has hung up or the line broke. Not called for ``close()``.
    var onEnd: (() -> Void)?
    private(set) var isOpen = true

    private let descriptor: Int32
    private let source: any DispatchSourceRead
    private var framer = GuestMessageFramer()

    /// Takes over `descriptor`, which is closed when the line is. Nothing is read before ``start()``.
    init(descriptor: Int32, queue: DispatchQueue, sendTimeout: TimeInterval = 5) {
        self.descriptor = descriptor
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var patience = timeval(tv_sec: Int(sendTimeout), tv_usec: Int32((sendTimeout - sendTimeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readWhatHasArrived() }
        // The descriptor may only be closed once nothing is watching it any more, which is here.
        source.setCancelHandler { Darwin.close(descriptor) }
    }

    deinit {
        if isOpen {
            source.cancel()
        }
        // A source that was never resumed can't be let go of.
        if !hasStarted {
            source.resume()
        }
    }

    private var hasStarted = false

    /// Starts reading. Set ``onLine`` and ``onEnd`` first.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        source.resume()
    }

    /// Sends a line that ``GuestMessageCoding`` made. Returns `false` when the line is over, or ends
    /// because the other side doesn't take it.
    @discardableResult
    func send(_ line: Data) -> Bool {
        guard isOpen else { return false }
        let isSent = line.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
        if !isSent {
            end()
        }
        return isSent
    }

    /// Hangs up.
    func close() {
        guard isOpen else { return }
        isOpen = false
        source.cancel()
    }

    // MARK: Private

    private func end() {
        guard isOpen else { return }
        close()
        onEnd?()
    }

    private func readWhatHasArrived() {
        guard isOpen else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
            // Whatever sends a line longer than any message isn't speaking the protocol.
            guard let lines = try? framer.receive(Data(buffer[0..<count])) else {
                end()
                return
            }
            for line in lines where isOpen {
                onLine?(line)
            }
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
            end()
        }
    }
}
