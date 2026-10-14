import Foundation
import GuestChannel

/// A value in QEMU's machine protocol, which is JSON.
public enum QMPValue: Sendable, Hashable, Codable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([QMPValue])
    case object([String: QMPValue])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, QMPValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
    public init(arrayLiteral elements: QMPValue...) { self = .array(elements) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([QMPValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: QMPValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go as such: QEMU reads `1.0` as no integer.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> QMPValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var array: [QMPValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

/// Something QEMU says unasked: that the guest shut down, that a device is gone.
public struct QMPEvent: Sendable, Hashable {
    public var name: String
    public var data: QMPValue

    public init(name: String, data: QMPValue = .object([:])) {
        self.name = name
        self.data = data
    }
}

/// The line to a running QEMU over its machine protocol (QMP): commands and their answers, one JSON
/// object a line each, and the events QEMU sends of its own accord in between.
///
/// The line is a socket the app made before QEMU started and handed it, so nothing on disk leads to it.
/// It reads on a thread of its own. Answers find the command they belong to by its `id`.
public final class QMPConnection: @unchecked Sendable {
    /// Called on the connection's own thread with every event, in the order QEMU sent them.
    public var onEvent: (@Sendable (QMPEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    /// Called once on the connection's own thread when QEMU has hung up: it has stopped.
    public var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { closeHandler } }
        set { lock.withLock { closeHandler = newValue } }
    }

    private let descriptor: Int32
    private let lock = NSLock()
    private var eventHandler: (@Sendable (QMPEvent) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var pending: [Int: CheckedContinuation<QMPValue, any Error>] = [:]
    private var nextID = 1
    private var isClosed = false
    /// Who waits for QEMU's greeting, which comes first, before any command can be sent.
    private var greeting: CheckedContinuation<Void, any Error>?
    private var hasGreeted = false

    /// Takes over `descriptor`, a connected socket whose other end QEMU has as its monitor.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    }

    deinit {
        close()
    }

    /// Starts reading, waits for QEMU's greeting, and switches the line into command mode. QEMU only
    /// greets once its machine is put together, so this returns when QEMU is ready to be told what to do.
    public func open() async throws {
        let thread = Thread { [self] in readLoop() }
        thread.name = "app.swiftvm.qmp"
        thread.start()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let ready = lock.withLock { () -> Bool? in
                if isClosed { return nil }
                if hasGreeted { return true }
                greeting = continuation
                return false
            }
            switch ready {
            case nil: continuation.resume(throwing: QEMUError.disconnected)
            case true?: continuation.resume()
            case false?: break
            }
        }
        _ = try await execute("qmp_capabilities")
    }

    /// Runs `command` and returns what it returned.
    ///
    /// - Parameter descriptor: A file descriptor that goes along with the command, for one such as
    ///   `getfd` that takes one. QEMU gets its own copy; the caller keeps theirs.
    @discardableResult
    public func execute(_ command: String, _ arguments: [String: QMPValue]? = nil, passing descriptor: Int32? = nil) async throws -> QMPValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QMPValue, any Error>) in
            let id: Int? = lock.withLock {
                guard !isClosed else { return nil }
                let id = nextID
                nextID += 1
                pending[id] = continuation
                return id
            }
            guard let id else {
                continuation.resume(throwing: QEMUError.disconnected)
                return
            }
            var message: [String: QMPValue] = ["execute": .string(command), "id": .number(Double(id))]
            if let arguments {
                message["arguments"] = .object(arguments)
            }
            var line = (try? JSONEncoder().encode(QMPValue.object(message))) ?? Data()
            line.append(UInt8(ascii: "\n"))
            // Not once it is closed: the reading thread closes the descriptor after that.
            let isSent = lock.withLock { !isClosed && send(line, passing: descriptor) }
            if !isSent {
                let waiting = lock.withLock { pending.removeValue(forKey: id) }
                waiting?.resume(throwing: QEMUError.disconnected)
            }
        }
    }

    /// Hangs up. Whatever is still waiting for an answer is told that none will come.
    public func close() {
        let (waiting, greeted) = lock.withLock { () -> ([CheckedContinuation<QMPValue, any Error>], CheckedContinuation<Void, any Error>?) in
            guard !isClosed else { return ([], nil) }
            isClosed = true
            let waiting = Array(pending.values)
            pending = [:]
            let greeted = greeting
            greeting = nil
            // Wakes the reading thread, which closes the descriptor once it is out of its read.
            shutdown(descriptor, SHUT_RDWR)
            return (waiting, greeted)
        }
        for continuation in waiting {
            continuation.resume(throwing: QEMUError.disconnected)
        }
        greeted?.resume(throwing: QEMUError.disconnected)
    }

    // MARK: Writing

    /// Writes all of `bytes`, with `descriptor` as an attachment to the first of them. Called with the
    /// lock held, so that two commands never interleave.
    private func send(_ bytes: Data, passing attachment: Int32?) -> Bool {
        var rest = bytes[...]
        if let attachment {
            let sent = Self.send(rest, with: attachment, over: descriptor)
            guard sent > 0 else { return false }
            rest = rest.dropFirst(sent)
        }
        return rest.isEmpty || ByteRelay.writeAll(ArraySlice(rest), to: descriptor)
    }

    /// Sends what of `bytes` fits in one go, with a copy of `attachment` riding along (`SCM_RIGHTS`).
    /// Returns how many bytes went, or -1.
    static func send(_ bytes: Data.SubSequence, with attachment: Int32, over descriptor: Int32) -> Int {
        // The header, then the descriptor right after it: four bytes in, on a four-byte boundary.
        let headerLength = MemoryLayout<cmsghdr>.size
        let controlLength = headerLength + MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlLength)
        let header = control.assumingMemoryBound(to: cmsghdr.self)
        header.pointee.cmsg_len = socklen_t(controlLength)
        header.pointee.cmsg_level = SOL_SOCKET
        header.pointee.cmsg_type = SCM_RIGHTS
        (control + headerLength).storeBytes(of: attachment, as: Int32.self)
        return bytes.withUnsafeBytes { buffer in
            var vector = iovec(iov_base: UnsafeMutableRawPointer(mutating: buffer.baseAddress), iov_len: buffer.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr(
                    msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1, msg_control: control,
                    msg_controllen: socklen_t(controlLength), msg_flags: 0
                )
                return sendmsg(descriptor, &message, 0)
            }
        }
    }

    // MARK: Reading

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pendingBytes = Data()
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pendingBytes.append(contentsOf: buffer[0..<count])
            while let lineBreak = pendingBytes.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pendingBytes[pendingBytes.startIndex..<lineBreak]
                pendingBytes = Data(pendingBytes[pendingBytes.index(after: lineBreak)...])
                handle(line: Data(line))
            }
        }
        close()
        Darwin.close(descriptor)
        let handler = lock.withLock { closeHandler }
        handler?()
    }

    private func handle(line: Data) {
        guard let message = try? JSONDecoder().decode(QMPValue.self, from: line) else { return }
        if message["QMP"] != nil {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                hasGreeted = true
                defer { greeting = nil }
                return greeting
            }
            waiting?.resume()
        } else if let name = message["event"]?.string {
            let handler = lock.withLock { eventHandler }
            handler?(QMPEvent(name: name, data: message["data"] ?? .object([:])))
        } else if let id = message["id"]?.int {
            guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: QEMUError.refused(error["desc"]?.string ?? "QEMU didn't say why."))
            } else {
                continuation.resume(returning: message["return"] ?? .null)
            }
        }
    }
}
