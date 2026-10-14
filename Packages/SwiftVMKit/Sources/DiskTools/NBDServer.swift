import Foundation

/// Hands a compressed disk to the Virtualization framework.
///
/// The framework takes a disk image in a format of its own, or a network block device: a server that
/// answers its reads and writes. That is the only way a disk can be the app's own. The server listens on
/// a socket that only this user can open, and what comes in over it is a guest's doing: every request is
/// checked before it reaches the disk.
public final class NBDServer: @unchecked Sendable {
    public enum ServerError: Error, LocalizedError {
        case socket(String)

        public var errorDescription: String? {
            switch self {
            case .socket(let reason): "The disk couldn't be made available to the virtual machine: \(reason)"
            }
        }
    }

    /// What the framework is given to connect to.
    public let url: URL

    private let disk: CompressedDisk
    private let socketPath: String
    private let listener: Int32
    /// A pipe that is written to when it is over, for the thread that waits for the machine to connect.
    private let wake: (read: Int32, write: Int32)
    private let work = DispatchQueue(label: "app.swiftvm.nbd", attributes: .concurrent)
    private let lock = NSLock()
    private var connections: Set<Int32> = []
    private var isStopped = false
    /// The threads that accept and serve, and every request that is being answered.
    private let busy = DispatchGroup()

    /// The largest read or write that is answered. The framework's client asks for 8 MiB at most.
    private static let largestRequest = 32 << 20

    private enum Command {
        static let read: UInt16 = 0
        static let write: UInt16 = 1
        static let disconnect: UInt16 = 2
        static let flush: UInt16 = 3
        static let trim: UInt16 = 4
        static let writeZeroes: UInt16 = 6
    }

    private enum Failure {
        static let notPermitted: UInt32 = 1
        static let io: UInt32 = 5
        static let invalid: UInt32 = 22
        static let noSpace: UInt32 = 28
    }

    private struct Buffer: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let count: Int

