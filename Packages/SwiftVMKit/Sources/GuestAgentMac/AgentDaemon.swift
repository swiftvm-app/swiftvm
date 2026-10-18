import Foundation
import GuestChannel

/// The half of the agent that runs as root: it answers the SwiftVM app on the Mac.
///
/// The app connects over the virtual machine's socket device, which needs no network. This half tells it
/// which system this is and which addresses it holds, and on its request sets the clock, sets the time
/// zone or shuts the system down. The clipboard belongs to whoever is logged in, where root can't reach
/// it: the agent's other half (``SessionAgent``) runs there and connects to this one, which passes copied
/// text on between it and the app.
///
/// Nothing that was copied is kept here. A session that begins asks the app, through this half, for what
/// is on the Mac's clipboard at that moment: the app knows, and knows whether it is still shared.
///
/// On a second port it takes jobs for whoever drives this system from the Mac (``AgentJobs``): commands
/// to run, and what is done with the screen, the mouse and the keyboard, which it hands to the other half.
///
/// It serves one app and one session at a time, the newest of each. Everything happens on one queue,
/// except what takes the system long to do, and jobs, which have threads of their own.
final class AgentDaemon: @unchecked Sendable {
    /// How long addresses get to settle after the system says they changed, before a look.
    var settleTime: TimeInterval = 0.3
    /// How often to look anyway, while the app is there to tell.
    var lookInterval: TimeInterval = 30

    private let system: any AgentSystem
    private let queue: DispatchQueue
    private let version: String
    private var app: AgentLine?
    private var session: AgentLine?
    /// The interfaces as the app was last told.
    private var reported: [GuestInterface]?
    /// A session has begun and has been given nothing from the Mac's clipboard yet.
    private var sessionWantsClipboard = false
    /// Where the system is asked for what it takes its time over, one thing after the other.
    private let slowWork = DispatchQueue(label: "SwiftVM guest agent, slow work")
    private var sources: [any DispatchSourceProtocol] = []
    private var addressWatcher: AddressWatcher?
    private var isLookDue = false
    private lazy var jobs = AgentJobs(system: system, version: version) { [weak self] token in
        self?.announceJob(token) ?? false
    }

    /// - Parameter queue: Where everything the daemon does happens. Call its methods from there, except
    ///   where they say otherwise.
    init(system: any AgentSystem, queue: DispatchQueue, version: String = GuestProtocol.macAgentVersion) {
        self.system = system
        self.queue = queue
        self.version = version
        // Made now, by the one who makes the daemon: a job can be served from any thread, and two
        // that came at once must not each make their own.
        _ = jobs
    }

    // MARK: Listening

    /// Starts listening for the app on the socket device and for the session on a Unix socket, and
    /// keeps an eye on the system's addresses. Safe to call from anywhere.
    func listen(
        port: UInt32 = GuestProtocol.agentPort, jobPort: UInt32 = GuestProtocol.jobPort,
        sessionSocketPath: String = AgentSockets.sessionSocketPath, sessionJobSocketPath: String = AgentSockets.sessionJobSocketPath
    ) {
        queue.async { [self] in
            listenForApp(port: port, lastProblem: nil)
            listenForJobs(port: jobPort)
            listenForSession(path: sessionSocketPath)
            listenForSessionJobs(path: sessionJobSocketPath)
            addressWatcher = AddressWatcher(queue: queue) { [weak self] in self?.addressesMayHaveChanged() }
            let regularLook = DispatchSource.makeTimerSource(queue: queue)
            regularLook.schedule(deadline: .now() + lookInterval, repeating: lookInterval, leeway: .seconds(5))
            regularLook.setEventHandler { [weak self] in self?.reportAddresses() }
            regularLook.resume()
            sources.append(regularLook)
        }
    }

