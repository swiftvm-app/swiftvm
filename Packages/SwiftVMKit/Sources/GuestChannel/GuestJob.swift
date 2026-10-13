import Foundation

/// Something the agent does in the guest for whoever drives it from the Mac: run a command, show what is
/// on the screen, use the mouse and the keyboard, or say what is on the screen as a tree of its parts.
///
/// A job has a connection of its own, on ``GuestProtocol/jobPort``. Unlike the line the app keeps open to
/// the agent, it carries megabytes and lasts for as long as a command runs, and many are open at once.
/// The app connects and sends the job as one line of JSON. The agent answers with one line, a
/// ``GuestJobAnswer``. After a yes, the rest of the connection is ``JobFrame``s, up to the agent's
/// ``JobFrame/Kind/end``. Whoever asked hangs up to call a job off.
///
/// The agent ends a job by saying it has no more to send and then waiting for the other side to hang
/// up, rather than hanging up itself. A line that is torn down from the agent's end while input is
/// still arriving could lose the frame that says how the job ended.
public enum GuestJob: Sendable, Hashable {
    /// Run a command. Its input and output travel as frames, and its exit status ends the job.
    case exec(Exec)
    /// What is on the screen, as a PNG.
    case screenshot
    case pointer(Pointer)
    case keys(Keys)
    /// What is on the screen as a tree of its parts, in JSON, as the system's accessibility tells it.
    case tree(Tree)
    case element(Element)
    /// Whether the guest's system lets the agent read the screen as a tree, and what leads there.
    case permission(Permission)
    /// A kind of job this build doesn't know.
    case unknown(type: String)

    public struct Exec: Codable, Sendable, Hashable {
        /// The command and its arguments. No shell reads them.
        public var arguments: [String]
        /// The account to run it as, `root` for one. Without one, whoever is logged in at the screen.
        public var user: String?
        /// Where to run it. Without one, the account's home folder.
        public var directory: String?
        /// Variables to add to the command's environment.
        public var environment: [String: String]?

        public init(arguments: [String], user: String? = nil, directory: String? = nil, environment: [String: String]? = nil) {
            self.arguments = arguments
            self.user = user
            self.directory = directory
            self.environment = environment
        }
    }

    /// Something done with the mouse. Places are in the pixels of a screenshot, from its top left corner.
    public struct Pointer: Codable, Sendable, Hashable {
        public enum Action: String, Codable, Sendable, Hashable, CaseIterable {
            case move, click, drag, scroll
        }

        public enum Button: String, Codable, Sendable, Hashable, CaseIterable {
            case left, right, middle
        }

        public var action: Action
        public var x: Int
        public var y: Int
        /// The button to click or drag with. Without one, the left.
        public var button: Button?
        /// For a click: how many, two for a double click.
        public var count: Int?
        /// For a drag: where it ends.
        public var toX: Int?
        public var toY: Int?
        /// For scrolling: notches of the wheel. Positive is down, and to the right.
        public var deltaX: Int?
        public var deltaY: Int?

        public init(
            action: Action, x: Int, y: Int, button: Button? = nil, count: Int? = nil, toX: Int? = nil, toY: Int? = nil,
            deltaX: Int? = nil, deltaY: Int? = nil
        ) {
            self.action = action
            self.x = x
            self.y = y
            self.button = button
            self.count = count
            self.toX = toX
            self.toY = toY
            self.deltaX = deltaX
            self.deltaY = deltaY
        }
    }

    /// Something done with the keyboard: text to type, or keys to press.
    public struct Keys: Codable, Sendable, Hashable {
        /// Text to type as it is.
        public var text: String?
        /// Keys to press one after the other. Each is one key or several held together, joined by a
        /// plus sign: `Return`, `ctrl+c`, `cmd+shift+4`.
        public var keys: [String]?

        public init(text: String? = nil, keys: [String]? = nil) {
            self.text = text
            self.keys = keys
        }
    }

