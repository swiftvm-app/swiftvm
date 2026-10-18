import Foundation
import GuestChannel
import Testing
@testable import VMCore

/// The guest's end of a line to its agent, played by the test.
private final class AgentEnd: @unchecked Sendable {
    let descriptor: Int32
    private var framer = GuestMessageFramer()
    private var pending: [Data] = []

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func send(_ message: AgentMessage) {
        _ = ByteRelay.writeAll(ArraySlice(GuestMessageCoding.line(for: message)), to: descriptor)
    }

    /// The next line from the app, or `nil` once a second has gone by without one.
    func nextLine() -> String? {
        while pending.isEmpty {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 1000) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return nil }
            pending += (try? framer.receive(Data(buffer[0..<count]))) ?? []
        }
        return String(decoding: pending.removeFirst(), as: UTF8.self)
    }

    func hangUp() {
        close(descriptor)
    }
}

/// What the app hears of a guest's windows, for Seamless Mode.
@MainActor
@Suite struct GuestWindowsTests {
    private let windows = GuestWindowList(width: 1920, height: 1080, windows: [
        GuestWindow(id: 42, title: "Notepad", x: 10, y: 20, width: 800, height: 600, isFocused: true),
    ])

    /// An agent that offers Seamless Mode, and the guest's ends of the lines it is reached on.
    private func connectedAgent() async throws -> (GuestAgent, () -> [AgentEnd]) {
        let agent = GuestAgent()
        agent.retryInterval = .milliseconds(10)
        var ends: [AgentEnd] = []
        agent.start {
            var descriptors: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.EIO) }
            _ = fcntl(descriptors[1], F_SETNOSIGPIPE, 1)
            let end = AgentEnd(descriptor: descriptors[1])
            end.send(.hello(AgentHello(agent: "1.4", features: [GuestFeature.seamless])))
            ends.append(end)
            return FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        }
        #expect(await agent.waitUntilConnected(timeout: .seconds(5)))
        return (agent, { ends })
    }

    private func nextLine(from end: AgentEnd) async -> String? {
        await Task.detached { end.nextLine() }.value
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func theGuestsWindowsAreTakenOnlyWhileTheyAreAskedFor() async throws {
        let (agent, ends) = try await connectedAgent()
        defer { agent.stop() }
        let end = try #require(ends().first)
        #expect(await nextLine(from: end) == #"{"protocol":1,"type":"hello"}"#)

        // Not asked for: what the guest says of its windows is no news.
        end.send(.windows(windows))
        try await Task.sleep(for: .milliseconds(100))
        #expect(agent.windows == nil)

        #expect(agent.reportWindows(true))
        #expect(await nextLine(from: end) == #"{"enabled":true,"type":"seamless"}"#)
        end.send(.windows(windows))
        #expect(await waitFor { agent.windows == windows })

        // Window by window: brought to the front by the guest's own name for it, not as a request.
        #expect(agent.activateWindow(42))
        #expect(await nextLine(from: end) == #"{"type":"activate-window","window":42}"#)

        #expect(agent.reportWindows(false))
        #expect(agent.windows == nil)
        #expect(await nextLine(from: end) == #"{"enabled":false,"type":"seamless"}"#)
        end.send(.windows(windows))
        try await Task.sleep(for: .milliseconds(100))
        #expect(agent.windows == nil)
    }

    @Test func aClickWaitsToHearWhetherItIsOnATitleBar() async throws {
        let (agent, ends) = try await connectedAgent()
        defer { agent.stop() }
        let end = try #require(ends().first)
        #expect(await nextLine(from: end) == #"{"protocol":1,"type":"hello"}"#)

        // The answer goes to the question it repeats the number of.
        async let onTitleBar = agent.isTitleBar(of: 42, x: 300, y: 25)
        #expect(await nextLine(from: end) == #"{"request":1,"type":"hit-test","window":42,"x":300,"y":25}"#)
        end.send(.hit(GuestHit(request: 1, area: GuestHit.titleBar)))
        #expect(await onTitleBar)

        // An agent that doesn't answer in time doesn't keep the click: it goes to the guest as it is.
        agent.hitTestTimeout = .milliseconds(50)
        #expect(await agent.isTitleBar(of: 42, x: 300, y: 300) == false)
        #expect(await nextLine(from: end)?.contains(#""request":2"#) == true)

        // Dropped on the Mac, the guest's window is moved after it.
        #expect(agent.moveWindow(42, x: 500, y: 120))
        #expect(await nextLine(from: end) == #"{"type":"move-window","window":42,"x":500,"y":120}"#)
    }

    @Test func anAgentThatComesBackIsAskedForTheWindowsAgain() async throws {
        let (agent, ends) = try await connectedAgent()
        defer { agent.stop() }
        let first = try #require(ends().first)
        #expect(await nextLine(from: first) == #"{"protocol":1,"type":"hello"}"#)
        agent.reportWindows(true)
        #expect(await nextLine(from: first) == #"{"enabled":true,"type":"seamless"}"#)
        first.send(.windows(windows))
        #expect(await waitFor { agent.windows == windows })

        // The guest restarted: its windows are gone with its agent, and the agent that comes back is
        // asked for them without anyone asking again.
        first.hangUp()
        #expect(await waitFor { ends().count == 2 && agent.windows == nil })
        let second = ends()[1]
        #expect(await nextLine(from: second) == #"{"protocol":1,"type":"hello"}"#)
        #expect(await nextLine(from: second) == #"{"enabled":true,"type":"seamless"}"#)
    }
}
