import Foundation

/// Carries a conversation between two sockets, such as the `swiftvm` tool on one side and a port in a
/// guest on the other. It is here, with the protocol, because both ends of the socket device relay: the
/// app on the Mac, and the agent in a macOS guest between its two halves.
public enum ByteRelay {
    /// Copies bytes both ways between `first` and `second` and returns when the conversation is over.
    ///
    /// A side that has said everything it had to say (end of stream) is passed on as such, and the other
    /// side can still answer. When either side fails, both are shut down. The descriptors stay open and
    /// remain the caller's to close.
    ///
    /// The end of one direction doesn't end the other, so this lasts for as long as either side keeps its
    /// own direction open. A side that has gone away without the other one noticing (it neither sends
    /// nor hangs up) holds the relay until it does, or until its descriptor is closed from outside.
    ///
    /// - Parameter patienceAfterFirstEnds: Where the end of what `first` sends ends the conversation, how
    ///   long `second` gets to say the rest of what it has to say. After that both are shut down: a
    ///   `second` that keeps its direction open for good doesn't hold the relay for good. Without it,
    ///   each direction lasts for as long as its sender likes.
    public static func run(between first: Int32, and second: Int32, patienceAfterFirstEnds: TimeInterval? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            start(between: first, and: second, patienceAfterFirstEnds: patienceAfterFirstEnds).notify(queue: .global()) {
                continuation.resume()
            }
        }
    }

    /// The same for a caller that has a thread to spend on it: returns when the conversation is over.
    public static func runAndWait(between first: Int32, and second: Int32) {
        start(between: first, and: second, patienceAfterFirstEnds: nil).wait()
    }

    /// Starts copying both ways. The group is left when both directions have come to their end.
    private static func start(between first: Int32, and second: Int32, patienceAfterFirstEnds: TimeInterval?) -> DispatchGroup {
        let group = DispatchGroup()
        let secondHasEnded = DispatchSemaphore(value: 0)
        for (source, destination) in [(first, second), (second, first)] {
            group.enter()
            Thread.detachNewThread {
                if !copy(from: source, to: destination) {
                    // Wakes the other direction, which may be waiting for bytes that won't come.
                    shutdown(source, SHUT_RDWR)
                    shutdown(destination, SHUT_RDWR)
                } else if source == first, let patienceAfterFirstEnds,
                          secondHasEnded.wait(timeout: .now() + patienceAfterFirstEnds) == .timedOut {
                    shutdown(first, SHUT_RDWR)
                    shutdown(second, SHUT_RDWR)
                }
                if source == second {
                    secondHasEnded.signal()
                }
                group.leave()
            }
        }
        return group
    }

    /// Copies from `source` to `destination` until `source` ends, then tells `destination` that nothing
    /// more is coming. Returns `false` if either descriptor failed instead.
    @discardableResult
    public static func copy(from source: Int32, to destination: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count == 0 {
                // Something that can't be closed in one direction only is left to the caller.
                return shutdown(destination, SHUT_WR) == 0 || errno == ENOTSOCK || errno == ENOTCONN
            }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard writeAll(buffer[0..<count], to: destination) else { return false }
        }
    }

    /// Writes all of `bytes`, however many calls that takes. Returns `false` if the descriptor failed.
    public static func writeAll(_ bytes: ArraySlice<UInt8>, to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
    }
}
