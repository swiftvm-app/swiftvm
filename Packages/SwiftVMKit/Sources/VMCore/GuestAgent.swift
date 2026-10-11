import Foundation
import GuestChannel
import Observation

/// The app's end of the line to the agent in a machine's guest.
///
/// While the guest is up, this keeps trying to reach the agent over the machine's socket device. Once an
/// agent has answered, it holds what the agent says about its system and passes requests on to it. A
/// guest without an agent simply never answers.
@MainActor
@Observable
public final class GuestAgent {
    /// What the agent said about itself and its system. `nil` while no agent is connected.
    public private(set) var hello: AgentHello?
    /// The guest's network interfaces that hold addresses, as the agent last reported them.
    public private(set) var interfaces: [GuestInterface] = []

    public var isConnected: Bool { hello != nil }
    /// The connected agent's version.
    public var version: String? { hello?.agent }
    /// The guest's kernel, as the connected agent reports it.
    public var kernel: String? { hello?.system.kernel }
    /// Whether the connected agent passes copied text on in both directions.
    public var sharesClipboard: Bool { hello?.offers(GuestFeature.clipboard) == true }
    /// Whether the connected agent can give its system a time zone.
    public var setsTimeZone: Bool { hello?.offers(GuestFeature.timeZone) == true }

    /// Called when an agent has connected and said who it is.
    @ObservationIgnored public var onConnect: (@MainActor (AgentHello) -> Void)?
    /// Called when ``interfaces`` has changed: the agent reported other addresses, or is gone.
    @ObservationIgnored public var onAddressesChange: (@MainActor () -> Void)?
    /// Called when an agent that was connected no longer is: the guest stopped, restarted by itself, or
    /// its agent went away.
    @ObservationIgnored public var onDisconnect: (@MainActor () -> Void)?
    /// Called with text that was copied in the guest, by an agent that shares the clipboard.
    @ObservationIgnored public var onClipboard: (@MainActor (String) -> Void)?
    /// Called when such an agent asks for what is on this Mac's clipboard: someone has logged in there.
    @ObservationIgnored public var onClipboardRequest: (@MainActor () -> Void)?
    /// How long to wait before trying again after the agent couldn't be reached, or went away.
    @ObservationIgnored public var retryInterval: Duration = .seconds(1)
    /// The same once ``eagerAttempts`` have come to nothing. A guest that is starting up answers within
    /// them; one without an agent never will, and is asked less often.
    @ObservationIgnored public var patientRetryInterval: Duration = .seconds(5)
    @ObservationIgnored public var eagerAttempts = 120
    /// How long whatever answers on the agent's port gets to say hello before it is hung up on.
    @ObservationIgnored public var helloTimeout: Duration = .seconds(5)
    /// How long the agent gets to answer a request.
    @ObservationIgnored public var requestTimeout: Duration = .seconds(5)
    /// How long it gets to change the time zone, which takes a guest that is busy starting up its time.
    @ObservationIgnored public var timeZoneTimeout: Duration = .seconds(30)

    @ObservationIgnored private var link: Task<Void, Never>?
    @ObservationIgnored private var connection: GuestAgentConnection?
    /// Whether an attempt to reach the agent has come to nothing since the guest came up.
    @ObservationIgnored private var hasFailedToConnect = false

    public init() {}

    /// The port in a guest that its agent listens on. It is the app's own line to the guest and nobody
    /// else's to connect to: the agent serves one connection, the newest.
    public static let port = GuestProtocol.agentPort

    // MARK: The guest coming and going

    /// Starts reaching for the agent of a guest that has just come up, and keeps at it until ``stop()``.
    ///
    /// - Parameter connect: Opens a line to the agent's port in the guest. It throws when nothing answers.
    public func start(connect: @escaping @MainActor () async throws -> FileHandle) {
        stop()
        link = Task { [weak self] in
            var fruitlessAttempts = 0
            while !Task.isCancelled {
                guard let hasReachedAgent = await self?.converse(connect) else { return }
                guard !Task.isCancelled, let self else { return }
                fruitlessAttempts = hasReachedAgent ? 0 : fruitlessAttempts + 1
                if !hasReachedAgent {
                    hasFailedToConnect = true
                }
                try? await Task.sleep(for: fruitlessAttempts > eagerAttempts ? patientRetryInterval : retryInterval)
            }
        }
    }

    /// The guest is gone. Hangs up and forgets what its agent said.
    public func stop() {
        link?.cancel()
        link = nil
        connection?.close()
        connection = nil
        hasFailedToConnect = false
        forgetAgent()
    }

