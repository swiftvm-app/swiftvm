import Foundation

/// A request to `swiftvm serve`, in API v1: the few the app makes itself. The service's own reference is
/// docs/tech/api.md; the Rust types are in crates/swiftvm-protocol.
public struct ServiceRequest: Codable, Sendable, Equatable {
    public var id: Int
    public var command: String
    /// For `hello`: the version of the API spoken.
    public var `protocol`: Int?
    /// For `hello`: who is asking, with its version.
    public var client: String?
    /// For the `clients-` commands: the path of a program.
    public var program: String?

    public init(id: Int, command: String, protocol: Int? = nil, client: String? = nil, program: String? = nil) {
        self.id = id
        self.command = command
        self.protocol = `protocol`
        self.client = client
        self.program = program
    }
}

/// An answer from `swiftvm serve`, in API v1, with the parts the app reads.
public struct ServiceAnswer: Codable, Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public var code: String
        public var message: String
    }

    public struct Info: Codable, Sendable, Equatable {
        public struct App: Codable, Sendable, Equatable {
            public var running: Bool
        }

        public var version: String
        public var `protocol`: Int
        public var platform: String
        public var offers: [String]
        public var app: App
    }

    /// A program that was allowed to use SwiftVM, or refused.
    public struct ClientProgram: Codable, Sendable, Equatable, Identifiable {
        public var path: String
        public var name: String
        public var allowed: Bool
        /// When, in RFC 3339.
        public var decidedAt: String

        public var id: String { path }
    }

    public var id: Int?
    public var ok: Bool
    public var error: Failure?
    public var machines: [MachineSummary]
    public var service: Info?
    public var clients: [ClientProgram]?
}

/// Talks to `swiftvm serve`. The app is always allowed to: it is the service's own app.
public struct ServiceClient: Sendable {
    public static let protocolVersion = 1

    public let socketURL: URL

    public init(socketURL: URL = ControlPaths.serviceSocket) {
        self.socketURL = socketURL
    }

    /// Says hello, sends `command`, and returns the answer. Throws when the service isn't running, or
    /// refuses the app.
    public func send(_ command: String, program: String? = nil) throws -> ServiceAnswer {
        let descriptor = try ControlSocket.connect(to: socketURL)
        defer { close(descriptor) }
        let hello = try exchange(
            ServiceRequest(id: 0, command: "hello", protocol: Self.protocolVersion, client: "\(AppIdentity.current.name) app"), over: descriptor
        )
        guard hello.ok else { throw ServiceClientError.refused(hello.error?.message ?? "The service refused the app.") }
        return try exchange(ServiceRequest(id: 1, command: command, program: program), over: descriptor)
    }

    private func exchange(_ request: ServiceRequest, over descriptor: Int32) throws -> ServiceAnswer {
        try ControlSocket.writeLine(JSONEncoder().encode(request), to: descriptor)
        guard let line = ControlSocket.readLine(from: descriptor) else { throw ControlSocketError.connectionClosed }
        guard let answer = try? JSONDecoder().decode(ServiceAnswer.self, from: line) else { throw ControlSocketError.invalidMessage }
        return answer
    }
}

public enum ServiceClientError: Error, LocalizedError, Equatable {
    case refused(String)
    /// The service answered with a failure: its code in API v1, and its words.
    case failed(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .refused(let message): message
        case .failed(_, let message): message
        }
    }
}