    /// Waits for as long as it takes for the socket device to be there: early in a start it isn't yet.
    private func listenForApp(port: UInt32, lastProblem: String?) {
        do {
            let listener = try AgentSockets.listenOnSocketDevice(port: port)
            accept(on: listener) { [weak self] in
                guard let connection = AgentSockets.acceptFromHost(on: listener) else { return }
                self?.serveApp(on: connection)
            }
            AgentLog.note("SwiftVM guest agent \(version), listening on port \(port) of the socket device.")
        } catch {
            let problem = "\(error)"
            if problem != lastProblem {
                AgentLog.note("Can't listen on the socket device (\(problem)). Trying again until it works.")
            }
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.listenForApp(port: port, lastProblem: problem) }
        }
    }

    /// Jobs arrive on a port of their own, each on its own connection. The socket device is there by
    /// the time the app's port could be listened on, or will be: this tries for as long.
    private func listenForJobs(port: UInt32) {
        do {
            let listener = try AgentSockets.listenOnSocketDevice(port: port)
            accept(on: listener) { [weak self] in
                guard let connection = AgentSockets.acceptFromHost(on: listener) else { return }
                self?.serveJob(on: connection)
            }
        } catch {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.listenForJobs(port: port) }
        }
    }

    private func listenForSessionJobs(path: String) {
        do {
            let listener = try AgentSockets.listenOnUnixSocket(path: path)
            accept(on: listener) { [weak self] in
                guard let (connection, user) = AgentSockets.acceptLocal(on: listener) else { return }
                // What the Mac asks of the screen is done by whoever sits at it, and answered by nobody else.
                guard user == AgentSockets.consoleUser() else {
                    close(connection)
                    return
                }
                self?.serveSessionJob(on: connection)
            }
        } catch {
            AgentLog.note("Can't listen for the user's session to take jobs (\(error)). The screen, the mouse and the keyboard won't be reached.")
        }
    }

    private func listenForSession(path: String) {
        do {
            let listener = try AgentSockets.listenOnUnixSocket(path: path)
            accept(on: listener) { [weak self] in
                guard let (connection, user) = AgentSockets.acceptLocal(on: listener) else { return }
                // The clipboard that is shared is the one of whoever sits at the screen, and nobody else
                // in this system gets to read what was copied on the Mac.
                guard user == AgentSockets.consoleUser() else {
                    close(connection)
                    return
                }
                self?.serveSession(on: connection)
            }
        } catch {
            AgentLog.note("Can't listen for the user's session (\(error)). The clipboard won't be shared.")
        }
    }

    private func accept(on listener: Int32, _ handler: @escaping () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
        sources.append(source)
    }

    // MARK: Connections

    /// Serves the app on a connection it has made. The app connects anew after the machine was
    /// suspended, when it can no longer use the connection it had: the newest one is the one that counts.
    func serveApp(on descriptor: Int32) {
        app?.close()
        let line = AgentLine(descriptor: descriptor, queue: queue)
        app = line
        reported = nil
        line.onLine = { [weak self, weak line] bytes in
            guard let self, let line, app === line else { return }
            handleFromApp(bytes)
        }
        line.onEnd = { [weak self, weak line] in
            guard let self, let line, app === line else { return }
            app = nil
        }
        line.start()
        send(.hello(AgentHello(
            agent: version, system: system.describe(), hostName: system.hostName(),
            features: [
                GuestFeature.clipboard, GuestFeature.timeZone, GuestFeature.exec, GuestFeature.screen, GuestFeature.input,
                GuestFeature.accessibility, GuestFeature.permission,
            ]
        )))
        reportAddresses(always: true)
        // Someone logged in while the app wasn't there to ask.
        if session != nil, sessionWantsClipboard {
            send(.clipboardRequest)
        }
    }

    /// Serves the agent's half in the session of the user at the screen. A session that begins takes the
    /// place of the one before.
    func serveSession(on descriptor: Int32) {
        session?.close()
        let line = AgentLine(descriptor: descriptor, queue: queue)
        session = line
        line.onLine = { [weak self, weak line] bytes in
            guard let self, let line, session === line else { return }
            handleFromSession(bytes)
        }
        line.onEnd = { [weak self, weak line] in
            guard let self, let line, session === line else { return }
            session = nil
            sessionWantsClipboard = false
        }
        line.start()
        // Whoever logs in finds on their clipboard what is on the Mac's. The app is asked for it now,
        // or when it next connects.
        sessionWantsClipboard = true
        send(.clipboardRequest)
    }

    private func send(_ message: AgentMessage) {
        app?.send(GuestMessageCoding.line(for: message))
    }

    // MARK: Jobs

    /// Serves a job on a connection the Mac has made for it. Safe to call from anywhere.
    func serveJob(on descriptor: Int32) {
        jobs.serve(descriptor)
    }

    /// The session's half has connected for a job it was told about. Safe to call from anywhere.
    func serveSessionJob(on descriptor: Int32) {
        jobs.serveSession(descriptor)
    }

    /// Tells the session's half that there is a job for it under this name. `false` when nobody is
    /// logged in to tell. Called from a job's own thread.
    private func announceJob(_ token: String) -> Bool {
        queue.sync {
            session?.send(GuestMessageCoding.line(for: SessionJobNotice(token: token))) ?? false
        }
    }

    // MARK: Messages

    private func handleFromApp(_ bytes: Data) {
        guard let message = GuestMessageCoding.message(HostMessage.self, from: bytes) else { return }
        switch message {
        case .hello:
            break
        case .setClock(let id, let nanoseconds):
            answer(id) {
                guard nanoseconds > 0 else { throw AgentFailure("The time has to be a number of nanoseconds since 1970.") }
                try system.setClock(nanoseconds: nanoseconds)
            }
        case .setTimeZone(let id, let identifier):
            // The system takes seconds over this while it is busy starting up. Nothing else waits for
            // it: a request to shut down that comes meanwhile is answered at once. The answer goes to
            // the line that asked, if that is still the app's.
            let asking = app
            slowWork.async { [weak self, system] in
                let outcome = Result { try system.setTimeZone(identifier) }
                guard let self else { return }
                queue.async { [self] in
                    guard let asking, app === asking else { return }
                    answer(id) { try outcome.get() }
                }
            }
        case .shutDown(let id):
            answer(id) { try system.shutDown() }
        case .mountSharedFolders(let id, _, _, _):
            answer(id) { throw AgentFailure("macOS mounts the shared folders by itself, under /Volumes/My Shared Files.") }
        case .clipboard(let text):
            // Without anyone logged in there is no clipboard to put it on, and it goes nowhere.
            if let session, let line = GuestMessageCoding.clipboardLine(text, as: HostMessage.clipboard(text:)), session.send(line) {
                sessionWantsClipboard = false
            }
        case .displaySize, .seamless, .activateWindow, .hitTest, .moveWindow, .resizeWindow:
            // macOS fits its display to the window by itself, and its windows aren't shown one by one.
            // The app sends these only to an agent that offers them, which this one doesn't.
            break
        case .unknown(let type):
            // Something from a later version of the app. If it asks for an answer, it gets a no.
            if let id = GuestMessageCoding.message(Identified.self, from: bytes)?.id {
                send(.result(GuestRequestResult(id: id, ok: false, error: "This agent (\(version)) doesn't know what “\(type.prefix(64))” is.")))
            }
        }
    }

    private struct Identified: Decodable {
        var id: Int?
    }

    private func answer(_ id: Int, _ request: () throws -> Void) {
        do {
            try request()
            send(.result(GuestRequestResult(id: id, ok: true)))
        } catch let failure as AgentFailure {
            send(.result(GuestRequestResult(id: id, ok: false, error: failure.message)))
        } catch {
            send(.result(GuestRequestResult(id: id, ok: false, error: error.localizedDescription)))
        }
    }

    private func handleFromSession(_ bytes: Data) {
        // The session has one thing to say: that text was copied.
        guard case .clipboard(let text) = GuestMessageCoding.message(AgentMessage.self, from: bytes),
              let line = GuestMessageCoding.clipboardLine(text, as: AgentMessage.clipboard(text:))
        else { return }
        app?.send(line)
    }

    // MARK: Addresses

    /// The system says a card got an address or lost one. One change seldom comes alone, so the look
    /// waits until they have settled.
    func addressesMayHaveChanged() {
        guard !isLookDue else { return }
        isLookDue = true
        queue.asyncAfter(deadline: .now() + settleTime) { [weak self] in
            self?.isLookDue = false
            self?.reportAddresses()
        }
    }

    private func reportAddresses(always: Bool = false) {
        // Without the app there is nobody to tell, and nothing to look for.
        guard app != nil else { return }
        let interfaces = system.interfaces()
        if always || interfaces != reported {
            reported = interfaces
            send(.addresses(interfaces))
        }
    }
}
