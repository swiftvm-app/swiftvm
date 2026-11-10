import Foundation

public enum ControlSocketError: Error, LocalizedError {
    case pathTooLong(String)
    case system(String, Int32)
    case appNotRunning
    case connectionClosed
    case invalidMessage
    case endpointInUse
    case unsafeEndpoint

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "The control socket path is too long: \(path)"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        case .appNotRunning: "\(AppIdentity.current.name) isn't running. Open the app first."
        case .connectionClosed: "The app closed the connection before answering."
        case .invalidMessage: "Received a message that couldn't be understood."
        case .endpointInUse: "A controller is already listening in this SwiftVM data folder. Use a separate SWIFTVM_HOME."
        case .unsafeEndpoint: "The existing control socket is unsafe or could not be shown to be stale."
        }
    }
}

/// Low-level Unix domain socket helpers shared by the app's server and the command-line client.
public enum ControlSocket {
    static func address(for url: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = url.path
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw ControlSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        return address
    }

    /// Creates a listening socket at `url`, replacing a stale one. Only the current user can connect.
    public static func listen(at url: URL) throws -> Int32 {
        var address = try address(for: url)
        try requireStaleEndpoint(at: url)
        unlink(url.path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw ControlSocketError.system("bind", code)
        }
        chmod(url.path, 0o600)
        guard Darwin.listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            throw ControlSocketError.system("listen", code)
        }
        return descriptor
    }

    /// Only a refused or vanished endpoint is safe to replace. Nonblocking connect also refuses a
    /// live controller whose backlog is full, without waiting for it or mistaking it for a stale file.
    static func requireStaleEndpoint(at url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return }
            throw ControlSocketError.system("inspect control socket", errno)
        }
        guard information.st_mode & S_IFMT == S_IFSOCK, information.st_uid == getuid() else {
            throw ControlSocketError.unsafeEndpoint
        }
        var address = try address(for: url)
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ControlSocketError.system("probe control socket", errno) }
        defer { close(probe) }
        let flags = fcntl(probe, F_GETFL)
        guard flags >= 0, fcntl(probe, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ControlSocketError.system("probe control socket", errno)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { throw ControlSocketError.endpointInUse }
        guard errno == ECONNREFUSED || errno == ENOENT else { throw ControlSocketError.unsafeEndpoint }
    }

    public static func connect(to url: URL) throws -> Int32 {
        var address = try address(for: url)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.system("socket", errno) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            if code == ENOENT || code == ECONNREFUSED {
                throw ControlSocketError.appNotRunning
            }
            throw ControlSocketError.system("connect", code)
        }
        return descriptor
    }

    /// Reads up to and including the next newline; returns the line without it, or `nil` at end of stream.
    public static func readLine(from descriptor: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") { return line }
                line.append(byte)
            } else if count == 0 {
                return line.isEmpty ? nil : line
            } else if errno != EINTR {
                return nil
            }
        }
    }

    public static func writeLine(_ data: Data, to descriptor: Int32) throws {
        var message = data
        message.append(UInt8(ascii: "\n"))
        try message.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    throw ControlSocketError.system("write", errno)
                }
            }
        }
    }
}

/// Sends requests to the running app.
public struct ControlClient: Sendable {
    public let socketURL: URL

    public init(socketURL: URL = ControlPaths.socket) {
        self.socketURL = socketURL
    }