    public struct Tree: Codable, Sendable, Hashable {
        /// Only the applications with this in their name. Without it, every one that has a window.
        public var application: String?
        /// How many levels down to go. Without one, as far as the agent goes by itself.
        public var depth: Int?
        /// Leave nothing out. Without this, the boxes that only hold other parts are left out, and of
        /// a part's actions those that every part of its window has.
        public var all: Bool?

        public init(application: String? = nil, depth: Int? = nil, all: Bool? = nil) {
            self.application = application
            self.depth = depth
            self.all = all
        }
    }

    /// Something done to one part of the tree, named by the `id` it has there.
    public struct Element: Codable, Sendable, Hashable {
        public enum Action: String, Codable, Sendable, Hashable, CaseIterable {
            /// What a click on it would do.
            case press
            /// Replace its text with ``Element/text``.
            case set
            case focus
        }

        public var action: Action
        public var element: String
        public var text: String?
        /// For a press: the one of the part's actions to do, by the name the tree gives it. Without
        /// one, what a click would do.
        public var actionName: String?

        public init(action: Action, element: String, text: String? = nil, actionName: String? = nil) {
            self.action = action
            self.element = element
            self.text = text
            self.actionName = actionName
        }
    }

    /// macOS asks whoever sits at the screen before a program may read what others show there and act
    /// on it, in its settings and for a password. The app answers for them, with the machine's own
    /// mouse and keyboard. The agent can't see the screen before it is let, but it knows where the
    /// windows are, and says so in a ``GuestPermissionState``.
    public struct Permission: Codable, Sendable, Hashable {
        public enum Action: String, Codable, Sendable, Hashable, CaseIterable {
            /// Say how things stand.
            case check
            /// Ask the system, and open its settings where the answer is given.
            case ask
            /// Put away what asking opened.
            case finish
        }

        public var action: Action

        public init(action: Action) {
            self.action = action
        }
    }

    /// The ``GuestFeature`` an agent has to offer to be given this job.
    public var feature: String? {
        switch self {
        case .exec: GuestFeature.exec
        case .screenshot: GuestFeature.screen
        case .pointer, .keys: GuestFeature.input
        case .tree, .element: GuestFeature.accessibility
        case .permission: GuestFeature.permission
        case .unknown: nil
        }
    }
}

/// What an agent puts out for a ``GuestJob/permission(_:)``, in JSON: how things stand, and where on
/// the screen the answer is given. Places are in the pixels of a screenshot: left, top, width, height.
public struct GuestPermissionState: Codable, Sendable, Hashable {
    /// The system lets the agent read the screen as a tree and act on its parts.
    public var isAllowed: Bool
    /// How many pixels of a screenshot make one of the points the system lays its windows out in.
    public var scale: Double
    /// The window of the system's settings, if it is on the screen.
    public var settings: [Int]?
    /// What the settings have put in front of their window: the question for the password.
    public var sheet: [Int]?

    public init(isAllowed: Bool, scale: Double = 1, settings: [Int]? = nil, sheet: [Int]? = nil) {
        self.isAllowed = isAllowed
        self.scale = scale
        self.settings = settings
        self.sheet = sheet
    }
}

/// The agent's answer to a job: whether it takes it on. What goes wrong after a yes comes with the
/// frame that ends the job.
public struct GuestJobAnswer: Codable, Sendable, Hashable {
    public var ok: Bool
    /// Why not, in the agent's words.
    public var error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }

    public static func refusal(_ error: String) -> GuestJobAnswer {
        GuestJobAnswer(ok: false, error: error)
    }
}

/// How a job ended, as the payload of its last frame.
public struct JobEnd: Codable, Sendable, Hashable {
    /// The exit status of a command that ran to its end, and zero for any other job that worked out.
    public var status: Int32?
    /// The signal that ended a command.
    public var signal: Int32?
    /// What went wrong, in the agent's words.
    public var error: String?

