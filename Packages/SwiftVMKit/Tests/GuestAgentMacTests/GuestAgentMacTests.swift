import CoreGraphics
import Foundation
import GuestChannel
import Testing
@testable import GuestAgentMac

/// A system that only writes down what it is asked to do.
private final class PretendSystem: AgentSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var done: [String] = []
    private var held = [GuestInterface(name: "en0", mac: "d2:1e:46:b8:05:2c", addresses: ["192.168.231.10"])]

    /// What the agent has done to the system, in order.
    var calls: [String] { lock.withLock { done } }

    func setInterfaces(_ interfaces: [GuestInterface]) {
        lock.withLock { held = interfaces }
    }

    func describe() -> GuestSystem {
        GuestSystem(id: "macos", name: "macOS", version: "27.0.1", prettyName: "macOS 27.0.1", build: "26A434", kernel: "27.0.0", architecture: "arm64")
    }

    func hostName() -> String? { "test-mac.local" }
    func interfaces() -> [GuestInterface] { lock.withLock { held } }

    func setClock(nanoseconds: Int64) throws {
        lock.withLock { done.append("clock \(nanoseconds)") }
    }

    /// How long the system takes over a time zone.
    var timeZoneDelay: TimeInterval {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }
    private var delay: TimeInterval = 0

    func setTimeZone(_ identifier: String) throws {
        guard TimeZoneName.isValid(identifier) else { throw AgentFailure("“\(identifier)” isn't the name of a time zone.") }
        Thread.sleep(forTimeInterval: timeZoneDelay)
        lock.withLock { done.append("time zone \(identifier)") }
    }

    func shutDown() throws {
        lock.withLock { done.append("shut down") }
    }

    /// The only account there is: whoever runs the tests.
    func account(named name: String?) throws -> AgentAccount {
        let account = AgentAccount(name: NSUserName(), user: getuid(), group: getgid(), home: NSHomeDirectory(), shell: "/bin/sh")
        guard name == nil || name == account.name else { throw AgentFailure("This Mac has no account named “\(name ?? "")”.") }
        return account
    }

    /// Commands run as they are, with nothing in between but the search for the program.
    func launch(_ command: [String], as account: AgentAccount) -> [String] {
        ["/usr/bin/env"] + command
    }
}

/// A desktop that only writes down what it is asked to do.
private final class PretendDesktop: AgentDesktop, @unchecked Sendable {
    private let lock = NSLock()
    private var done: [String] = []
    private var objection: String?

    /// What the agent has done with the desktop, in order.
    var calls: [String] { lock.withLock { done } }
    /// What the system says instead of letting the screen be recorded, as before someone allowed it.
    var refusal: String? {
        get { lock.withLock { objection } }
        set { lock.withLock { objection = newValue } }
    }

    func screenshot() throws -> Data {
        if let refusal { throw AgentFailure(refusal) }
        lock.withLock { done.append("screenshot") }
        return Data("a picture".utf8)
    }

    func pointer(_ request: GuestJob.Pointer) throws {
        lock.withLock { done.append("\(request.action.rawValue) \(request.x),\(request.y)") }
    }

    func keys(_ request: GuestJob.Keys) throws {
        lock.withLock { done.append("keys \(request.text ?? request.keys?.joined(separator: " ") ?? "")") }
    }

    func tree(_ request: GuestJob.Tree) throws -> Data {
        Data(#"{"applications":[],"truncated":false}"#.utf8)
    }

    func act(on request: GuestJob.Element) throws -> Data {
        lock.withLock { done.append("\(request.action.rawValue) \(request.element)") }
        return Data("{}".utf8)
    }
}

/// A clipboard that the test copies to and reads from.
private final class PretendPasteboard: AgentPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var contents: String?
    private var readCount = 0

    var changeCount: Int { lock.withLock { count } }
    var text: String? {
        lock.withLock {
            readCount += 1
            return contents
        }
    }
    /// How often the clipboard's contents were read, which is what a system could ask the user about.
    var reads: Int { lock.withLock { readCount } }
    /// What is on the clipboard, without that counting as a read.
    var current: String? { lock.withLock { contents } }

    func setText(_ text: String) {
        copy(text)
    }

    /// Someone copies something. `nil` is something that isn't text, such as a picture.
    func copy(_ text: String?) {
        lock.withLock {
            contents = text
            count += 1
        }
    }
}

/// The far end of a line to the agent, played by the test: a plain socket.
private struct FarEnd: @unchecked Sendable {
    let descriptor: Int32

    /// A connected pair: the end the agent gets, and the test's end.
    static func makeLine() -> (agent: Int32, test: FarEnd) {
        var descriptors: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        _ = fcntl(descriptors[1], F_SETNOSIGPIPE, 1)
        return (descriptors[0], FarEnd(descriptor: descriptors[1]))
    }

    func send<Message: Encodable>(_ message: Message) {
        send(GuestMessageCoding.line(for: message))
    }

