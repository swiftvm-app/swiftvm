import Darwin
import Foundation

/// Serves the Mac's shared folders to guests that can't have them through a file-sharing device:
/// Windows guests on QEMU, which map them as a drive over WebDAV.
///
/// It listens only on the Mac's address on the virtual network, and only answers guests on that
/// network. Each machine has a path of its own, a secret that its agent is told and nobody else, and
/// sees only its own folders under it: the guests share a network, not their folders.
public final class SharedFolderServer: @unchecked Sendable {
    public enum ServerError: Error, LocalizedError {
        case couldNotListen(String)

        public var errorDescription: String? {
            switch self {
            case .couldNotListen(let reason): "The shared folders couldn't be offered to the guest: \(reason)"
            }
        }
    }

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var address = ""
    private var port: UInt16 = 0
    /// Who may connect, by their address as text.
    private var isAllowed: @Sendable (String) -> Bool = { _ in false }
    private var handlers: [String: WebDAVHandler] = [:]
    /// The secret path of each machine that shares folders, by the machine.
    private var paths: [String: String] = [:]
    private var connectionCount = 0

    /// How many connections are served at once. Windows opens a few.
    static let connectionLimit = 64
    /// How long a connection may go without sending or taking anything: a guest that stopped leaves
    /// its connections open.
    static let idleTimeout = 120

    public init() {}

    /// Where a machine's folders are, once ``share(_:for:)`` has given them a path: `http://…/<secret>/`.
    public func location(for machine: String) -> URL? {
        lock.withLock {
            guard listener >= 0, let path = paths[machine] else { return nil }
            return URL(string: "http://\(address):\(port)\(path)/")
        }
    }

    /// Listens on `address`, which has to be one of the Mac's own, unless it does already. Only those
    /// that `isAllowed` says yes to are answered.
    public func start(on address: String, isAllowed: @escaping @Sendable (String) -> Bool) throws {
        let isRunning = lock.withLock { () -> Bool in
            if listener >= 0, self.address == address { return true }
            return false
        }
        guard !isRunning else { return }
        stop()

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.couldNotListen(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var socketAddress = sockaddr_in()
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_port = 0
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            close(descriptor)
            throw ServerError.couldNotListen("\(address) isn't an address.")
        }
        let bound = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw ServerError.couldNotListen(reason)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &socketAddress) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        lock.withLock {
            listener = descriptor
            self.address = address
            port = UInt16(bigEndian: socketAddress.sin_port)
            self.isAllowed = isAllowed
        }
        let thread = Thread { [self] in acceptLoop(descriptor) }
        thread.name = "app.swiftvm.shared-folders"
        thread.start()
    }

    /// Stops listening. Connections that are open finish what they are doing.
    public func stop() {
        let descriptor = lock.withLock { () -> Int32 in
            defer { listener = -1 }
            return listener
        }
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    /// Gives `machine` its folders, under a path of its own that stays the same while the app runs.
    @discardableResult
    public func share(_ locations: [SharedLocation], for machine: String) -> String {
        lock.withLock {
            let path = paths[machine] ?? "/" + Self.secret()
            paths[machine] = path
            handlers[path] = WebDAVHandler(locations: locations, prefix: path)
            return path
        }
    }

    /// Stops serving the folders of every machine but `machines`: those that were deleted.
    public func unshare(allBut machines: Set<String>) {
        lock.withLock {
            for (machine, path) in paths where !machines.contains(machine) {
                paths[machine] = nil
                handlers[path] = nil
            }
        }
    }

    private static func secret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Connections

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let connection = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(descriptor, $0, &length) }
            }
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                // Out of descriptors for a moment: those of connections that end come back.
                if errno == EMFILE || errno == ENFILE {
                    usleep(100_000)
                    continue
                }
                return
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &peer.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            let peerAddress = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let isTaken = lock.withLock { () -> Bool in
                guard isAllowed(peerAddress), connectionCount < Self.connectionLimit else { return false }
                connectionCount += 1
                return true
            }
            guard isTaken else {
                close(connection)
                continue
            }
            var yes: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var patience = timeval(tv_sec: Self.idleTimeout, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [self] in serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        defer {
            close(connection)
            lock.withLock { connectionCount -= 1 }
        }
        var reader = HTTPReader(descriptor: connection)
        while var request = reader.nextHead() {
            let handler = lock.withLock { handlers.first { request.path == $0.key || request.path.hasPrefix($0.key + "/") }?.value }
            // What is sent is only taken in under a machine's secret: nobody else gets to fill the
            // Mac's disk with it.
            if handler == nil, request.hasBody {
                _ = Self.send(HTTPResponse(status: 404, headers: [("Connection", "close")]), method: request.method, to: connection)
                return
            }
            guard reader.readBody(of: &request) else { return }
            // Windows asks the server's root whether it speaks WebDAV before it looks any further. The
            // root says so, and holds nothing: what is shared is only under a machine's secret.
            var response = (handler ?? WebDAVHandler(locations: [])).handle(request)
            if let body = request.bodyFile {
                try? FileManager.default.removeItem(at: body)
            }
            let closes = request.header("Connection")?.lowercased() == "close"
            response.headers.append(("Connection", closes ? "close" : "keep-alive"))
            guard Self.send(response, method: request.method, to: connection), !closes else { return }
        }
    }

    static func send(_ response: HTTPResponse, method: String, to connection: Int32) -> Bool {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        var headers = response.headers
        if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
            headers.append(("Content-Length", String(response.bodyLength)))
        }
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        guard writeAll(Data(head.utf8), to: connection) else { return false }
        guard method.uppercased() != "HEAD" else { return true }
        switch response.body {
        case .data(let data):
            return data.isEmpty || writeAll(data, to: connection)
        case .file(let url, let offset, let length):
            guard let file = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? file.close() }
            try? file.seek(toOffset: offset)
            var left = length
            while left > 0 {
                guard let piece = try? file.read(upToCount: Int(min(left, 1 << 20))), !piece.isEmpty else { return false }
                guard writeAll(piece, to: connection) else { return false }
                left -= UInt64(piece.count)
            }
            return true
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 206: "Partial Content"
        case 207: "Multi-Status"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Payload Too Large"
        case 416: "Range Not Satisfiable"
        case 507: "Insufficient Storage"
        default: "Error"
        }
    }
}

