import Foundation
import GuestChannel

/// An engine request to `swiftvm serve` (`qemu-…`): how the app hands a QEMU machine to the service and
/// drives it there. The Rust side is crates/swiftvm-protocol/src/qemu.rs; both read the shared fixture
/// `api-v1/qemu.json`.
public struct QEMURequest: Codable, Sendable, Equatable {
    /// What a descriptor that comes with `qemu-start` is for.
    public enum Descriptor: String, Codable, Sendable {
        case console, network, display
    }

    public struct DirectX: Codable, Sendable, Equatable {
        /// `dxmt`, or `d3dmetal` with `framework`.
        public var backend: String
        public var framework: String?

        public init(backend: String, framework: String? = nil) {
            self.backend = backend
            self.framework = framework
        }
    }

    public struct Image: Codable, Sendable, Equatable {
        public var id: UUID
        public var path: String
        public var readOnly: Bool

        public init(id: UUID, path: String, readOnly: Bool) {
            self.id = id
            self.path = path
            self.readOnly = readOnly
        }
    }

    public struct Size: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var id: Int
    public var command: String
    public var machine: UUID?
    public var bundle: String?
    public var savedState: String?
    public var directX: DirectX?
    public var refreshRate: Int?
    /// The NBD socket that serves each compressed disk, by the disk's identifier.
    public var diskSources: [String: String]?
    public var descriptors: [Descriptor]?
    public var force: Bool?
    public var path: String?
    public var index: Int?
    public var connected: Bool?
    public var image: Image?
    public var imageId: UUID?
    public var port: UInt32?
    public var pointer: GuestPointer?
    public var keys: GuestJob.Keys?
    public var size: Size?

    public init(id: Int = 1, command: String, machine: UUID? = nil) {
        self.id = id
        self.command = command
        self.machine = machine
    }
}

/// What QEMU shows a machine's display with.
public enum QEMUDisplayAdapter: String, Codable, Sendable {
    case framebuffer, virtioGPU, virtioGPU3D
}

/// A machine the service runs on QEMU.
public struct QEMUMachineInfo: Codable, Sendable, Equatable {
    public var machine: UUID
    public var name: String
    public var bundle: String
    public var pid: Int32
    /// `held`, `running`, `paused` or `exited`.
    public var state: String
    public var adapter: QEMUDisplayAdapter
    public var canSaveState: Bool
    public var spiceSocket: String?
}

/// How QEMU ended.
public struct QEMUExit: Codable, Sendable, Equatable {
    /// The reason QEMU gave for the guest going down, such as `guest-shutdown` or `guest-reset`.
    public var reason: String?
    /// The service had been asked to stop it.
    public var expected: Bool
    /// What QEMU said last that tells what went wrong.
    public var message: String?
}

/// A line of the stream that follows `qemu-start` and `qemu-attach`.
public struct QEMUEvent: Codable, Sendable, Equatable {
    public var event: String
    public var machine: UUID
    public var exit: QEMUExit?
}

/// The answer to an engine request.
public struct QEMUAnswer: Codable, Sendable, Equatable {
    public struct Frame: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var bytesPerRow: Int
        public var length: Int
    }

    public var id: Int?
    public var ok: Bool
    public var error: ServiceAnswer.Failure?
    public var qemu: QEMUMachineInfo?
    public var qemuMachines: [QEMUMachineInfo]?
    public var exit: QEMUExit?
    public var frame: Frame?
}

/// One connection to `swiftvm serve`, past its hello, that carries requests in API v1 and, after some of
/// them, a stream. Its calls block: make them away from the main thread.
public final class ServiceConnection: @unchecked Sendable {
    public let descriptor: Int32
    private let lock = NSLock()
    private var isClosed = false

    /// Connects to the service at `socketURL` and says hello.
    public init(socketURL: URL) throws {
        descriptor = try ControlSocket.connect(to: socketURL)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        do {
            let hello = ServiceRequest(id: 0, command: "hello", protocol: ServiceClient.protocolVersion, client: "\(AppIdentity.current.name) app")
            try ControlSocket.writeLine(JSONEncoder().encode(hello), to: descriptor)
            guard let line = ControlSocket.readLine(from: descriptor) else { throw ControlSocketError.connectionClosed }
            let answer = try JSONDecoder().decode(ServiceAnswer.self, from: line)
            guard answer.ok else { throw ServiceClientError.refused(answer.error?.message ?? "The service refused the app.") }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        close()
    }

    /// Sends `request` with copies of `descriptors` riding along, and reads the answer. A failure answer is
    /// thrown.
    @discardableResult
    public func send(_ request: QEMURequest, passing descriptors: [Int32] = []) throws -> QEMUAnswer {
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        try Self.write(line, passing: descriptors, to: descriptor)
        guard let answerLine = ControlSocket.readLine(from: descriptor) else { throw ControlSocketError.connectionClosed }
        guard let answer = try? JSONDecoder().decode(QEMUAnswer.self, from: answerLine) else { throw ControlSocketError.invalidMessage }
        if !answer.ok {
            throw ServiceClientError.failed(code: answer.error?.code ?? "failed", message: answer.error?.message ?? "The service didn't say why.")
        }
        return answer
    }

    /// The next line of a stream, or `nil` at its end.
    public func readLine() -> Data? {
        ControlSocket.readLine(from: descriptor)
    }

    /// Exactly `count` bytes, or `nil` if the stream ends first.
    public func read(count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            while offset < count {
                let read = Darwin.read(descriptor, buffer.baseAddress! + offset, count - offset)
                if read > 0 {
                    offset += read
                } else if read < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return complete ? data : nil
    }

    /// Ends a read that is waiting, from another thread. The descriptor stays this connection's.
    public func shutdown() {
        lock.withLock {
            if !isClosed { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    /// Hands the descriptor over to whoever keeps it from now on: this no longer closes it.
    public func detach() -> Int32 {
        lock.withLock { isClosed = true }
        return descriptor
    }

    public func close() {
        let shouldClose = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        if shouldClose { Darwin.close(descriptor) }
    }

    /// Writes all of `bytes`, with `descriptors` riding along with the first of them (`SCM_RIGHTS`).
    static func write(_ bytes: Data, passing descriptors: [Int32], to socket: Int32) throws {
        var rest = bytes[...]
        if !descriptors.isEmpty {
            let headerLength = MemoryLayout<cmsghdr>.size
            let dataLength = descriptors.count * MemoryLayout<Int32>.size
            let controlLength = headerLength + dataLength
            let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
            defer { control.deallocate() }
            control.initializeMemory(as: UInt8.self, repeating: 0, count: controlLength)
            let header = control.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len = socklen_t(controlLength)
            header.pointee.cmsg_level = SOL_SOCKET
            header.pointee.cmsg_type = SCM_RIGHTS
            for (index, descriptor) in descriptors.enumerated() {
                (control + headerLength + index * MemoryLayout<Int32>.size).storeBytes(of: descriptor, as: Int32.self)
            }
            let sent = rest.withUnsafeBytes { buffer in
                var vector = iovec(iov_base: UnsafeMutableRawPointer(mutating: buffer.baseAddress), iov_len: buffer.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr(
                        msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1, msg_control: control,
                        msg_controllen: socklen_t(controlLength), msg_flags: 0
                    )
                    return sendmsg(socket, &message, 0)
                }
            }
            guard sent > 0 else { throw ControlSocketError.system("sendmsg", errno) }
            rest = rest.dropFirst(sent)
        }
        guard rest.isEmpty || ByteRelay.writeAll(ArraySlice(rest), to: socket) else { throw ControlSocketError.connectionClosed }
    }
}