        init(count: Int) {
            pointer = .allocate(byteCount: max(count, 1), alignment: 16384)
            self.count = count
        }
    }

    public init(disk: CompressedDisk) throws {
        self.disk = disk
        // A socket's path has room for 103 bytes. The folder for temporary files is the user's own,
        // and its path is short enough.
        let path = FileManager.default.temporaryDirectory.appending(path: "swiftvm-\(UUID().uuidString.prefix(8)).sock").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw ServerError.socket("the path of its socket is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }

        // Kept in a variable of its own until everything is set: a closure can't use `self` before.
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.socket(String(cString: strerror(errno))) }
        // Set here, for every connection to take over: on one whose other end has hung up already it
        // can't be set any more, and the first word written to it would end the app.
        var quiet: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            unlink(path)
            throw ServerError.socket(reason)
        }
        var components = URLComponents()
        components.scheme = "nbd+unix"
        components.host = ""
        components.path = "/disk"
        components.queryItems = [URLQueryItem(name: "socket", value: path)]
        guard let url = components.url else {
            close(descriptor)
            unlink(path)
            throw ServerError.socket("its address couldn't be written down.")
        }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            unlink(path)
            throw ServerError.socket(reason)
        }
        // So that a machine that hangs up between knocking and being let in doesn't hold the thread.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        socketPath = path
        listener = descriptor
        wake = (ends[0], ends[1])
        self.url = url
    }

    public func start() {
        busy.enter()
        Thread.detachNewThread { [self] in
            defer { busy.leave() }
            while true {
                var waiting = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0)]
                if poll(&waiting, 2, -1) < 0, errno != EINTR { return }
                if waiting[1].revents != 0 { return }
                guard waiting[0].revents != 0 else { continue }
                let descriptor = accept(listener, nil, nil)
                if descriptor < 0 {
                    // Out of descriptors, for one: that passes, and the machine tries again by itself.
                    if errno != EINTR, errno != EAGAIN, errno != ECONNABORTED { usleep(100_000) }
                    continue
                }
                // What is let in would otherwise not wait for what it reads either.
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
                var yes: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                // The system's 8 KiB would make every megabyte a hundred trips.
                var size: Int32 = 4 << 20
                setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                let accepted = lock.withLock {
                    if isStopped { return false }
                    connections.insert(descriptor)
                    return true
                }
                guard accepted else {
                    close(descriptor)
                    return
                }
                busy.enter()
                Thread.detachNewThread { [self] in
                    serve(descriptor)
                    lock.withLock { _ = connections.remove(descriptor) }
                    close(descriptor)
                    busy.leave()
                }
            }
        }
    }

    /// Stops listening and hangs up. Returns once no request is being answered any more, so that the
    /// disk can be closed.
    public func stop() {
        let wasStopped = lock.withLock {
            let wasStopped = isStopped
            isStopped = true
            // With the lock held: a connection is taken off this list before it is closed, so none of
            // these numbers stands for something else by now.
            if !wasStopped { for descriptor in connections { shutdown(descriptor, SHUT_RDWR) } }
            return wasStopped
        }
        guard !wasStopped else { return }
        var byte: UInt8 = 0
        _ = write(wake.write, &byte, 1)
        busy.wait()
        close(listener)
        close(wake.read)
        close(wake.write)
        unlink(socketPath)
    }

    // MARK: Wire

    private func receive(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let got = read(descriptor, buffer + done, count - done)
            if got < 0 {
                if errno == EINTR { continue }
                return false
            }
            if got == 0 { return false }
            done += got
        }
        return true
    }

    private func receive(_ descriptor: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard count == 0 || bytes.withUnsafeMutableBytes({ receive(descriptor, $0.baseAddress!, count) }) else { return nil }
        return bytes
    }

    @discardableResult
    private func send(_ descriptor: Int32, _ head: [UInt8], _ payload: Buffer? = nil) -> Bool {
        head.withUnsafeBytes { raw in
            var vectors = [iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress), iov_len: raw.count)]
            if let payload, payload.count > 0 { vectors.append(iovec(iov_base: payload.pointer, iov_len: payload.count)) }
            var first = 0
            while first < vectors.count {
                let put = vectors.withUnsafeMutableBufferPointer { writev(descriptor, $0.baseAddress! + first, Int32($0.count - first)) }
                if put < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                var left = put
                while first < vectors.count, left >= vectors[first].iov_len {
                    left -= vectors[first].iov_len
                    first += 1
                }
                if first < vectors.count, left > 0 {
                    vectors[first].iov_base = vectors[first].iov_base.map { $0 + left }
                    vectors[first].iov_len -= left
                }
            }
            return true
        }
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private static func integer<T: FixedWidthInteger>(_ bytes: ArraySlice<UInt8>, as type: T.Type) -> T {
        bytes.reduce(T(0)) { $0 << 8 | T($1) }
    }

    // MARK: Handshake

    private var transmissionFlags: UInt16 {
        // Has flags, takes flushes, trims and requests to write zeros.
        1 << 0 | 1 << 2 | 1 << 5 | 1 << 6 | (disk.isReadOnly ? 1 << 1 : 0)
    }

    /// Agrees with the client on what is served. `false` when it hung up or asked for nothing.
    private func handshake(_ descriptor: Int32) -> Bool {
        let optionMagic: UInt64 = 0x4948_4156_454F_5054
        // "NBDMAGIC", "IHAVEOPT", and that this server speaks the newer handshake without its padding.
        guard send(descriptor, Self.bytes(UInt64(0x4E42_444D_4147_4943)) + Self.bytes(optionMagic) + Self.bytes(UInt16(3))),
              let flags = receive(descriptor, count: 4)
        else { return false }
        let skipsPadding = flags[3] & 2 != 0

        func reply(_ option: UInt32, _ type: UInt32, _ data: [UInt8] = []) -> Bool {
            send(descriptor, Self.bytes(UInt64(0x0003_E889_0455_65A9)) + Self.bytes(option) + Self.bytes(type) + Self.bytes(UInt32(data.count)) + data)
        }
        let acknowledged: UInt32 = 1, information: UInt32 = 3, unsupported: UInt32 = 0x8000_0001

        while true {
            guard let head = receive(descriptor, count: 16), Self.integer(head[0..<8], as: UInt64.self) == optionMagic else { return false }
            let option = Self.integer(head[8..<12], as: UInt32.self)
            let length = Int(Self.integer(head[12..<16], as: UInt32.self))
            guard length <= 4096, let data = receive(descriptor, count: length) else { return false }

            switch option {
            case 1:  // The older way to ask for the disk: answered with its size alone.
                var answer = Self.bytes(disk.capacity) + Self.bytes(transmissionFlags)
                if !skipsPadding { answer += [UInt8](repeating: 0, count: 124) }
                return send(descriptor, answer)
            case 2:  // Never mind.
                _ = reply(option, acknowledged)
                return false
            case 6, 7:  // What is the disk like, and: let's go.
                var wantsBlockSize = false
                if data.count >= 6 {
                    var cursor = 4 + Int(Self.integer(data[0..<4], as: UInt32.self))
                    if cursor + 2 <= data.count {
                        let count = Int(Self.integer(data[cursor..<(cursor + 2)], as: UInt16.self))
                        cursor += 2
                        for _ in 0..<count where cursor + 2 <= data.count {
                            if Self.integer(data[cursor..<(cursor + 2)], as: UInt16.self) == 3 { wantsBlockSize = true }
                            cursor += 2
                        }
                    }
                }
                guard reply(option, information, Self.bytes(UInt16(0)) + Self.bytes(disk.capacity) + Self.bytes(transmissionFlags)) else { return false }
                if wantsBlockSize {
                    let sizes = Self.bytes(UInt16(3)) + Self.bytes(UInt32(512)) + Self.bytes(UInt32(4096)) + Self.bytes(UInt32(Self.largestRequest))
                    guard reply(option, information, sizes) else { return false }
                }
                guard reply(option, acknowledged) else { return false }
                if option == 7 { return true }
            default:
                guard reply(option, unsupported) else { return false }
            }
        }
    }

    // MARK: Requests

    private func serve(_ descriptor: Int32) {
        guard handshake(descriptor) else { return }
        let replies = NSLock()
        // Requests that are being answered on this connection, which is closed only after them.
        let pending = DispatchGroup()
        defer { pending.wait() }
        let slots = DispatchSemaphore(value: 64)

        @Sendable func answer(_ cookie: UInt64, _ error: UInt32, _ payload: Buffer? = nil) {
            replies.withLock {
                _ = send(descriptor, Self.bytes(UInt32(0x6744_6698)) + Self.bytes(error) + Self.bytes(cookie), error == 0 ? payload : nil)
            }
        }

        @Sendable func code(_ error: any Error) -> UInt32 {
            switch error {
            case CompressedDisk.DiskError.io(ENOSPC): Failure.noSpace
            case CompressedDisk.DiskError.outOfRange: Failure.invalid
            case CompressedDisk.DiskError.readOnly: Failure.notPermitted
            default: Failure.io
            }
        }

        func perform(_ cookie: UInt64, _ operation: @escaping @Sendable () throws -> Buffer?) {
            slots.wait()
            pending.enter()
            busy.enter()
            work.async { [busy] in
                do {
                    let payload = try operation()
                    answer(cookie, 0, payload)
                    payload?.pointer.deallocate()
                } catch {
                    answer(cookie, code(error))
                }
                slots.signal()
                pending.leave()
                busy.leave()
            }
        }

        while let head = receive(descriptor, count: 28) {
            guard Self.integer(head[0..<4], as: UInt32.self) == 0x2560_9513 else { return }
            let command = Self.integer(head[6..<8], as: UInt16.self)
            let cookie = Self.integer(head[8..<16], as: UInt64.self)
            let offset = Self.integer(head[16..<24], as: UInt64.self)
            let length = Int(Self.integer(head[24..<28], as: UInt32.self))
            let disk = disk

            switch command {
            case Command.disconnect:
                return
            case Command.read:
                guard length <= Self.largestRequest else {
                    answer(cookie, Failure.invalid)
                    continue
                }
                perform(cookie) {
                    let buffer = Buffer(count: length)
                    do {
                        try disk.read(at: offset, into: UnsafeMutableRawBufferPointer(start: buffer.pointer, count: length))
                    } catch {
                        buffer.pointer.deallocate()
                        throw error
                    }
                    return buffer
                }
            case Command.write:
                // What follows on the line is the data, which can't be told from the next request
                // without reading it: a write that is too large ends the conversation.
                guard length <= Self.largestRequest else { return }
                let buffer = Buffer(count: length)
                guard receive(descriptor, buffer.pointer, length) else {
                    buffer.pointer.deallocate()
                    return
                }
                perform(cookie) {
                    defer { buffer.pointer.deallocate() }
                    try disk.write(at: offset, from: UnsafeRawBufferPointer(start: buffer.pointer, count: length))
                    return nil
                }
            case Command.flush:
                perform(cookie) {
                    // A disk that is only read has nothing waiting to be written.
                    if !disk.isReadOnly { try disk.flush() }
                    return nil
                }
            case Command.trim:
                perform(cookie) {
                    try disk.discard(at: offset, length: UInt64(length))
                    return nil
                }
            case Command.writeZeroes:
                perform(cookie) {
                    try disk.zero(at: offset, length: UInt64(length))
                    return nil
                }
            default:
                answer(cookie, Failure.invalid)
            }
        }
    }
}

/// A compressed disk that a virtual machine has, from when the machine is put together until it is gone.
public final class CompressedDiskExport: Sendable {
    /// What the Virtualization framework connects to.
    public var url: URL { server.url }

    private let disk: CompressedDisk
    private let server: NBDServer

    public init(diskAt url: URL, readOnly: Bool) throws {
        disk = try CompressedDisk(url: url, readOnly: readOnly)
        do {
            server = try NBDServer(disk: disk)
        } catch {
            try? disk.close()
            throw error
        }
        server.start()
    }

    /// Hangs up on the machine and closes the disk, with everything that was written to it in the file.
    public func close() throws {
        server.stop()
        try disk.close()
    }
}
