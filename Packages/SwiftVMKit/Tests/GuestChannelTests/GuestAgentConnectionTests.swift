import Foundation
import Testing
@testable import GuestChannel

/// The agent's end of a line, played by the test: a plain socket.
struct AgentEnd: @unchecked Sendable {
    let descriptor: Int32

    /// A connected pair: the handle for the app's side, and the agent's end.
    static func makeLine() -> (handle: FileHandle, agent: AgentEnd) {
        var descriptors: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        _ = fcntl(descriptors[1], F_SETNOSIGPIPE, 1)
        return (FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true), AgentEnd(descriptor: descriptors[1]))
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }

    func send(_ message: AgentMessage) {
        send(String(decoding: GuestMessageCoding.line(for: message), as: UTF8.self))
    }

    /// The next line the app sent, or `nil` if it hung up or nothing came within `timeout`.
    func receiveLine(timeout: TimeInterval = 5) async -> String? {
        await Task.detached {
            var line: [UInt8] = []
            var byte: UInt8 = 0
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            while true {
                guard poll(&waiting, 1, Int32(timeout * 1000)) == 1, read(descriptor, &byte, 1) == 1 else { return nil }
                if byte == UInt8(ascii: "\n") { return String(decoding: line, as: UTF8.self) }
                line.append(byte)
            }
        }.value
    }

    func receive(timeout: TimeInterval = 5) async -> HostMessage? {
        guard let line = await receiveLine(timeout: timeout) else { return nil }
        return GuestMessageCoding.message(HostMessage.self, from: Data(line.utf8))
    }

    /// Whether the app has hung up: reading reaches the end within `timeout`.
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

