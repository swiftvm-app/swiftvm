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
    /// How the guest's setup script is doing, as the agent last reported it. `nil` for a guest that has
    /// none, and while no agent is connected.
    public private(set) var setup: GuestSetupStatus?
    /// The windows on the guest's screen, as the agent last reported them while asked to. `nil` while
    /// it isn't asked to, or hasn't said yet.
    public private(set) var windows: GuestWindowList?

    public var isConnected: Bool { hello != nil }
    /// The connected agent's version.
    public var version: String? { hello?.agent }
    /// The guest's kernel, as the connected agent reports it.
    public var kernel: String? { hello?.system.kernel }
    /// Whether the connected agent passes copied text on in both directions.
    public var sharesClipboard: Bool { hello?.offers(GuestFeature.clipboard) == true }
    /// Whether the connected agent can give its system a time zone.
    public var setsTimeZone: Bool { hello?.offers(GuestFeature.timeZone) == true }
    /// What the connected agent offers beyond what every agent does, by the names in ``GuestFeature``.
    public var features: [String] { hello?.features ?? [] }

    /// Whether the connected agent offers `feature`.
    public func offers(_ feature: String) -> Bool {
        hello?.offers(feature) == true
    }

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
    /// Called when the agent reports where the guest's setup script has got to: once when it connects
    /// to a guest that has one, and whenever that changes.
    @ObservationIgnored public var onSetupChange: (@MainActor (GuestSetupStatus) -> Void)?
    /// Called when ``windows`` has changed.
    @ObservationIgnored public var onWindowsChange: (@MainActor () -> Void)?
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
    /// Whether the app wants the guest's windows, which an agent that connects again is asked for anew.
    @ObservationIgnored private var wantsWindows = false
    /// Those waiting to hear whether a point is on a window's title bar, by the number of their question.
    @ObservationIgnored private var hitTests: [Int: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var lastHitTest = 0
    /// How long a question about a point is given before the answer is taken to be no. A click waits on
    /// it, and so is passed on as it is if the agent takes longer.
    @ObservationIgnored public var hitTestTimeout: Duration = .milliseconds(250)

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

    /// Mounts the shared folders in the guest, unless they are mounted there already: those of the
    /// device with `tag`, or the folders that have a device each.
    public func mountSharedFolders(tag: String, at mountPoint: String, folders: [SharedFolderDevice] = []) async -> Bool {
        await request { .mountSharedFolders(id: $0, tag: tag, mountPoint: mountPoint, folders: folders) }
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

    /// Tells the agent how large the window is that its guest is shown in. Returns `false` when there is
    /// no agent that fits its desktop to it.
    @discardableResult
    public func sendDisplaySize(width: Int, height: Int, scale: Double) -> Bool {
        guard hello?.offers(GuestFeature.displaySize) == true, let connection else { return false }
        return connection.send(line: GuestMessageCoding.line(for: HostMessage.displaySize(width: width, height: height, scale: scale)))
    }

    /// Has the agent report the guest's windows in ``windows``, or stop. The agent is asked again
    /// whenever it connects, until this is turned off. Returns `false` when there is no agent that
    /// reports them.
    @discardableResult
    public func reportWindows(_ enabled: Bool) -> Bool {
        wantsWindows = enabled
        if !enabled {
            forgetWindows()
        }
        guard hello?.offers(GuestFeature.seamless) == true, let connection else { return false }
        return connection.send(line: GuestMessageCoding.line(for: HostMessage.seamless(enabled: enabled)))
    }

    /// Has the guest bring one of its ``windows`` to the front.
    @discardableResult
    public func activateWindow(_ id: GuestWindow.ID) -> Bool {
        guard hello?.offers(GuestFeature.seamless) == true, let connection else { return false }
        return connection.send(line: GuestMessageCoding.line(for: HostMessage.activateWindow(id)))
    }

    /// Whether a click at this point of the guest's screen, in its pixels, would take hold of the title bar
    /// of the window with this ``GuestWindow/id``: Windows' own, or one that its app draws itself. `false`
    /// also when the agent doesn't answer in time.
    public func isTitleBar(of window: GuestWindow.ID, x: Int, y: Int) async -> Bool {
        guard hello?.offers(GuestFeature.seamless) == true, let connection else { return false }
        lastHitTest += 1
        let request = lastHitTest
        return await withCheckedContinuation { continuation in
            hitTests[request] = continuation
            let test = GuestHitTest(request: request, window: window, x: x, y: y)
            guard connection.send(line: GuestMessageCoding.line(for: HostMessage.hitTest(test))) else {
                answerHitTest(request, isTitleBar: false)
                return
            }
            Task { [hitTestTimeout] in
                try? await Task.sleep(for: hitTestTimeout)
                answerHitTest(request, isTitleBar: false)
            }
        }
    }

    /// Has the guest move one of its ``windows`` so that its top left corner is at this point of its
    /// screen, in its pixels.
    @discardableResult
    public func moveWindow(_ id: GuestWindow.ID, x: Int, y: Int) -> Bool {
        guard hello?.offers(GuestFeature.seamless) == true, let connection else { return false }
        return connection.send(line: GuestMessageCoding.line(for: HostMessage.moveWindow(id, x: x, y: y)))
    }

    /// Has the guest move a window and give it a size, as it was resized on the Mac. `false` without an
    /// agent that can.
    @discardableResult
    public func resizeWindow(_ id: GuestWindow.ID, x: Int, y: Int, width: Int, height: Int) -> Bool {
        guard hello?.offers(GuestFeature.seamless) == true, let connection else { return false }
        return connection.send(line: GuestMessageCoding.line(for: HostMessage.resizeWindow(id, x: x, y: y, width: width, height: height)))
    }

    private func answerHitTest(_ request: Int, isTitleBar: Bool) {
        hitTests.removeValue(forKey: request)?.resume(returning: isTitleBar)
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
                if wantsWindows, hello.offers(GuestFeature.seamless) {
                    connection.send(.seamless(enabled: true))
                }
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
            case .setup(let status):
                if hasSaidHello, status != setup {
                    setup = status
                    onSetupChange?(status)
                }
            case .windows(let list):
                if hasSaidHello, wantsWindows, offers(GuestFeature.seamless), list != windows {
                    windows = list
                    onWindowsChange?()
                }
            case .hit(let hit):
                answerHitTest(hit.request, isTitleBar: hit.area == GuestHit.titleBar)
            case .result, .unknown:
                break
            }
        }
        return hasSaidHello
    }

    private func forgetWindows() {
        guard windows != nil else { return }
        windows = nil
        onWindowsChange?()
    }

    private func forgetAgent() {
        let wasConnected = hello != nil
        if wasConnected {
            hello = nil
        }
        if setup != nil {
            setup = nil
        }
        forgetWindows()
        for request in Array(hitTests.keys) {
            answerHitTest(request, isTitleBar: false)
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
