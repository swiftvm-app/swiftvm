import Foundation

/// Checks whether a guest answers at an address.
public enum Reachability {
    /// Whether a TCP connection to `address:port` succeeds within `timeout`.
    public static func canConnect(to address: IPv4Address, port: UInt16, timeout: Duration = .milliseconds(300)) async -> Bool {
        await Task.detached(priority: .utility) {
            connectBlocking(to: address, port: port, timeout: timeout)
        }.value
    }

    private static func connectBlocking(to address: IPv4Address, port: UInt16, timeout: Duration) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else { return false }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr = address.inAddr
        let result = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        guard poll(&pollDescriptor, 1, max(milliseconds, 1)) == 1 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }
}
