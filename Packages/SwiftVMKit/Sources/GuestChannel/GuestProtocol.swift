import Foundation

/// The conversation between the app and the agent that runs inside a guest.
///
/// It runs over the machine's socket device (virtio-vsock), so it needs no network in the guest. The agent
/// listens, the app connects. Both sides send one JSON object per line, and every object says what it is
/// in `type`. A side ignores the types and fields it doesn't know, so that an agent and an app of different
/// ages still get along; what they may use with each other is settled by the lower of the two `protocol`
/// numbers they exchange in their `hello` messages.
public enum GuestProtocol {
    /// The newest version of the protocol this build speaks.
    public static let version = 1
    /// The port in the guest that the agent listens on. It is below 1024, where only root may listen, so
    /// that the app knows who answers.
    public static let agentPort: UInt32 = 717
    /// No message is longer than this, its line break included.
    public static let maximumLineLength = 256 * 1024
    /// The version of the agent for macOS guests that is built from these sources, as it reports it
    /// when it connects. The agent for Linux keeps its own, in its script.
    public static let macAgentVersion = "1.0"

    /// The time on this Mac, in nanoseconds since 1970, as the agent takes it for setting the guest's clock.
    public static func currentTimeInNanoseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }
}

/// What an agent can do beyond what every agent does (set the clock, mount shared folders, shut down).
/// An agent names the ones it offers in its `hello`, and the app asks for nothing else.
public enum GuestFeature {
    /// Shares the clipboard: both sides send ``HostMessage/clipboard(text:)`` and
    /// ``AgentMessage/clipboard(text:)`` when text is copied, and the agent sends
    /// ``AgentMessage/clipboardRequest`` when it has a clipboard to fill.
    public static let clipboard = "clipboard"
    /// Answers ``HostMessage/setTimeZone(id:identifier:)``.
    public static let timeZone = "time-zone"
}

/// What an agent says about itself and its system when a connection opens.
public struct AgentHello: Codable, Sendable, Hashable {
    /// The newest version of the protocol the agent speaks.
    public var `protocol`: Int
    /// The agent's own version.
    public var agent: String
    public var system: GuestSystem
    public var hostName: String?
    /// The ``GuestFeature``s the agent offers. Names this build doesn't know are kept and ignored.
    public var features: [String]

    public init(
        protocol: Int = GuestProtocol.version, agent: String, system: GuestSystem = GuestSystem(), hostName: String? = nil,
        features: [String] = []
    ) {
        self.protocol = `protocol`
        self.agent = agent
        self.system = system
        self.hostName = hostName
        self.features = features
    }

    private enum CodingKeys: String, CodingKey {
        case `protocol`, agent, system, hostName, features
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        `protocol` = try container.decode(Int.self, forKey: .protocol)
        agent = try container.decode(String.self, forKey: .agent)
        system = try container.decodeIfPresent(GuestSystem.self, forKey: .system) ?? GuestSystem()
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        features = try container.decodeIfPresent([String].self, forKey: .features) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(`protocol`, forKey: .protocol)
        try container.encode(agent, forKey: .agent)
        try container.encode(system, forKey: .system)
        try container.encodeIfPresent(hostName, forKey: .hostName)
        // An agent without any says nothing about them, as the agents did before there were features.
        if !features.isEmpty {
            try container.encode(features, forKey: .features)
        }
    }

    public func offers(_ feature: String) -> Bool {
        features.contains(feature)
    }
}

/// The operating system in a guest, in its own words.
public struct GuestSystem: Codable, Sendable, Hashable {
    /// The distribution's identifier, such as `ubuntu` (`ID` in a Linux system's os-release), or `macos`.
    public var id: String?
    /// The system's name without a version, such as `Ubuntu`.
    public var name: String?
    public var version: String?
    /// Name and version the way the system shows them, such as `Ubuntu 26.04.1 LTS`.
    public var prettyName: String?
    /// The system's build, where it has one apart from its version, such as `26A434` for macOS.
    public var build: String?
    public var kernel: String?
    public var architecture: String?

    public init(
        id: String? = nil, name: String? = nil, version: String? = nil, prettyName: String? = nil, build: String? = nil,
        kernel: String? = nil, architecture: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.prettyName = prettyName
        self.build = build
        self.kernel = kernel
        self.architecture = architecture
    }