    /// Sends `request` and waits for the app's answer, however long the operation takes.
    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let descriptor = try ControlSocket.connect(to: socketURL)
        defer { close(descriptor) }
        return try exchange(request, over: descriptor)
    }

    /// Sends a request that turns the connection into a byte stream, such as ``ControlRequest/Command/console``.
    ///
    /// If the app agrees, the returned descriptor carries the stream and is the caller's to close. If it
    /// refuses, the descriptor is `nil` and the response says why.
    public func openStream(_ request: ControlRequest) throws -> (response: ControlResponse, descriptor: Int32?) {
        let descriptor = try ControlSocket.connect(to: socketURL)
        do {
            let response = try exchange(request, over: descriptor)
            guard response.ok else {
                close(descriptor)
                return (response, nil)
            }
            return (response, descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func exchange(_ request: ControlRequest, over descriptor: Int32) throws -> ControlResponse {
        try ControlSocket.writeLine(JSONEncoder().encode(request), to: descriptor)
        guard let line = ControlSocket.readLine(from: descriptor) else {
            throw ControlSocketError.connectionClosed
        }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else {
            throw ControlSocketError.invalidMessage
        }
        return response
    }
}

/// Tells when a tool has gone from a connection on which it says nothing after its request.
public enum ControlHangUp {
    /// Calls `gone` once when the other side of `connection` hangs up. Cancel what this returns before
    /// the connection is closed.
    public static func watch(_ connection: Int32, gone: @escaping @Sendable () -> Void) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: connection, queue: .global())
        source.setEventHandler { [weak source] in
            var byte: UInt8 = 0
            guard recv(connection, &byte, 1, MSG_PEEK) == 0 else { return }
            source?.cancel()
            gone()
        }
        source.resume()
        return source
    }
}

/// Accepts control connections on a background thread and hands each request to `handler`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse
    /// Takes over a connection as a byte stream. The connection is closed when it returns.
    public typealias Stream = @Sendable (Int32) async -> Void
    /// Answers a request that opens a stream (``ControlRequest/Command/opensStream``). With a successful
    /// answer comes what serves the stream; whatever the stream needs is set up before answering, so that
    /// a failure to do so can still be the answer.
    public typealias StreamHandler = @Sendable (ControlRequest) async -> (response: ControlResponse, stream: Stream?)

    private let descriptor: Int32
    private let socketURL: URL
    private let handler: Handler
    private let ownership: LibraryOwnership
    /// The inode bound here: cleanup must not remove an externally replaced pathname.
    private let socketFile: (device: dev_t, inode: ino_t)?

    public init(socketURL: URL = ControlPaths.socket, ownership: LibraryOwnership? = nil,
                handler: @escaping Handler, streamHandler: StreamHandler? = nil) throws {
        let directory = socketURL.deletingLastPathComponent()
        let ownership = try ownership ?? LibraryOwnership(at: directory)
        guard ownership.directory.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw LibraryOwnership.Problem.wrongDirectory
        }
        self.ownership = ownership
        self.socketURL = socketURL
        self.handler = handler
        self.descriptor = try ControlSocket.listen(at: socketURL)
        var information = stat()
        socketFile = stat(socketURL.path, &information) == 0 ? (information.st_dev, information.st_ino) : nil
        signal(SIGPIPE, SIG_IGN)
        let thread = Thread { [descriptor, handler, ownership] in
            while true {
                let connection = accept(descriptor, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Task.detached {
                    defer { withExtendedLifetime(ownership) {} }
                    await Self.serve(connection, handler: handler, streamHandler: streamHandler)
                }
            }
        }
        thread.name = "SwiftVM control server"
        thread.start()
    }

    deinit {
        // Wake accept before releasing its descriptor or the ownership held by its thread.
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        invalidate()
    }

    /// Removes this server's socket path. Ownership remains held until the server and its requests
    /// finish, and a replacement at the same pathname is never removed.
    public func invalidate() {
        var information = stat()
        guard let socketFile, stat(socketURL.path, &information) == 0,
              information.st_dev == socketFile.device, information.st_ino == socketFile.inode
        else { return }
        unlink(socketURL.path)
    }

    private static func serve(_ connection: Int32, handler: Handler, streamHandler: StreamHandler?) async {
        defer { close(connection) }
        while let line = ControlSocket.readLine(from: connection) {
            let request = try? JSONDecoder().decode(ControlRequest.self, from: line)
            var response = ControlResponse.failure("The request couldn't be understood.")
            var stream: Stream?
            if let request, request.command.opensStream {
                if let streamHandler {
                    (response, stream) = await streamHandler(request)
                } else {
                    response = .failure("This command isn't available.")
                }
            } else if let request {
                response = await handler(request)
            }
            guard let data = try? JSONEncoder().encode(response) else { return }
            do {
                try ControlSocket.writeLine(data, to: connection)
            } catch {
                return
            }
            if response.ok, let stream {
                await stream(connection)
                return
            }
        }
    }
}