    func send(_ bytes: Data) {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// The next message the agent sent, or `nil` if it hung up or nothing came within `timeout`.
    func receive<Message: Decodable & Sendable>(_ type: Message.Type, timeout: TimeInterval = 5) async -> Message? {
        await Task.detached {
            var line = Data()
            var byte: UInt8 = 0
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            while true {
                guard poll(&waiting, 1, Int32(timeout * 1000)) == 1, read(descriptor, &byte, 1) == 1 else { return nil }
                if byte == UInt8(ascii: "\n") { return GuestMessageCoding.message(type, from: line) }
                line.append(byte)
            }
        }.value
    }

    /// Whether the agent has hung up: reading reaches the end within `timeout`.
    func isHungUp(timeout: TimeInterval = 5) async -> Bool {
        await Task.detached {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            var byte: UInt8 = 0
            while poll(&waiting, 1, Int32(timeout * 1000)) == 1 {
                if read(descriptor, &byte, 1) <= 0 { return true }
            }
            return false
        }.value
    }

    /// The next frame of a job, or `nil` if the agent hung up or nothing came within `timeout`.
    func frame(timeout: TimeInterval = 5) async -> JobFrame? {
        await Task.detached {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, Int32(timeout * 1000)) == 1 else { return nil }
            return try? JobFrame.read(from: descriptor)
        }.value
    }

    func hangUp() {
        close(descriptor)
    }
}

/// Waits for something that happens a moment later, on the agent's queue.
private func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// The half that runs as root, against the app's own end of the line: this is where the agent and the
/// app meet without a virtual machine between them.
@Suite struct AgentDaemonTests {
    private let system = PretendSystem()
    private let queue = DispatchQueue(label: "agent under test")

    private func makeDaemon() -> AgentDaemon {
        let daemon = AgentDaemon(system: system, queue: queue)
        daemon.settleTime = 0.01
        return daemon
    }