    /// The best the guest offers to show a person: `Ubuntu 26.04.1 LTS`, or failing that `Ubuntu 26.04`.
    public var displayName: String? {
        if let prettyName, !prettyName.isEmpty { return prettyName }
        guard let name, !name.isEmpty else { return nil }
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }
}

/// One of the guest's network interfaces that holds an address.
public struct GuestInterface: Codable, Sendable, Hashable {
    /// The interface's name in the guest, such as `enp0s1`.
    public var name: String
    /// Its hardware address, colon-separated.
    public var mac: String
    /// The addresses it holds, IPv4 and IPv6, without those that only work on the link itself.
    public var addresses: [String]

    public init(name: String, mac: String, addresses: [String]) {
        self.name = name
        self.mac = mac
        self.addresses = addresses
    }
}

/// The agent's answer to a request.
public struct GuestRequestResult: Codable, Sendable, Hashable {
    /// The `id` of the request this answers.
    public var id: Int
    public var ok: Bool
    /// Why it didn't work, in the agent's words.
    public var error: String?

    public init(id: Int, ok: Bool, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
    }
}

/// A message from the agent to the app.
public enum AgentMessage: Sendable, Hashable {
    /// The first message on every connection.
    case hello(AgentHello)
    /// The interfaces that hold addresses: once after `hello`, and again whenever they change.
    case addresses([GuestInterface])
    case result(GuestRequestResult)
    /// Text was copied in the guest. Only from an agent that offers ``GuestFeature/clipboard``.
    case clipboard(text: String)
    /// Someone has logged in at the guest's screen and has nothing from the Mac on their clipboard yet:
    /// the agent asks for what is on the Mac's. Nothing is kept in the guest for them in the meantime,
    /// so that what they get is what is on the Mac now, or nothing if it isn't shared any more.
    case clipboardRequest
    /// A kind of message this build doesn't know. It is ignored.
    case unknown(type: String)
}

/// A message from the app to the agent. Those with an `id` are requests, which the agent answers with a
/// ``GuestRequestResult`` of the same `id`.
public enum HostMessage: Sendable, Hashable {
    /// The first message on every connection, with the newest version of the protocol the app speaks.
    case hello(protocol: Int)
    /// Set the system's clock to this time, in nanoseconds since 1970.
    case setClock(id: Int, nanoseconds: Int64)
    /// Mount the shared folders (the virtio-fs device with this tag) unless they are mounted already.
    case mountSharedFolders(id: Int, tag: String, mountPoint: String)
    /// Shut the system down.
    case shutDown(id: Int)
    /// Give the system this time zone, named as in the time zone database (`Europe/Berlin`). Only to
    /// an agent that offers ``GuestFeature/timeZone``.
    case setTimeZone(id: Int, identifier: String)
    /// Text was copied on the Mac. Only to an agent that offers ``GuestFeature/clipboard``.
    case clipboard(text: String)
    /// A kind of message this build doesn't know.
    case unknown(type: String)
}

// MARK: - Coding

private enum MessageKey: String, CodingKey {
    case type, id, `protocol`, interfaces, nanoseconds, tag, mountPoint, identifier, text
}

