import Foundation
import GuestChannel

/// The sockets the agent listens on and connects to.
enum AgentSockets {
    /// Where the agent's half in a user's session finds the half that runs as root.
    static let sessionSocketPath = "/var/run/swiftvm-agent.sock"
    /// Where it connects once more for every job it does: one with the screen, the mouse or the keyboard.
    static let sessionJobSocketPath = "/var/run/swiftvm-agent-jobs.sock"

    struct SocketError: Error, CustomStringConvertible {
        var description: String

        init(_ what: String) {
            description = "\(what): \(String(cString: strerror(errno)))"
        }
    }

    /// Listens on a port of the socket device (virtio-vsock). Below port 1024 that takes root.
    static func listenOnSocketDevice(port: UInt32) throws -> Int32 {
        let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SocketError("no socket for the socket device") }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = port
        address.svm_cid = UInt32.max   // VMADDR_CID_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            let problem = SocketError("port \(port) of the socket device")
            close(listener)
            throw problem
        }
        return listener
    }

    /// Takes the next connection on the socket device. Returns `nil` for one that doesn't come from the
    /// Mac: something in this system has no business there.
    static func acceptFromHost(on listener: Int32) -> Int32? {
        var peer = sockaddr_vm()
        var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
        let connection = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
        }
        guard connection >= 0 else { return nil }
        guard peer.svm_cid == UInt32(VMADDR_CID_HOST) else {
            close(connection)
            return nil
        }
        return connection
    }

    /// Listens on a Unix socket that every user of this system may connect to.
    static func listenOnUnixSocket(path: String) throws -> Int32 {
        var address = try unixAddress(path)
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SocketError("no socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Who may speak is decided when they connect, by who they are.
        guard bound == 0, chmod(path, 0o666) == 0, listen(listener, 4) == 0 else {
            let problem = SocketError(path)
            close(listener)
            throw problem
        }
        return listener
    }

    /// Takes the next connection on a Unix socket, with the user at its other end.
    static func acceptLocal(on listener: Int32) -> (connection: Int32, user: uid_t)? {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return nil }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(connection, &user, &group) == 0 else {
            close(connection)
            return nil
        }
        return (connection, user)
    }

    /// Connects to a Unix socket. Returns `nil` when nobody listens there.
    static func connectToUnixSocket(path: String) -> Int32? {
        guard var address = try? unixAddress(path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// The user who sits at this system's screen: the one whose session owns the console. Root while
    /// nobody is logged in.
    static func consoleUser() -> uid_t? {
        var status = stat()
        return stat("/dev/console", &status) == 0 ? status.st_uid : nil
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            errno = ENAMETOOLONG
            throw SocketError(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}
