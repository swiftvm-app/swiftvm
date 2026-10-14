import Foundation

/// How many connections share one serial line, for a guest that has no socket device: a Windows guest
/// on QEMU, whose Mac side has no vsock.
///
/// The app opens a connection to a port the agent listens on, as it would over a socket device, and
/// both ends then pass bytes in frames that say which connection they belong to. Each direction of a
/// connection ends on its own, so that a job's agent can say it has no more to send and still hear
/// the other side hang up, as it does over a socket.
///
/// A frame is a byte for its kind, four for the connection and four for the length of what follows,
/// most significant first, and then that many bytes.
public struct ChannelFrame: Sendable, Hashable {
    public enum Kind: UInt8, Sendable, Hashable {
        /// From the agent, first, whenever it has opened the line, and in answer to the app's: whatever
        /// was open before is gone. From the app when it opens its end, to hear it.
        case hello = 0
        /// From the app: a new connection, to the port that the payload names in four bytes.
        case open = 1
        /// From the agent: it took the connection.
        case accept = 2
        /// From the agent: nothing listens on that port.
        case refuse = 3
        case data = 4
        /// The sender has no more to send on this connection. It still reads.
        case end = 5
        /// The sender is done with the connection both ways.
        case close = 6
    }

    public var kind: Kind
    public var connection: UInt32
    public var payload: Data

    public init(_ kind: Kind, connection: UInt32 = 0, payload: Data = Data()) {
        self.kind = kind
        self.connection = connection
        self.payload = payload
    }

    /// The frame the agent opens the line with. It carries words of its own, so that a reader that has
    /// lost its way in what an agent before it left half sent finds the start of what this one sends.
    public static let hello = ChannelFrame(.hello, payload: Data("swiftvm-agent-channel".utf8))

    /// The frame that opens `connection` to `port`.
    public static func open(_ connection: UInt32, port: UInt32) -> ChannelFrame {
        ChannelFrame(.open, connection: connection, payload: withUnsafeBytes(of: port.bigEndian) { Data($0) })
    }

    /// The port an ``Kind/open`` frame asks for.
    public var port: UInt32? {
        guard kind == .open, payload.count == 4 else { return nil }
        return payload.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// No frame carries more than this. More is sent as several.
    public static let maximumPayloadLength = 64 * 1024
    static let headerLength = 9

    public var encoded: Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.append(kind.rawValue)
        withUnsafeBytes(of: connection.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Cuts the bytes that arrive into frames.
    ///
    /// What isn't frames is passed over up to the next ``ChannelFrame/hello``: an agent that stopped
    /// half way through a frame leaves the rest of it unsaid, and the one after it starts with a hello.
    public struct Reader: Sendable {
        private var pending = Data()
        /// The bytes are no frames: the next hello is looked for.
        public private(set) var isLost = false

        public init() {}

        /// Takes in bytes as they arrive and returns the frames they complete.
        public mutating func receive(_ bytes: Data) -> [ChannelFrame] {
            pending.append(bytes)
            var frames: [ChannelFrame] = []
            // Where the next frame starts. What is before it is let go of once, at the end: cutting each
            // frame off on its own would copy everything after it, again for every frame.
            var offset = pending.startIndex
            while true {
                if isLost {
                    let marker = ChannelFrame.hello.encoded
                    guard let found = pending[offset...].firstRange(of: marker) else {
                        // What is left may be the start of one.
                        offset = max(offset, pending.endIndex - (marker.count - 1))
                        break
                    }
                    offset = found.lowerBound
                    isLost = false
                }
                guard pending.endIndex - offset >= ChannelFrame.headerLength else { break }
                let connection = pending[(offset + 1)..<(offset + 5)].reduce(0) { $0 << 8 | UInt32($1) }
                let length = Int(pending[(offset + 5)..<(offset + 9)].reduce(0) { $0 << 8 | UInt32($1) })
                guard let kind = Kind(rawValue: pending[offset]), length <= ChannelFrame.maximumPayloadLength else {
                    isLost = true
                    offset += 1
                    continue
                }
                guard pending.endIndex - offset >= ChannelFrame.headerLength + length else { break }
                let payload = Data(pending[(offset + ChannelFrame.headerLength)..<(offset + ChannelFrame.headerLength + length)])
                frames.append(ChannelFrame(kind, connection: connection, payload: payload))
                offset += ChannelFrame.headerLength + length
            }
            pending = Data(pending[offset...])
            return frames
        }

        /// Lets go of what has arrived and looks for the next hello: the agent that sent it is gone,
        /// maybe half way through a frame.
        public mutating func reset() {
            pending = Data()
            isLost = true
        }
    }
}