    /// Waits for the agent to connect. Returns `false` when the time is up, and sooner if it is already
    /// clear that nothing answers on the agent's port.
    public func waitUntilConnected(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isConnected {
            guard link != nil, !hasFailedToConnect, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: Requests

    /// Sets the guest's clock to this Mac's. A guest that was suspended believes no time has passed.
    public func setClock() async -> Bool {
        await request { .setClock(id: $0, nanoseconds: GuestProtocol.currentTimeInNanoseconds()) }
    }

    /// Mounts the shared folders in the guest, unless they are mounted there already.
    public func mountSharedFolders(tag: String, at mountPoint: String) async -> Bool {
        await request { .mountSharedFolders(id: $0, tag: tag, mountPoint: mountPoint) }
    }

    /// Has the guest shut itself down. `true` means it has started to.
    public func shutDown() async -> Bool {
        await request { .shutDown(id: $0) }
    }

    /// Gives the guest a time zone, named as in the time zone database (`Europe/Berlin`).
    public func setTimeZone(_ identifier: String) async -> Bool {
        guard setsTimeZone, let connection else { return false }
        return await connection.request(timeout: timeZoneTimeout) { .setTimeZone(id: $0, identifier: identifier) }?.ok == true
    }

    /// Tells the guest that `text` was copied on this Mac. Returns `false` when there is no agent that
    /// shares the clipboard, or the text is longer than a message may be.
    @discardableResult
    public func sendClipboard(_ text: String) -> Bool {
        guard sharesClipboard, let connection,
              let line = GuestMessageCoding.clipboardLine(text, as: HostMessage.clipboard(text:))
        else { return false }
        return connection.send(line: line)
    }

    /// Whether the agent did what `message` asks. `false` also when there is no agent, or no answer.
    private func request(_ message: @Sendable (Int) -> HostMessage) async -> Bool {
        guard isConnected, let connection else { return false }
        return await connection.request(timeout: requestTimeout, message)?.ok == true
    }

    // MARK: What the guest reports

    /// Every address the guest reports, on whichever network card.
    public var addresses: [String] {
        interfaces.flatMap(\.addresses)
    }

    /// The addresses the guest holds on the network card with this hardware address, as it reports them.
    public func addresses(ofInterface macAddress: String) -> [String] {
        guard let wanted = MACAddress(macAddress) else { return [] }
        return interfaces.filter { MACAddress($0.mac) == wanted }.flatMap(\.addresses)
    }

    // MARK: Private

    /// One attempt to reach the agent, which lasts for as long as the agent stays on the line. Returns
    /// whether there was an agent at all.
    private func converse(_ connect: @MainActor () async throws -> FileHandle) async -> Bool {
        guard let handle = try? await connect(), !Task.isCancelled else { return false }
        let connection = GuestAgentConnection(handle: handle)
        self.connection = connection
        defer {
            connection.close()
            // Unless the guest has stopped in the meantime, or stopped and started: then all of this
            // has been cleared already, and the connection there now belongs to its next run.
            if self.connection === connection {
                self.connection = nil
                forgetAgent()
            }
        }

        connection.send(.hello(protocol: GuestProtocol.version))
        // An agent says hello at once. Whatever else answers on its port isn't worth waiting for.
        let patience = Task { [helloTimeout] in
            try? await Task.sleep(for: helloTimeout)
            if !Task.isCancelled {
                connection.close()
            }
        }
        defer { patience.cancel() }

        var hasSaidHello = false
        for await message in connection.messages {
            guard !Task.isCancelled, self.connection === connection else { break }
            switch message {
            case .hello(let hello):
                guard !hasSaidHello, hello.protocol >= 1 else { continue }
                hasSaidHello = true
                patience.cancel()
                self.hello = hello
                onConnect?(hello)
            case .addresses(let interfaces):
                if hasSaidHello, interfaces != self.interfaces {
                    self.interfaces = interfaces
                    onAddressesChange?()
                }
            case .clipboard(let text):
                if hasSaidHello, sharesClipboard {
                    onClipboard?(text)
                }
            case .clipboardRequest:
                if hasSaidHello, sharesClipboard {
                    onClipboardRequest?()
                }
            case .result, .unknown:
                break
            }
        }
        return hasSaidHello
    }

    private func forgetAgent() {
        let wasConnected = hello != nil
        if wasConnected {
            hello = nil
        }
        if !interfaces.isEmpty {
            interfaces = []
            onAddressesChange?()
        }
        if wasConnected {
            onDisconnect?()
        }
    }
}