    /// Has the daemon serve a new connection from the app, and returns the app's end of it.
    private func connectApp(to daemon: AgentDaemon) -> GuestAgentConnection {
        var descriptors: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        queue.sync { daemon.serveApp(on: descriptors[0]) }
        return GuestAgentConnection(handle: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
    }

    /// Has the daemon serve a new connection from a user's session, and returns the session's end of it.
    private func connectSession(to daemon: AgentDaemon) -> FarEnd {
        let (agent, test) = FarEnd.makeLine()
        queue.sync { daemon.serveSession(on: agent) }
        return test
    }

    @Test func theAgentAndTheAppUnderstandEachOther() async throws {
        let daemon = makeDaemon()
        let connection = connectApp(to: daemon)
        var messages = connection.messages.makeAsyncIterator()

        // It introduces itself and says what it holds, unasked.
        guard case .hello(let hello) = await messages.next() else {
            Issue.record("the agent didn't say hello first")
            return
        }
        #expect(hello.protocol == GuestProtocol.version)
        #expect(hello.agent == GuestProtocol.macAgentVersion)
        #expect(hello.system.displayName == "macOS 27.0.1")
        #expect(hello.system.build == "26A434")
        #expect(hello.hostName == "test-mac.local")
        #expect(hello.offers(GuestFeature.clipboard))
        #expect(hello.offers(GuestFeature.timeZone))
        #expect(await messages.next() == .addresses([GuestInterface(name: "en0", mac: "d2:1e:46:b8:05:2c", addresses: ["192.168.231.10"])]))

        connection.send(.hello(protocol: GuestProtocol.version))
        #expect(await connection.request { .setClock(id: $0, nanoseconds: 1_790_000_000_123_456_789) } == GuestRequestResult(id: 1, ok: true))
        #expect(await connection.request { .setTimeZone(id: $0, identifier: "Europe/Berlin") }?.ok == true)
        #expect(await connection.request { .shutDown(id: $0) }?.ok == true)
        #expect(system.calls == ["clock 1790000000123456789", "time zone Europe/Berlin", "shut down"])

        // What it can't do it refuses, and says why.
        let noTime = await connection.request { .setClock(id: $0, nanoseconds: -5) }
        #expect(noTime?.ok == false)
        #expect(noTime?.error?.isEmpty == false)
        let noZone = await connection.request { .setTimeZone(id: $0, identifier: "../../etc/passwd") }
        #expect(noZone?.ok == false)
        #expect(noZone?.error?.contains("time zone") == true)
        // macOS mounts shared folders by itself; nothing is mounted on the app's say-so.
        let noMount = await connection.request { .mountSharedFolders(id: $0, tag: "swiftvm", mountPoint: "/mnt/shared") }
        #expect(noMount?.ok == false)
        #expect(system.calls.count == 3)

        // Something from a later version of the app gets a no rather than silence, if it asks for an
        // answer, and is passed over if it doesn't.
        connection.send(line: Data(#"{"type":"rotate-display","id":900}"#.utf8 + [UInt8(ascii: "\n")]))
        connection.send(.unknown(type: "later"))
        connection.send(line: Data("not even json\n".utf8))
        let stillThere = await connection.request { .setClock(id: $0, nanoseconds: 1) }
        #expect(stillThere?.ok == true)
        connection.close()
    }

    @Test func aRequestFromALaterAppGetsANo() async {
        let daemon = makeDaemon()
        let (agent, app) = FarEnd.makeLine()
        defer { app.hangUp() }
        queue.sync { daemon.serveApp(on: agent) }
        guard case .hello = await app.receive(AgentMessage.self), case .addresses = await app.receive(AgentMessage.self) else {
            Issue.record("no greeting")
            return
        }
        app.send(Data(#"{"type":"rotate-display","id":900,"degrees":90}"#.utf8 + [UInt8(ascii: "\n")]))
        guard case .result(let result) = await app.receive(AgentMessage.self) else {
            Issue.record("no answer")
            return
        }
        #expect(result.id == 900)
        #expect(!result.ok)
        #expect(result.error?.contains("rotate-display") == true)
    }

    @Test func aNewConnectionTakesTheOldOnesPlace() async {
        // The app connects anew after a machine was suspended, without having hung up on the old line.
        let daemon = makeDaemon()
        let first = connectApp(to: daemon)
        var firstMessages = first.messages.makeAsyncIterator()
        guard case .hello = await firstMessages.next(), case .addresses = await firstMessages.next() else {
            Issue.record("no greeting on the first line")
            return
        }
        let second = connectApp(to: daemon)
        var secondMessages = second.messages.makeAsyncIterator()
        guard case .hello = await secondMessages.next(), case .addresses = await secondMessages.next() else {
            Issue.record("no greeting on the second line")
            return
        }
        // The first line is closed by the agent, the second one works.
        #expect(await firstMessages.next() == nil)
        #expect(await second.request { .setClock(id: $0, nanoseconds: 2) }?.ok == true)
        #expect(await first.request { .setClock(id: $0, nanoseconds: 3) } == nil)
        #expect(system.calls == ["clock 2"])
    }

    @Test func tellsTheAppWhenItsAddressesChange() async {
        let daemon = makeDaemon()
        let (agent, app) = FarEnd.makeLine()
        defer { app.hangUp() }
        queue.sync { daemon.serveApp(on: agent) }
        guard case .hello = await app.receive(AgentMessage.self), case .addresses = await app.receive(AgentMessage.self) else {
            Issue.record("no greeting")
            return
        }

        // The system says something changed. Nothing did that matters: no news for the app.
        queue.sync { daemon.addressesMayHaveChanged() }
        #expect(await app.receive(AgentMessage.self, timeout: 0.2) == nil)

        // The cable is pulled, and plugged in again with another address handed out. Several notices
        // in a row make one look.
        system.setInterfaces([])
        queue.sync {
            daemon.addressesMayHaveChanged()
            daemon.addressesMayHaveChanged()
        }
        #expect(await app.receive(AgentMessage.self) == .addresses([]))
        let moved = [GuestInterface(name: "en0", mac: "d2:1e:46:b8:05:2c", addresses: ["192.168.231.44", "fd00::44"])]
        system.setInterfaces(moved)
        queue.sync { daemon.addressesMayHaveChanged() }
        #expect(await app.receive(AgentMessage.self) == .addresses(moved))
        #expect(await app.receive(AgentMessage.self, timeout: 0.2) == nil)
    }

    @Test func passesCopiedTextBetweenTheAppAndTheSession() async {
        let daemon = makeDaemon()
        let (agent, app) = FarEnd.makeLine()
        defer { app.hangUp() }
        queue.sync { daemon.serveApp(on: agent) }
        guard case .hello = await app.receive(AgentMessage.self), case .addresses = await app.receive(AgentMessage.self) else {
            Issue.record("no greeting")
            return
        }
        // Something is copied on the Mac before anyone is logged in here. There is no clipboard to put
        // it on, and it isn't kept: by the time someone logs in it may be old, or no longer shared.
        app.send(HostMessage.clipboard(text: "copied early"))
        // Read something back, so that it has been taken in before the session begins.
        app.send(HostMessage.setClock(id: 1, nanoseconds: 5))
        guard case .result = await app.receive(AgentMessage.self) else {
            Issue.record("no answer")
            return
        }

        // Whoever logs in asks, through this half, for what is on the Mac's clipboard now.
        let session = connectSession(to: daemon)
        defer { session.hangUp() }
        #expect(await app.receive(AgentMessage.self) == .clipboardRequest)
        #expect(await session.receive(HostMessage.self, timeout: 0.2) == nil)
        app.send(HostMessage.clipboard(text: "on the Mac now"))
        #expect(await session.receive(HostMessage.self) == .clipboard(text: "on the Mac now"))

        // From then on it goes both ways, as it comes.
        app.send(HostMessage.clipboard(text: "more from the Mac"))
        #expect(await session.receive(HostMessage.self) == .clipboard(text: "more from the Mac"))
        session.send(AgentMessage.clipboard(text: "copied in the guest"))
        #expect(await app.receive(AgentMessage.self) == .clipboard(text: "copied in the guest"))

        // The session has nothing else to say to the app: it can't answer for the agent, or pass for it.
        session.send(AgentMessage.result(GuestRequestResult(id: 2, ok: true)))
        session.send(AgentMessage.hello(AgentHello(agent: "9.9")))
        session.send(AgentMessage.clipboardRequest)
        session.send(HostMessage.shutDown(id: 3))
        session.send(AgentMessage.clipboard(text: "still here"))
        #expect(await app.receive(AgentMessage.self) == .clipboard(text: "still here"))
        #expect(system.calls == ["clock 5"])
    }

    @Test func aSessionThatBeginsTakesThePlaceOfTheOneBefore() async {
        let daemon = makeDaemon()
        let (agent, app) = FarEnd.makeLine()
        defer { app.hangUp() }
        queue.sync { daemon.serveApp(on: agent) }
        guard case .hello = await app.receive(AgentMessage.self), case .addresses = await app.receive(AgentMessage.self) else {
            Issue.record("no greeting")
            return
        }
        let first = connectSession(to: daemon)
        defer { first.hangUp() }
        #expect(await app.receive(AgentMessage.self) == .clipboardRequest)
        app.send(HostMessage.clipboard(text: "for the first"))
        #expect(await first.receive(HostMessage.self) == .clipboard(text: "for the first"))

        // Someone else logs in, or the same user again. They ask anew, and are given nothing that was
        // sent for the one before.
        let second = connectSession(to: daemon)
        defer { second.hangUp() }
        #expect(await first.isHungUp())
        #expect(await app.receive(AgentMessage.self) == .clipboardRequest)
        #expect(await second.receive(HostMessage.self, timeout: 0.2) == nil)
        app.send(HostMessage.clipboard(text: "for whoever is at the screen"))
        #expect(await second.receive(HostMessage.self) == .clipboard(text: "for whoever is at the screen"))
    }

    @Test func asksTheAppWhenItComesBackForASessionThatIsStillWaiting() async {
        let daemon = makeDaemon()
        // Someone logs in while the app isn't there: nobody to ask.
        let session = connectSession(to: daemon)
        defer { session.hangUp() }
        session.send(AgentMessage.clipboard(text: "nobody to tell"))
        // Give the agent the moment it takes to read that, before the app turns up.
        try? await Task.sleep(for: .milliseconds(100))
        queue.sync {}

        // The app is asked as soon as it is. What was copied in the guest meanwhile went nowhere.
        let (agent, app) = FarEnd.makeLine()
        queue.sync { daemon.serveApp(on: agent) }
        guard case .hello = await app.receive(AgentMessage.self), case .addresses = await app.receive(AgentMessage.self) else {
            Issue.record("no greeting")
            return
        }
        #expect(await app.receive(AgentMessage.self) == .clipboardRequest)
        #expect(await app.receive(AgentMessage.self, timeout: 0.2) == nil)
        app.send(HostMessage.clipboard(text: "from the Mac"))
        #expect(await session.receive(HostMessage.self) == .clipboard(text: "from the Mac"))
        app.hangUp()

        // The session has what it asked for. When the app connects anew, after the machine was
        // suspended say, it isn't asked again: the guest may have copied something since.
        let (again, back) = FarEnd.makeLine()
        defer { back.hangUp() }
        queue.sync { daemon.serveApp(on: again) }
        guard case .hello = await back.receive(AgentMessage.self), case .addresses = await back.receive(AgentMessage.self) else {
            Issue.record("no greeting")
            return
        }
        #expect(await back.receive(AgentMessage.self, timeout: 0.2) == nil)
    }

    @Test func whatIsNotTheProtocolEndsTheLine() async {
        let daemon = makeDaemon()
        let (agent, rude) = FarEnd.makeLine()
        queue.sync { daemon.serveApp(on: agent) }
        // Half a megabyte without a line break. The agent doesn't wait for the line to end.
        let wasHungUpOn = await Task.detached { () -> Bool in
            defer { rude.hangUp() }
            let rubbish = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
            for _ in 0..<8 {
                rude.send(rubbish)
            }
            return await rude.isHungUp()
        }.value
        #expect(wasHungUpOn)

        // The next caller is served as if nothing had happened.
        let polite = connectApp(to: daemon)
        var messages = polite.messages.makeAsyncIterator()
        guard case .hello = await messages.next() else {
            Issue.record("the agent is gone")
            return
        }
        #expect(await polite.request { .setClock(id: $0, nanoseconds: 4) }?.ok == true)
    }
}

/// The half that runs in the user's session, with a clipboard the test copies to.
@Suite struct SessionAgentTests {
    private let pasteboard = PretendPasteboard()
    private let queue = DispatchQueue(label: "session under test")

    /// Hands the session agent the lines it asks for, one per attempt, for as long as there are any.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [Int32] = []
        private var count = 0

        var attempts: Int { lock.withLock { count } }

        /// Makes a line for the agent's next attempt and returns the daemon's end of it.
        func add() -> FarEnd {
            let (agent, test) = FarEnd.makeLine()
            lock.withLock { waiting.append(agent) }
            return test
        }

        func next() -> Int32? {
            lock.withLock {
                count += 1
                return waiting.isEmpty ? nil : waiting.removeFirst()
            }
        }
    }

    private func makeSession(_ lines: Lines) -> SessionAgent {
        SessionAgent(pasteboard: pasteboard, queue: queue, lookInterval: 0.01, retryInterval: 0.02) { lines.next() }
    }

    @Test func tellsWhatIsCopiedHere() async {
        // What is on the clipboard when the session begins was copied before anyone shared it.
        pasteboard.copy("copied before")
        let lines = Lines()
        let daemon = lines.add()
        defer { daemon.hangUp() }
        let session = makeSession(lines)
        session.start()
        #expect(await daemon.receive(AgentMessage.self, timeout: 0.2) == nil)
        #expect(pasteboard.reads == 0)

        pasteboard.copy("copied in the guest")
        #expect(await daemon.receive(AgentMessage.self) == .clipboard(text: "copied in the guest"))
        // While nothing is copied, the clipboard isn't read: looking at its counter is all it takes.
        let reads = pasteboard.reads
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pasteboard.reads == reads)

        // A picture stays here, and so does text that is too long for a message. What follows still goes.
        pasteboard.copy(nil)
        pasteboard.copy(String(repeating: "x", count: GuestProtocol.maximumLineLength))
        #expect(await daemon.receive(AgentMessage.self, timeout: 0.2) == nil)
        pasteboard.copy("short again")
        #expect(await daemon.receive(AgentMessage.self) == .clipboard(text: "short again"))
    }

    @Test func putsOnTheClipboardWhatWasCopiedOnTheMac() async {
        let lines = Lines()
        let daemon = lines.add()
        defer { daemon.hangUp() }
        let session = makeSession(lines)
        session.start()

        daemon.send(HostMessage.clipboard(text: "copied on the Mac"))
        #expect(await eventually { pasteboard.current == "copied on the Mac" })
        // That was the agent's own doing, and is no news for the Mac.
        #expect(await daemon.receive(AgentMessage.self, timeout: 0.2) == nil)

        // The same text again doesn't touch the clipboard, and still isn't sent back.
        let count = pasteboard.changeCount
        daemon.send(HostMessage.clipboard(text: "copied on the Mac"))
        daemon.send(HostMessage.setClock(id: 1, nanoseconds: 1))
        #expect(await daemon.receive(AgentMessage.self, timeout: 0.2) == nil)
        #expect(pasteboard.changeCount == count)

        // What the user copies afterwards is news again.
        pasteboard.copy("an answer")
        #expect(await daemon.receive(AgentMessage.self) == .clipboard(text: "an answer"))
    }

}

/// Both halves and the app's own end, wired up as they are in a guest.
@Suite struct AgentEndToEndTests {
    @Test func theClipboardGoesAllTheWayBothWays() async {
        let queue = DispatchQueue(label: "agent under test")
        let daemon = AgentDaemon(system: PretendSystem(), queue: queue)
        let pasteboard = PretendPasteboard()
        let session = SessionAgent(pasteboard: pasteboard, queue: queue, lookInterval: 0.01, retryInterval: 0.02) {
            var descriptors: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }
            // Called on the agent's queue, where the daemon lives too.
            daemon.serveSession(on: descriptors[0])
            return descriptors[1]
        }
        session.start()

        var descriptors: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        queue.sync { daemon.serveApp(on: descriptors[0]) }
        let app = GuestAgentConnection(handle: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
        var messages = app.messages.makeAsyncIterator()
        guard case .hello = await messages.next(), case .addresses = await messages.next() else {
            Issue.record("no greeting")
            return
        }

        let text = "Über “quotes”\n\ttab \u{1F642}"
        app.send(.clipboard(text: text))
        #expect(await eventually { pasteboard.current == text })

        pasteboard.copy("and back")
        // The session asked for the Mac's clipboard when it began, before or after the app was there.
        var next = await messages.next()
        if next == .clipboardRequest {
            next = await messages.next()
        }
        #expect(next == .clipboard(text: "and back"))
        withExtendedLifetime(session) {}
    }
}

@Suite struct MacSystemTests {
    @Test func saysWhatSystemThisIs() {
        // This Mac stands in for a guest: it is macOS too.
        let system = MacSystem().describe()
        #expect(system.id == "macos")
        #expect(system.name == "macOS")
        #expect(system.prettyName == "macOS \(system.version ?? "?")")
        #expect(system.version?.split(separator: ".").count ?? 0 >= 2)
        #expect(system.build?.isEmpty == false)
        #expect(system.kernel?.isEmpty == false)
        #expect(system.architecture == "arm64")
        #expect(MacSystem().hostName()?.isEmpty == false)
    }

    @Test func listsTheNetworkCardsThatHoldAnAddress() {
        for interface in NetworkInterfaces.current() {
            #expect(!interface.name.isEmpty)
            #expect(interface.mac.wholeMatch(of: /[0-9a-f]{2}(:[0-9a-f]{2}){5}/) != nil, "\(interface.mac)")
            #expect(!interface.addresses.isEmpty)
            for address in interface.addresses {
                // Nothing that only works on the link itself, or only in this system.
                #expect(!address.hasPrefix("169.254."), "\(address)")
                #expect(!address.lowercased().hasPrefix("fe80"), "\(address)")
                #expect(address != "127.0.0.1" && address != "::1")
                #expect(!address.contains("%"))
            }
        }
        #expect(NetworkInterfaces.current(limit: 0).isEmpty)
    }

    @Test func tellsTimeZoneNamesFromOtherThings() {
        for name in ["Europe/Berlin", "America/Argentina/Buenos_Aires", "UTC", "Etc/GMT+5", "US/Pacific", "America/Port-au-Prince"] {
            #expect(TimeZoneName.isValid(name), "\(name)")
        }
        for name in ["", "../etc/passwd", "Europe/../../etc", "/etc/localtime", "Europe/Berlin; reboot", "-settimezone", "Europe Berlin", "Zürich", String(repeating: "A", count: 65)] {
            #expect(!TimeZoneName.isValid(name), "\(name)")
        }
    }

    @Test func refusesATimeZoneThatIsNotOne() {
        // Refused before anything is run, which is all that can be tried without being root.
        #expect(throws: AgentFailure.self) { try MacSystem().setTimeZone("Not/AZone") }
        #expect(throws: AgentFailure.self) { try MacSystem().setTimeZone("../../etc/passwd") }
        // The zone the system is in already takes nothing to set.
        if let current = MacSystem.currentTimeZone() {
            #expect(throws: Never.self) { try MacSystem().setTimeZone(current) }
        }
    }

    @Test func runsACommandAndSaysWhatItSaidWhenItFails() {
        #expect(throws: Never.self) { try MacSystem.run("/usr/bin/true", [], timeout: 5) }
        #expect(throws: AgentFailure("nope")) { try MacSystem.run("/bin/sh", ["-c", "echo nope; exit 3"], timeout: 5) }
        #expect(throws: AgentFailure("false failed with status 1.")) { try MacSystem.run("/usr/bin/false", [], timeout: 5) }
        #expect(throws: AgentFailure("sleep didn't finish in 0 seconds.")) { try MacSystem.run("/bin/sleep", ["5"], timeout: 0.1) }
        #expect(throws: AgentFailure.self) { try MacSystem.run("/nonexistent/tool", [], timeout: 5) }
    }
}

@Suite struct AgentSocketTests {
    @Test func aSessionIsKnownByItsUser() throws {
        let path = "/tmp/swiftvm-agent-test-\(UInt32.random(in: 0...UInt32.max)).sock"
        defer { unlink(path) }
        #expect(AgentSockets.connectToUnixSocket(path: path) == nil)
        let listener = try AgentSockets.listenOnUnixSocket(path: path)
        defer { close(listener) }
        // Everyone may connect; who they are decides what happens next.
        var status = stat()
        #expect(stat(path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o666)

        let connection = try #require(AgentSockets.connectToUnixSocket(path: path))
        defer { close(connection) }
        let accepted = try #require(AgentSockets.acceptLocal(on: listener))
        defer { close(accepted.connection) }
        #expect(accepted.user == getuid())
        // On this Mac someone is logged in, or nobody is and the console is root's.
        #expect(AgentSockets.consoleUser() != nil)

        // A path that doesn't fit in a socket's address is refused rather than cut short.
        #expect(throws: (any Error).self) { try AgentSockets.listenOnUnixSocket(path: "/tmp/" + String(repeating: "x", count: 200)) }
    }

    @Test func theProgramSaysHowItIsCalledWhenItIsCalledWrongly() {
        #expect(AgentCommand.run(["--help"]) == 64)
        #expect(AgentCommand.run([]) == 64)
        #expect(AgentCommand.run(["daemon", "extra"]) == 64)
    }
}

/// Jobs for whoever drives the system from the Mac, against the Mac's own end of a job's connection.
@Suite struct AgentJobTests {
    private let system = PretendSystem()
    private let queue = DispatchQueue(label: "agent under test")

    /// Has the daemon take a job on a connection of its own, and returns the Mac's end of it.
    private func send(_ job: GuestJob, to daemon: AgentDaemon) -> FarEnd {
        let (agent, mac) = FarEnd.makeLine()
        daemon.serveJob(on: agent)
        mac.send(job)
        return mac
    }

    @Test func runsACommandAndSaysHowItEnded() async {
        let daemon = AgentDaemon(system: system, queue: queue)
        let script = "echo out; echo $GREETING >&2; cat; exit 3"
        let mac = send(.exec(.init(arguments: ["sh", "-c", script], environment: ["GREETING": "hello"])), to: daemon)
        defer { mac.hangUp() }
        #expect(await mac.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        // What the Mac sends is the command's input, and an empty frame the end of it.
        mac.send(JobFrame(.input, Data("typed".utf8)).encoded)
        mac.send(JobFrame(.input).encoded)

        var (printed, complained) = (Data(), Data())
        var end: JobEnd?
        while end == nil, let frame = await mac.frame() {
            switch frame.kind {
            case .output: printed.append(frame.payload)
            case .errorOutput: complained.append(frame.payload)
            case .end: end = frame.end
            case .input: break
            }
        }
        #expect(String(decoding: printed, as: UTF8.self) == "out\ntyped")
        #expect(String(decoding: complained, as: UTF8.self) == "hello\n")
        #expect(end == JobEnd(status: 3))
    }

    @Test(arguments: [false, true]) func aSlowReaderGetsAllTheOutput(standardError: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let finished = directory.appending(path: "finished")
        let daemon = AgentDaemon(system: system, queue: queue)
        let (agent, mac) = FarEnd.makeLine()
        defer { mac.hangUp() }
        var size: Int32 = 4096
        for descriptor in [agent, mac.descriptor] {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        daemon.serveJob(on: agent)
        let script = """
            if [ "$2" = stderr ]; then exec 1>&2; fi
            dd if=/dev/zero bs=8192 count=1 2>/dev/null
            sleep 0.2
            dd if=/dev/zero bs=8192 count=1 2>/dev/null
            : > "$1"
            """
        mac.send(GuestJob.exec(.init(arguments: ["sh", "-c", script, "output", finished.path, standardError ? "stderr" : "stdout"])))
        #expect(await mac.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        mac.send(JobFrame(.input).encoded)
        // The command has printed everything and can exit, but the first frame is still blocked on
        // this reader. Time spent sending must not cost it the bytes still waiting in the pipe.
        try #require(await eventually { FileManager.default.fileExists(atPath: finished.path) })
        try await Task.sleep(for: .seconds(CommandJob.outputGrace + 1))
        var printed = Data()
        var end: JobEnd?
        while end == nil, let frame = await mac.frame() {
            if frame.kind == (standardError ? .errorOutput : .output) {
                printed.append(frame.payload)
            }
            end = frame.end
        }
        #expect(printed == Data(repeating: 0, count: 16384))
        #expect(end == .success)
    }

    @Test func anIdleInheritedPipeDoesNotHoldTheJobOpen() async throws {
        let daemon = AgentDaemon(system: system, queue: queue)
        let mac = send(.exec(.init(arguments: ["sh", "-c", "sleep 30 & echo $!"])), to: daemon)
        defer { mac.hangUp() }
        #expect(await mac.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        mac.send(JobFrame(.input).encoded)
        let first = try #require(await mac.frame())
        let child = try #require(pid_t(String(decoding: first.payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGKILL) }
        #expect(await mac.frame(timeout: CommandJob.outputGrace + 3)?.end == .success)
        // Finishing normally is not cancellation: background work is left alone.
        #expect(kill(child, 0) == 0)
    }

    @Test func cancellationReachesChildrenAfterTheirParentExits() async throws {
        let daemon = AgentDaemon(system: system, queue: queue)
        let command = """
            POSIX::setsid() >= 0 || POSIX::setpgid(0, 0) == 0 || die "process group";
            pipe(my $ready, my $signal) or die "pipe";
            my $child = fork();
            defined($child) or die "fork";
            if ($child == 0) {
                close $ready;
                $SIG{TERM} = 'IGNORE';
                syswrite($signal, 'r');
                close $signal;
                sleep 15;
                exit 0;
            }
            close $signal;
            sysread($ready, my $byte, 1);
            $| = 1;
            print "$$ $child\\n";
            sleep 15;
            kill 9, $child;
            waitpid($child, 0);
            """
        let mac = send(.exec(.init(arguments: ["/usr/bin/perl", "-MPOSIX", "-e", command])), to: daemon)
        defer { mac.hangUp() }
        #expect(await mac.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        let first = try #require(await mac.frame())
        let processes = String(decoding: first.payload, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        try #require(processes.count == 2)
        let (parent, child) = (processes[0], processes[1])
        defer {
            kill(child, SIGKILL)
            kill(parent, SIGKILL)
        }
        #expect(getpgid(child) == parent)
        // The parent takes TERM, but its child is already ignoring it when the Mac hangs up.
        shutdown(mac.descriptor, SHUT_RDWR)
        #expect(await eventually { kill(parent, 0) != 0 })
        #expect(await eventually(within: .seconds(CommandJob.killGrace + 2)) { kill(child, 0) != 0 })
    }

    @Test func aCommandIsCalledOffWhenTheMacHangsUp() async throws {
        let daemon = AgentDaemon(system: system, queue: queue)
        let mac = send(.exec(.init(arguments: ["sh", "-c", "echo $$; exec sleep 600"])), to: daemon)
        #expect(await mac.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        let first = try #require(await mac.frame())
        let process = try #require(pid_t(String(decoding: first.payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(process, 0) == 0)
        // Whoever wanted the command is gone.
        mac.hangUp()
        #expect(await eventually { kill(process, 0) != 0 })
    }

    @Test func inputThatKeepsComingAfterItsEndIsLetGo() async {
        // The Mac says the input is over and sends more all the same, to a command that has ended
        // long since: a line that is torn looks like this. The agent must still be there afterwards.
        let daemon = AgentDaemon(system: system, queue: queue)
        let mac = send(.exec(.init(arguments: ["sh", "-c", "exit 1"])), to: daemon)
        #expect(await mac.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        mac.send(JobFrame(.input).encoded)
        for _ in 0..<64 {
            mac.send(JobFrame(.input, Data(repeating: 0, count: 4096)).encoded)
        }
        var end: JobEnd?
        while end == nil, let frame = await mac.frame() {
            end = frame.end
        }
        #expect(end == JobEnd(status: 1))
        mac.hangUp()

        let next = send(.exec(.init(arguments: ["true"])), to: daemon)
        defer { next.hangUp() }
        #expect(await next.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        #expect(await next.frame()?.end == .success)
    }

    @Test func refusesWhatItCannotRun() async {
        let daemon = AgentDaemon(system: system, queue: queue)
        let stranger = send(.exec(.init(arguments: ["true"], user: "nobody-here")), to: daemon)
        defer { stranger.hangUp() }
        let answer = await stranger.receive(GuestJobAnswer.self)
        #expect(answer?.ok == false)
        #expect(answer?.error?.contains("nobody-here") == true)

        // A job from a later version of the app gets a no, not silence.
        let later = send(.unknown(type: "record-screen"), to: daemon)
        defer { later.hangUp() }
        #expect(await later.receive(GuestJobAnswer.self)?.error?.contains("record-screen") == true)
    }

    @Test func theScreenIsNobodysWhileNobodyIsLoggedIn() async {
        let daemon = AgentDaemon(system: system, queue: queue)
        let mac = send(.screenshot, to: daemon)
        defer { mac.hangUp() }
        let answer = await mac.receive(GuestJobAnswer.self)
        #expect(answer?.ok == false)
        #expect(answer?.error?.contains("logged in") == true)
    }

    @Test func aJobForTheScreenIsDoneInTheUsersSession() async {
        // Both halves, wired up as they are in a guest: the Mac asks the half that runs as root, and
        // the half in the user's session answers.
        let daemon = AgentDaemon(system: system, queue: queue)
        let desktop = PretendDesktop()
        let session = SessionAgent(
            pasteboard: PretendPasteboard(), queue: queue, desktop: desktop, lookInterval: 0.01, retryInterval: 0.02,
            connect: {
                var descriptors: [Int32] = [0, 0]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }
                // Called on the agent's queue, where the daemon lives too.
                daemon.serveSession(on: descriptors[0])
                return descriptors[1]
            },
            connectForJob: {
                var descriptors: [Int32] = [0, 0]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }
                daemon.serveSessionJob(on: descriptors[0])
                return descriptors[1]
            }
        )
        session.start()
        // The session's half has to have reached the other one before there is anyone to hand a job to.
        queue.sync {}

        let picture = send(.screenshot, to: daemon)
        defer { picture.hangUp() }
        #expect(await picture.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        #expect(await picture.frame() == JobFrame(.output, Data("a picture".utf8)))
        #expect(await picture.frame()?.end == .success)

        let click = send(.pointer(.init(action: .click, x: 40, y: 50)), to: daemon)
        defer { click.hangUp() }
        #expect(await click.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        #expect(await click.frame()?.end == .success)
        #expect(desktop.calls == ["screenshot", "click 40,50"])

        // What macOS hasn't allowed ends the job with what the desktop has to say about it.
        desktop.refusal = "macOS hasn't let the guest tools record this Mac's screen yet."
        let refused = send(.screenshot, to: daemon)
        defer { refused.hangUp() }
        #expect(await refused.receive(GuestJobAnswer.self) == GuestJobAnswer(ok: true))
        #expect(await refused.frame()?.end == .failure("macOS hasn't let the guest tools record this Mac's screen yet."))
        withExtendedLifetime(session) {}
    }
}

@Suite struct MacKeyboardTests {
    @Test func readsAPressAsItIsWritten() throws {
        let command = MacKeyboard.Modifier(key: 55, flag: CGEventFlags.maskCommand.rawValue)
        let shift = MacKeyboard.Modifier(key: 56, flag: CGEventFlags.maskShift.rawValue)
        #expect(try MacKeyboard.press(for: "Return") == .init(key: 36, modifiers: []))
        #expect(try MacKeyboard.press(for: "cmd+space") == .init(key: 49, modifiers: [command]))
        // A letter in a shortcut is the key, whichever way it is written. A sign that takes Shift brings it.
        #expect(try MacKeyboard.press(for: "CMD+Shift+T") == .init(key: 17, modifiers: [command, shift]))
        #expect(try MacKeyboard.press(for: "cmd+?") == .init(key: 44, modifiers: [command, shift]))
        // The plus sign is a key too, alone or held with others. A key that is only held is a press as well.
        #expect(try MacKeyboard.press(for: "+") == .init(key: 24, modifiers: [shift]))
        #expect(try MacKeyboard.press(for: "cmd++") == .init(key: 24, modifiers: [command, shift]))
        #expect(try MacKeyboard.press(for: "super") == .init(key: nil, modifiers: [command]))
        #expect(throws: AgentFailure.self) { try MacKeyboard.press(for: "ctrl+banana") }
        #expect(throws: AgentFailure.self) { try MacKeyboard.press(for: "banana+c") }
    }
}