    public init(status: Int32? = nil, signal: Int32? = nil, error: String? = nil) {
        self.status = status
        self.signal = signal
        self.error = error
    }

    public static let success = JobEnd(status: 0)

    /// ``error`` made fit to show on this Mac: one line of no more than a few hundred characters,
    /// whatever the guest sent.
    public var shownError: String? {
        guard let error else { return nil }
        let line = ShownText.line(error, limit: 500)
        return line.isEmpty ? "The guest tools gave up, without saying why." : line
    }

    public static func failure(_ error: String, status: Int32? = nil) -> JobEnd {
        JobEnd(status: status, error: error)
    }
}

// MARK: - Coding

extension GuestJob: Codable {
    private enum TypeKey: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "exec": self = .exec(try Exec(from: decoder))
        case "screenshot": self = .screenshot
        case "pointer": self = .pointer(try Pointer(from: decoder))
        case "keys": self = .keys(try Keys(from: decoder))
        case "tree": self = .tree(try Tree(from: decoder))
        case "element": self = .element(try Element(from: decoder))
        case "permission": self = .permission(try Permission(from: decoder))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .exec(let exec):
            try container.encode("exec", forKey: .type)
            try exec.encode(to: encoder)
        case .screenshot:
            try container.encode("screenshot", forKey: .type)
        case .pointer(let pointer):
            try container.encode("pointer", forKey: .type)
            try pointer.encode(to: encoder)
        case .keys(let keys):
            try container.encode("keys", forKey: .type)
            try keys.encode(to: encoder)
        case .tree(let tree):
            try container.encode("tree", forKey: .type)
            try tree.encode(to: encoder)
        case .element(let element):
            try container.encode("element", forKey: .type)
            try element.encode(to: encoder)
        case .permission(let permission):
            try container.encode("permission", forKey: .type)
            try permission.encode(to: encoder)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

// MARK: - Frames

/// One piece of what a job carries once the agent has said yes: a kind, a length, and that many bytes.
///
/// On the connection a frame is one byte for its kind, four for the length of what follows, most
/// significant first, and then the bytes themselves.
public struct JobFrame: Sendable, Hashable {
    public enum Kind: UInt8, Sendable, Hashable {
        /// From the Mac: bytes for the command's input. An empty one says there is no more to come.
        case input = 0
        /// From the agent: what the command printed, or what the job is for: the picture, the tree.
        case output = 1
        /// From the agent: what the command printed as errors.
        case errorOutput = 2
        /// From the agent, last: a ``JobEnd`` in JSON.
        case end = 3
    }

    public var kind: Kind
    public var payload: Data

    public init(_ kind: Kind, _ payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }

    /// No frame is sent with more in it than this. What is longer goes in several.
    public static let maximumPayloadLength = 64 * 1024
    /// A frame that claims to be longer than this isn't one, and the connection is of no further use.
    static let longestAcceptedPayload = 1024 * 1024

    public struct Malformed: Error {}

    /// The frame that ends a job.
    public static func end(_ end: JobEnd) -> JobFrame {
        JobFrame(.end, (try? JSONEncoder().encode(end)) ?? Data("{}".utf8))
    }

    /// What an ``Kind/end`` frame says. A frame that can't be read says that much.
    public var end: JobEnd? {
        guard kind == .end else { return nil }
        return (try? JSONDecoder().decode(JobEnd.self, from: payload)) ?? .failure("The guest ended the job without saying how.")
    }

    /// The frame as it travels.
    public var encoded: Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Writes `payload` as frames of `kind`, as many as it takes, and at least one. Returns `false`
    /// when the connection failed. Whoever shares a connection between threads takes turns at this.
    @discardableResult
    public static func write(_ kind: Kind, _ payload: Data = Data(), to descriptor: Int32) -> Bool {
        var rest = payload[...]
        repeat {
            let piece = rest.prefix(maximumPayloadLength)
            rest = rest.dropFirst(piece.count)
            guard ByteRelay.writeAll(ArraySlice(JobFrame(kind, Data(piece)).encoded), to: descriptor) else { return false }
        } while !rest.isEmpty
        return true
    }