extension AgentMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(try AgentHello(from: decoder))
        case "addresses":
            self = .addresses(try container.decode([GuestInterface].self, forKey: .interfaces))
        case "result":
            self = .result(try GuestRequestResult(from: decoder))
        case "clipboard":
            self = .clipboard(text: try container.decode(String.self, forKey: .text))
        case "clipboard-request":
            self = .clipboardRequest
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: MessageKey.self)
        switch self {
        case .hello(let hello):
            try container.encode("hello", forKey: .type)
            try hello.encode(to: encoder)
        case .addresses(let interfaces):
            try container.encode("addresses", forKey: .type)
            try container.encode(interfaces, forKey: .interfaces)
        case .result(let result):
            try container.encode("result", forKey: .type)
            try result.encode(to: encoder)
        case .clipboard(let text):
            try container.encode("clipboard", forKey: .type)
            try container.encode(text, forKey: .text)
        case .clipboardRequest:
            try container.encode("clipboard-request", forKey: .type)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

extension HostMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: MessageKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(protocol: try container.decode(Int.self, forKey: .protocol))
        case "set-clock":
            self = .setClock(
                id: try container.decode(Int.self, forKey: .id),
                nanoseconds: try container.decode(Int64.self, forKey: .nanoseconds)
            )
        case "mount-shared-folders":
            self = .mountSharedFolders(
                id: try container.decode(Int.self, forKey: .id),
                tag: try container.decode(String.self, forKey: .tag),
                mountPoint: try container.decode(String.self, forKey: .mountPoint)
            )
        case "shut-down":
            self = .shutDown(id: try container.decode(Int.self, forKey: .id))
        case "set-time-zone":
            self = .setTimeZone(
                id: try container.decode(Int.self, forKey: .id),
                identifier: try container.decode(String.self, forKey: .identifier)
            )
        case "clipboard":
            self = .clipboard(text: try container.decode(String.self, forKey: .text))
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: MessageKey.self)
        switch self {
        case .hello(let version):
            try container.encode("hello", forKey: .type)
            try container.encode(version, forKey: .protocol)
        case .setClock(let id, let nanoseconds):
            try container.encode("set-clock", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(nanoseconds, forKey: .nanoseconds)
        case .mountSharedFolders(let id, let tag, let mountPoint):
            try container.encode("mount-shared-folders", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(tag, forKey: .tag)
            try container.encode(mountPoint, forKey: .mountPoint)
        case .shutDown(let id):
            try container.encode("shut-down", forKey: .type)
            try container.encode(id, forKey: .id)
        case .setTimeZone(let id, let identifier):
            try container.encode("set-time-zone", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(identifier, forKey: .identifier)
        case .clipboard(let text):
            try container.encode("clipboard", forKey: .type)
            try container.encode(text, forKey: .text)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

extension HostMessage {
    /// The `id` an answer to this message has to carry, if it is a request.
    public var requestID: Int? {
        switch self {
        case .setClock(let id, _), .mountSharedFolders(let id, _, _), .shutDown(let id), .setTimeZone(let id, _): id
        case .hello, .clipboard, .unknown: nil
        }
    }
}

// MARK: - Lines

/// Turns messages into the lines of the protocol and back.
public enum GuestMessageCoding {
    /// The line for `message`, with its line break.
    public static func line<Message: Encodable>(for message: Message) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A message is made of strings and numbers; there is nothing in one that can't be encoded.
        var data = (try? encoder.encode(message)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The message on `line`, or `nil` if the line isn't one this side can read.
    public static func message<Message: Decodable>(_ type: Message.Type = Message.self, from line: Data) -> Message? {
        try? JSONDecoder().decode(type, from: line)
    }

    /// The line that carries copied text, made by `message`, or `nil` when the text is too long for
    /// one. Such text simply isn't shared.
    public static func clipboardLine<Message: Encodable>(_ text: String, as message: (String) -> Message) -> Data? {
        // Written down, text only gets longer: what is too long as it is needs no writing down to tell.
        guard text.utf8.count < GuestProtocol.maximumLineLength else { return nil }
        let line = line(for: message(text))
        return line.count < GuestProtocol.maximumLineLength ? line : nil
    }
}

/// Cuts the bytes that arrive on a connection into the lines of the protocol.
public struct GuestMessageFramer: Sendable {
    public struct LineTooLong: Error {}

    private var pending = Data()

    public init() {}

    /// Takes in bytes as they arrive and returns the lines they complete, without their line breaks.
    /// Empty lines are left out.
    ///
    /// Throws when a line grows beyond ``GuestProtocol/maximumLineLength``. Whatever is at the other end
    /// isn't speaking the protocol then, and the connection is of no further use.
    public mutating func receive(_ bytes: Data) throws -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        while let lineBreak = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<lineBreak]
            guard line.count < GuestProtocol.maximumLineLength else { throw LineTooLong() }
            if !line.isEmpty {
                lines.append(Data(line))
            }
            // A fresh copy of the rest, so that what has been handed out isn't kept alive with it.
            pending = Data(pending[pending.index(after: lineBreak)...])
        }
        guard pending.count < GuestProtocol.maximumLineLength else { throw LineTooLong() }
        return lines
    }
}