@Suite struct GuestAgentConnectionTests {
    @Test func handsOutTheAgentsMessagesInOrder() async {
        let (handle, agent) = AgentEnd.makeLine()
        defer { agent.hangUp() }
        let connection = GuestAgentConnection(handle: handle)
        let hello = AgentMessage.hello(AgentHello(agent: "1.0", system: GuestSystem(prettyName: "Ubuntu 26.04.1 LTS")))
        let addresses = AgentMessage.addresses([GuestInterface(name: "enp0s1", mac: "02:00:00:00:00:01", addresses: ["192.168.232.11"])])
        agent.send(hello)
        // Something that isn't a message is skipped; what follows it still counts.
        agent.send("not json\n")
        agent.send(#"{"type":"clipboard"}"# + "\n")
        agent.send(addresses)

        var received: [AgentMessage] = []
        for await message in connection.messages {
            received.append(message)
            if received.count == 3 { break }
        }
        #expect(received == [hello, .unknown(type: "clipboard"), addresses])
    }

    @Test func aRequestGetsItsOwnAnswer() async {
        let (handle, agent) = AgentEnd.makeLine()
        defer { agent.hangUp() }
        let connection = GuestAgentConnection(handle: handle)

        async let clock = connection.request { .setClock(id: $0, nanoseconds: 42) }
        async let mount = connection.request { .mountSharedFolders(id: $0, tag: "swiftvm", mountPoint: "/mnt/shared") }
        var requests: [HostMessage] = []
        for _ in 0..<2 {
            if let request = await agent.receive() { requests.append(request) }
        }
        // Answered the other way round, each answer still reaches the one who asked.
        for request in requests.reversed() {
            switch request {
            case .setClock(let id, _): agent.send(.result(GuestRequestResult(id: id, ok: true)))
            case .mountSharedFolders(let id, _, _): agent.send(.result(GuestRequestResult(id: id, ok: false, error: "no such device")))
            default: Issue.record("unexpected \(request)")
            }
        }
        #expect(await clock?.ok == true)
        #expect(await mount?.ok == false)
        #expect(await mount?.error == "no such device")
        #expect(requests.count == 2)
    }

    @Test func aRequestNobodyAnswersGivesUp() async {
        let (handle, agent) = AgentEnd.makeLine()
        defer { agent.hangUp() }
        let connection = GuestAgentConnection(handle: handle)
        let started = ContinuousClock.now
        let answer = await connection.request(timeout: .milliseconds(100)) { .shutDown(id: $0) }
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
        // An answer that turns up afterwards is nobody's, and does no harm.
        agent.send(.result(GuestRequestResult(id: 1, ok: true)))
        agent.send(.addresses([]))
        var iterator = connection.messages.makeAsyncIterator()
        #expect(await iterator.next() == .addresses([]))
    }

    @Test func theAgentHangingUpEndsEverything() async {
        let (handle, agent) = AgentEnd.makeLine()
        let connection = GuestAgentConnection(handle: handle)
        async let answer = connection.request(timeout: .seconds(30)) { .shutDown(id: $0) }
        _ = await agent.receive()
        agent.send(.addresses([]))
        agent.hangUp()

        var received: [AgentMessage] = []
        for await message in connection.messages { received.append(message) }
        // What the agent said before it left still arrives.
        #expect(received == [.addresses([])])
        #expect(await answer == nil)
        #expect(connection.send(.hello(protocol: 1)) == false)
        #expect(await connection.request { .shutDown(id: $0) } == nil)
    }

    @Test func closingHangsUpOnTheAgent() async {
        let (handle, agent) = AgentEnd.makeLine()
        defer { agent.hangUp() }
        let connection = GuestAgentConnection(handle: handle)
        async let answer = connection.request(timeout: .seconds(30)) { .shutDown(id: $0) }
        _ = await agent.receive()
        connection.close()
        connection.close()
        #expect(await answer == nil)
        #expect(await agent.isHungUp())
        for await _ in connection.messages { Issue.record("a closed line has nothing more to say") }
    }

    @Test func lettingGoOfTheConnectionHangsUpToo() async {
        let (handle, agent) = AgentEnd.makeLine()
        defer { agent.hangUp() }
        do {
            let connection = GuestAgentConnection(handle: handle)
            connection.send(.hello(protocol: 1))
        }
        #expect(await agent.receive() == .hello(protocol: 1))
        #expect(await agent.isHungUp())
    }

    @Test func somethingThatIsNotAnAgentIsHungUpOn() async {
        let (handle, agent) = AgentEnd.makeLine()
        defer { agent.hangUp() }
        let connection = GuestAgentConnection(handle: handle)
        // A megabyte without a line break isn't the protocol.
        let writer = Task.detached { agent.send(String(repeating: "x", count: 1 << 20)) }
        for await _ in connection.messages { Issue.record("nothing in there was a message") }
        // The writer is cut off by the hang-up. Its descriptor is only closed once it has noticed.
        await writer.value
        #expect(await agent.isHungUp())
    }

    @Test func anAgentThatTalksFasterThanItIsHeardLosesItsOldestWords() async {
        let (handle, agent) = AgentEnd.makeLine()
        let connection = GuestAgentConnection(handle: handle)
        // Nobody reads while these arrive, three times as many as are kept.
        let count = GuestAgentConnection.backlogLimit * 3
        for number in 1...count {
            agent.send(.addresses([GuestInterface(name: "eth\(number)", mac: "02:00:00:00:00:01", addresses: [])]))
        }
        agent.hangUp()
        // All of it has been taken in once the end of the line has been read. Only then does anyone listen.
        while !connection.isClosedNow {
            try? await Task.sleep(for: .milliseconds(5))
        }

        var names: [String] = []
        for await message in connection.messages {
            if case .addresses(let interfaces) = message { names.append(interfaces[0].name) }
        }
        // What is left is the newest, in order, up to the last one.
        #expect(names.count == GuestAgentConnection.backlogLimit)
        #expect(names.last == "eth\(count)")
        #expect(names.first == "eth\(count - GuestAgentConnection.backlogLimit + 1)")
    }

    @Test func anAgentThatStopsListeningIsGivenUpOn() async {
        let (handle, agent) = AgentEnd.makeLine()
        defer { agent.hangUp() }
        let connection = GuestAgentConnection(handle: handle)
        // Nobody reads at the other end: sooner or later a message doesn't fit any more.
        var sent = 0
        while connection.send(.mountSharedFolders(id: sent, tag: "swiftvm", mountPoint: String(repeating: "/x", count: 2000))) {
            sent += 1
            guard sent < 100_000 else {
                Issue.record("the line never filled up")
                return
            }
        }
        #expect(sent > 0)
        for await _ in connection.messages {}
        #expect(connection.send(.hello(protocol: 1)) == false)
    }
}
