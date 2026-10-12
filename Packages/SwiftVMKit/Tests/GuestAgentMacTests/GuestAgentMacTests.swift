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
