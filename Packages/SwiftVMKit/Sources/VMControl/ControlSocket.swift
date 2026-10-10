import Foundation

public enum ControlSocketError: Error, LocalizedError {
    case pathTooLong(String)
    case system(String, Int32)
    case appNotRunning
    case connectionClosed
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "The control socket path is too long: \(path)"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        case .appNotRunning: "SwiftVM isn't running. Open the app first."
        case .connectionClosed: "The app closed the connection before answering."
        case .invalidMessage: "Received a message that couldn't be understood."
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

/// Accepts control connections on a background thread and hands each request to `handler`.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse
    /// Takes over a connection as a byte stream after a stream request was answered with success. The
    /// connection is closed when it returns.
    public typealias StreamHandler = @Sendable (ControlRequest, Int32) async -> Void

    private let descriptor: Int32
    private let socketURL: URL
    private let handler: Handler

    public init(socketURL: URL = ControlPaths.socket, handler: @escaping Handler, streamHandler: StreamHandler? = nil) throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.socketURL = socketURL
        self.handler = handler
        self.descriptor = try ControlSocket.listen(at: socketURL)
        signal(SIGPIPE, SIG_IGN)
        let thread = Thread { [descriptor, handler] in
            while true {
                let connection = accept(descriptor, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Task.detached {
                    await Self.serve(connection, handler: handler, streamHandler: streamHandler)
                }
            }
        }
        thread.name = "SwiftVM control server"
        thread.start()
    }

    deinit {
        close(descriptor)
        unlink(socketURL.path)
    }

    /// Removes the socket file so clients see that the app is gone.
    public func invalidate() {
        unlink(socketURL.path)
    }

    private static func serve(_ connection: Int32, handler: Handler, streamHandler: StreamHandler?) async {
        defer { close(connection) }
        while let line = ControlSocket.readLine(from: connection) {
            let request = try? JSONDecoder().decode(ControlRequest.self, from: line)
            let response: ControlResponse
            if let request {
                response = await handler(request)
            } else {
                response = .failure("The request couldn't be understood.")
            }
            guard let data = try? JSONEncoder().encode(response) else { return }
            do {
                try ControlSocket.writeLine(data, to: connection)
            } catch {
                return
            }
            if let request, request.command.opensStream, response.ok {
                await streamHandler?(request, connection)
                return
            }
        }
    }
}
