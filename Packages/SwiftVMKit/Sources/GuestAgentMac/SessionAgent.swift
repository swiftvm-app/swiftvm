import AppKit
import GuestChannel

/// A clipboard, as far as the agent has to do with one: what was copied last, as text.
protocol AgentPasteboard: AnyObject {
    /// Goes up whenever something is copied, by anyone.
    var changeCount: Int { get }
    /// What was copied, if it can be had as text.
    var text: String? { get }
    func setText(_ text: String)
}

/// The clipboard of the session the agent runs in.
final class SystemPasteboard: AgentPasteboard {
    private let pasteboard = NSPasteboard.general

    init() {}

    var changeCount: Int { pasteboard.changeCount }
    var text: String? { pasteboard.string(forType: .string) }

    func setText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The half of the agent that runs in the session of whoever is logged in, where the clipboard is.
///
/// It tells the half that runs as root (``AgentDaemon``) when text is copied here, for the app on the
/// Mac, and puts on the clipboard what was copied there. It has no line to the Mac of its own.
///
/// macOS has no way to be told that something was copied, so this looks at the clipboard's counter a
/// couple of times a second, which costs next to nothing, and only reads the clipboard when it has moved.
final class SessionAgent: @unchecked Sendable {
    private let pasteboard: any AgentPasteboard
    private let queue: DispatchQueue
    private let connect: () -> Int32?
    private let lookInterval: TimeInterval
    private let retryInterval: TimeInterval
    private var daemon: AgentLine?
    /// The state of the clipboard that has been dealt with: told to the Mac, or put there from it.
    private var seenChangeCount: Int
    private var timer: (any DispatchSourceTimer)?

    /// - Parameters:
    ///   - queue: Where everything happens, the clipboard included.
    ///   - connect: Opens a line to the half that runs as root, or returns `nil` while it isn't there.
    init(
        pasteboard: any AgentPasteboard, queue: DispatchQueue, lookInterval: TimeInterval = 0.5, retryInterval: TimeInterval = 2,
        connect: @escaping () -> Int32? = { AgentSockets.connectToUnixSocket(path: AgentSockets.sessionSocketPath) }
    ) {
        self.pasteboard = pasteboard
        self.queue = queue
        self.connect = connect
        self.lookInterval = lookInterval
        self.retryInterval = retryInterval
        // What is on the clipboard when the session begins was copied before anyone shared it.
        seenChangeCount = pasteboard.changeCount
    }

    /// Starts sharing. Safe to call from anywhere.
    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            reachDaemon()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + lookInterval, repeating: lookInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.lookAtClipboard() }
            timer.resume()
            self.timer = timer
        }
    }

    // MARK: Private

    /// Connects to the half that runs as root, and keeps trying while it isn't there: it is started
    /// with the system, this half with a login, and either can be replaced by a newer one at any time.
    private func reachDaemon() {
        guard daemon == nil else { return }
        guard let descriptor = connect() else {
            queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in self?.reachDaemon() }
            return
        }
        let line = AgentLine(descriptor: descriptor, queue: queue)
        daemon = line
        line.onLine = { [weak self] bytes in self?.handle(bytes) }
        line.onEnd = { [weak self, weak line] in
            guard let self, let line, daemon === line else { return }
            daemon = nil
            queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in self?.reachDaemon() }
        }
        line.start()
    }

    private func handle(_ bytes: Data) {
        guard case .clipboard(let text) = GuestMessageCoding.message(HostMessage.self, from: bytes) else { return }
        if pasteboard.text != text {
            pasteboard.setText(text)
        }
        // Putting it there moved the counter. That was this agent's doing, and is no news for the Mac.
        seenChangeCount = pasteboard.changeCount
    }

    private func lookAtClipboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != seenChangeCount else { return }
        seenChangeCount = changeCount
        // Text that is too long for a message, and what isn't text at all, stays here.
        guard let daemon, let text = pasteboard.text, !text.isEmpty,
              let line = GuestMessageCoding.clipboardLine(text, as: AgentMessage.clipboard(text:))
        else { return }
        daemon.send(line)
    }
}