    public struct TimedOut: Error {}

    /// Reads the next frame. Returns `nil` when the other side has hung up between two frames, and
    /// throws when it did so inside one or sent something that isn't a frame. Frames of a kind this
    /// build doesn't know are passed over. When given, `timeout` covers the whole frame and any passed
    /// over before it, not just the wait for its first byte.
    public static func read(from descriptor: Int32, timeout: TimeInterval? = nil) throws -> JobFrame? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            guard let header = try readExactly(5, from: descriptor, allowingEnd: true, deadline: deadline) else { return nil }
            let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
            guard length <= longestAcceptedPayload else { throw Malformed() }
            guard let payload = try readExactly(length, from: descriptor, allowingEnd: false, deadline: deadline) else { throw Malformed() }
            if let kind = Kind(rawValue: header[header.startIndex]) {
                return JobFrame(kind, payload)
            }
        }
    }

    private static func readExactly(_ count: Int, from descriptor: Int32, allowingEnd: Bool, deadline: Date?) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw TimedOut() }
                var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&waiting, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
                if ready < 0, errno != EINTR { throw Malformed() }
                guard ready > 0 else { continue }
            }
            let received = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, count - offset) }
            if received > 0 {
                offset += received
            } else if received == 0 {
                if offset == 0, allowingEnd { return nil }
                throw Malformed()
            } else if errno != EINTR {
                throw Malformed()
            }
        }
        return data
    }
}

// MARK: - Opening a job

/// The first two lines of a job's connection: the job, and the agent's answer to it.
public enum GuestJobLine {
    /// Sends `job` on a connection to the agent's job port and waits for the answer. Returns `nil` when
    /// none came in time, or the connection broke first. Call it where waiting is no harm.
    public static func open(_ job: GuestJob, over descriptor: Int32, timeout: TimeInterval = 15) -> GuestJobAnswer? {
        guard ByteRelay.writeAll(ArraySlice(GuestMessageCoding.line(for: job)), to: descriptor),
              let line = read(from: descriptor, timeout: timeout)
        else { return nil }
        return GuestMessageCoding.message(GuestJobAnswer.self, from: line)
    }

    /// Reads up to the next line break, and not a byte further: what follows a job's first lines is
    /// frames, for someone else to read. Returns the line without its break, or `nil` when it didn't
    /// come in time, the other side hung up, or it grew longer than a line may be.
    public static func read(from descriptor: Int32, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var line = Data()
        var byte: UInt8 = 0
        while line.count < GuestProtocol.maximumLineLength {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready < 0, errno != EINTR { return nil }
            // Nothing yet, or a signal: the time that is left says whether to go on waiting.
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") { return line }
                line.append(byte)
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                return nil
            }
        }
        return nil
    }

    /// Writes the agent's answer to a job.
    @discardableResult
    public static func answer(_ answer: GuestJobAnswer, on descriptor: Int32) -> Bool {
        ByteRelay.writeAll(ArraySlice(GuestMessageCoding.line(for: answer)), to: descriptor)
    }

    /// Ends a job's connection from the agent's side, and closes `descriptor`: says that no more is
    /// coming, and then listens until the other side has hung up too, for `patience` at most. What
    /// is still on its way either way arrives.
    public static func hangUp(_ descriptor: Int32, patience: TimeInterval = 5) {
        shutdown(descriptor, SHUT_WR)
        let deadline = Date().addingTimeInterval(patience)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) { break }
        }
        // Whoever else is still waiting to read from it is told that nothing will come, before the
        // number is given away to the next connection.
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }
}