/// Reads HTTP requests off a connection, one after the other. A body of more than a little goes to a
/// file, so that a guest writing a large file doesn't fill the Mac's memory with it.
struct HTTPReader {
    let descriptor: Int32
    private var buffered = Data()
    /// What a body is kept in memory up to.
    static let inMemoryLimit = 1 << 20
    static let headerLimit = 64 * 1024

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The next request's method, path and headers. Its body comes with ``readBody(of:)``.
    mutating func nextHead() -> HTTPRequest? {
        guard let headerEnd = readUntil(Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: buffered[buffered.startIndex..<headerEnd], as: UTF8.self)
        buffered = Data(buffered[(headerEnd + 4)...])
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(requestLine[1])
        // A client may send the whole address; what counts is its path.
        let path = URLComponents(string: target)?.percentEncodedPath ?? target
        return HTTPRequest(method: String(requestLine[0]), path: path.isEmpty ? "/" : path, headers: headers)
    }

    /// Reads the body that `request`'s head announces. `false` when the connection ended first.
    mutating func readBody(of request: inout HTTPRequest) -> Bool {
        if request.isChunked {
            guard let file = readChunked() else { return false }
            request.bodyFile = file
        } else if let length = request.contentLength, length > 0 {
            if length <= UInt64(Self.inMemoryLimit) {
                guard let body = read(count: Int(length)) else { return false }
                request.body = body
            } else {
                guard let file = readToFile(count: length) else { return false }
                request.bodyFile = file
            }
        }
        return true
    }

    /// Reads until `marker` is in what has arrived, and returns where it starts.
    private mutating func readUntil(_ marker: Data) -> Data.Index? {
        while true {
            if let range = buffered.firstRange(of: marker) { return range.lowerBound }
            guard buffered.count < Self.headerLimit, fill() else { return nil }
        }
    }

    private mutating func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffered.append(contentsOf: chunk[0..<count])
                return true
            }
            if count < 0, errno == EINTR { continue }
            return false
        }
    }

    private mutating func read(count: Int) -> Data? {
        while buffered.count < count {
            guard fill() else { return nil }
        }
        let body = Data(buffered.prefix(count))
        buffered = Data(buffered.dropFirst(count))
        return body
    }

    private static func temporaryFile() -> (URL, FileHandle)? {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else { return nil }
        return (url, handle)
    }

    private mutating func readToFile(count: UInt64) -> URL? {
        guard let (url, handle) = Self.temporaryFile() else { return nil }
        defer { try? handle.close() }
        var left = count
        while left > 0 {
            if buffered.isEmpty, !fill() {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let piece = buffered.prefix(Int(min(left, UInt64(buffered.count))))
            try? handle.write(contentsOf: piece)
            buffered = Data(buffered.dropFirst(piece.count))
            left -= UInt64(piece.count)
        }
        return url
    }

    private mutating func readChunked() -> URL? {
        guard let (url, handle) = Self.temporaryFile() else { return nil }
        var isComplete = false
        defer {
            try? handle.close()
            if !isComplete {
                try? FileManager.default.removeItem(at: url)
            }
        }
        while true {
            guard let lineEnd = readUntil(Data("\r\n".utf8)) else { return nil }
            let sizeText = String(decoding: buffered[buffered.startIndex..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
            buffered = Data(buffered[(lineEnd + 2)...])
            guard let size = UInt64(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            if size == 0 {
                // What may follow the last chunk, up to the empty line.
                _ = readUntil(Data("\r\n".utf8)).map { buffered = Data(buffered[($0 + 2)...]) }
                isComplete = true
                return url
            }
            var left = size
            while left > 0 {
                if buffered.isEmpty, !fill() { return nil }
                let piece = buffered.prefix(Int(min(left, UInt64(buffered.count))))
                try? handle.write(contentsOf: piece)
                buffered = Data(buffered.dropFirst(piece.count))
                left -= UInt64(piece.count)
            }
            guard read(count: 2) != nil else { return nil }
        }
    }
}

extension HTTPRequest {
    var isChunked: Bool {
        header("Transfer-Encoding")?.lowercased().contains("chunked") == true
    }

    var contentLength: UInt64? {
        header("Content-Length").flatMap(UInt64.init)
    }

    /// Whether a body follows the head.
    var hasBody: Bool {
        isChunked || (contentLength ?? 0) > 0
    }
}
