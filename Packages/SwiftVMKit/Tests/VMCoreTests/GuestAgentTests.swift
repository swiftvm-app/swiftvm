import AppKit
import Foundation
import GuestChannel
import Testing
@testable import VMCore

/// The agent in a guest, played by the test, at the other end of one line the machine has opened.
private final class FakeAgent: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var messages: [HostMessage] = []
    private var isHungUp = false
    private var hasBeenHungUpOn = false
    /// What to answer a request with: `true` or `false`, or `nil` to say nothing at all.
    private let answer: @Sendable (HostMessage) -> Bool?

    init(descriptor: Int32, hello: AgentHello?, interfaces: [GuestInterface], answer: @escaping @Sendable (HostMessage) -> Bool?) {
        self.descriptor = descriptor
        self.answer = answer
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        if let hello {
            send(.hello(hello))
            send(.addresses(interfaces))
        }
        Thread.detachNewThread { [self] in listen() }
    }

    /// Everything the app has sent on this line so far.
    var received: [HostMessage] { lock.withLock { messages } }
    /// Whether the app has closed the line.
    var wasHungUpOn: Bool { lock.withLock { hasBeenHungUpOn } }

    func send(_ message: AgentMessage) {
        let line = GuestMessageCoding.line(for: message)
        lock.withLock {
            guard !isHungUp else { return }
            line.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    func hangUp() {
        lock.withLock {
            guard !isHungUp else { return }
            isHungUp = true
            // Wakes the reader, which then closes the descriptor.
            shutdown(descriptor, SHUT_RDWR)
        }
    }

    private func listen() {
        var framer = GuestMessageFramer()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            for line in (try? framer.receive(Data(buffer[0..<count]))) ?? [] {
                guard let message = GuestMessageCoding.message(HostMessage.self, from: line) else { continue }
                lock.withLock { messages.append(message) }
                let id: Int? = switch message {
                case .setClock(let id, _), .mountSharedFolders(let id, _, _), .shutDown(let id): id
                case .hello, .unknown: nil
                }
                if let id, let isOK = answer(message) {
                    send(.result(GuestRequestResult(id: id, ok: isOK, error: isOK ? nil : "no")))
                }
            }
        }
        lock.withLock {
            hasBeenHungUpOn = !isHungUp
            isHungUp = true
        }
        close(descriptor)
    }
}

/// Counts from one, from any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// A backend whose guest has an agent, or doesn't.
@MainActor
private final class AgentBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    var stopRequests = 0

    /// What the guest's agent says about itself. `nil` for something on the port that never says hello.
    var hello: AgentHello? = AgentHello(
        agent: "1.0",
        system: GuestSystem(id: "ubuntu", name: "Ubuntu", version: "26.04", prettyName: "Ubuntu 26.04.1 LTS", kernel: "7.0.0-34-generic")
    )
    var interfaces = [GuestInterface(name: "enp0s1", mac: "02:00:00:00:00:01", addresses: ["192.168.230.10", "fd00::10"])]
    /// Whether anything answers on the agent's port.
    var hasAgent = true
    var answer: @Sendable (HostMessage) -> Bool? = { _ in true }
    /// The ports the machine has tried to connect to, in order.
    var attempts: [UInt32] = []
    /// The agent's end of every line that was opened, oldest first.
    var agents: [FakeAgent] = []

    func connectToGuest(port: UInt32) async throws -> FileHandle {
        attempts.append(port)
        guard hasAgent else { throw POSIXError(.ECONNRESET) }
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.EMFILE) }
        agents.append(FakeAgent(descriptor: descriptors[1], hello: hello, interfaces: interfaces, answer: answer))
        return FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    }

    func start(options: VMStartOptions) async throws {}
    func requestStop() throws { stopRequests += 1 }
    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws { try Data("memory".utf8).write(to: url) }
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func invalidate() {}
}

@MainActor
private final class AgentProvider: VMBackendProvider {
    let backend = AgentBackend()

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend { backend }
    func backendDidStop(for machine: VirtualMachine) {}
}

@MainActor
@Suite struct GuestAgentTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
    private let provider = AgentProvider()
    private var backend: AgentBackend { provider.backend }

    /// A machine whose attempts to reach its agent follow each other quickly.
    private func makeMachine(family: GuestFamily = .linux, setUpBySwiftVM: Bool = true) throws -> VirtualMachine {
        let configuration = VMConfiguration(
            name: "Box", os: GuestOS(family: family, productName: family == .linux ? "Ubuntu 26.04 LTS" : nil),
            cpuCount: 2, memorySize: 4 << 30, disks: [],
            networkInterfaces: [NetworkInterfaceConfiguration(macAddress: "02:00:00:00:00:01", ipv4Address: "192.168.230.10")],
            installation: InstallationConfiguration(attachesSeedImage: setUpBySwiftVM)
        )
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        machine.isHostLocked = { false }
        machine.agent.retryInterval = .milliseconds(10)
        machine.agent.patientRetryInterval = .milliseconds(10)
        return machine
    }

    /// Waits for something that happens a moment later, on another thread or in another task.
    private func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func clockRequests(of agent: FakeAgent) -> [Int64] {
        agent.received.compactMap { if case .setClock(_, let nanoseconds) = $0 { nanoseconds } else { nil } }
    }

    @Test func holdsOnToAnAgentThatAnswers() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        var reports = 0
        machine.onGuestAddressesChange = { _ in reports += 1 }
        #expect(!machine.agent.isConnected)

        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        #expect(backend.attempts == [GuestProtocol.agentPort])
        #expect(machine.agent.version == "1.0")
        #expect(machine.agent.kernel == "7.0.0-34-generic")
        // The app introduces itself too.
        #expect(await eventually { backend.agents[0].received.first == .hello(protocol: GuestProtocol.version) })

        // What the guest says it is replaces what the catalog said, also on disk.
        #expect(machine.configuration.os.productName == "Ubuntu 26.04.1 LTS")
        #expect(machine.configuration.os.distribution == "ubuntu")
        #expect(try machine.bundle.loadConfiguration().os.productName == "Ubuntu 26.04.1 LTS")

        // Its addresses are those of the network card that is asked about, however the address is written.
        #expect(await eventually { !machine.agent.interfaces.isEmpty })
        #expect(machine.agent.addresses(ofInterface: "02:00:00:00:00:01") == ["192.168.230.10", "fd00::10"])
        #expect(machine.agent.addresses(ofInterface: "2:0:0:0:0:1") == ["192.168.230.10", "fd00::10"])
        #expect(machine.agent.addresses(ofInterface: "02:00:00:00:00:02").isEmpty)
        #expect(machine.agent.addresses(ofInterface: "nonsense").isEmpty)
        #expect(machine.agent.addresses == ["192.168.230.10", "fd00::10"])
        #expect(reports == 1)

        // A guest that changes its address says so, and the machine passes it on.
        backend.agents[0].send(.addresses([GuestInterface(name: "enp0s1", mac: "02:00:00:00:00:01", addresses: ["192.168.230.77"])]))
        #expect(await eventually { machine.agent.addresses(ofInterface: "02:00:00:00:00:01") == ["192.168.230.77"] })
        #expect(reports == 2)
        // Saying the same again is no news.
        backend.agents[0].send(.addresses([GuestInterface(name: "enp0s1", mac: "02:00:00:00:00:01", addresses: ["192.168.230.77"])]))
        backend.agents[0].send(.addresses([]))
        #expect(await eventually { machine.agent.interfaces.isEmpty })
        #expect(reports == 3)

        // A cold start leaves the guest's clock alone, and a guest that mounts its shared folders
        // itself isn't asked to.
        #expect(backend.agents[0].received == [.hello(protocol: GuestProtocol.version)])
        #expect(!machine.hasAgentMountedSharedFolders)
    }

    @Test func aStoppedGuestHasNoAgent() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        #expect(await eventually { !machine.agent.interfaces.isEmpty })
        var reports = 0
        machine.onGuestAddressesChange = { _ in reports += 1 }

        await machine.forceStop()
        #expect(machine.state == .stopped)
        #expect(!machine.agent.isConnected)
        #expect(machine.agent.version == nil)
        #expect(machine.agent.interfaces.isEmpty)
        #expect(reports == 1)
        // The line is hung up, and nobody reaches for an agent that can't be there.
        #expect(await eventually { backend.agents[0].wasHungUpOn })
        let attempts = backend.attempts.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.attempts.count == attempts)
        #expect(await machine.agent.setClock() == false)
        #expect(await machine.agent.waitUntilConnected(timeout: .milliseconds(50)) == false)
        // What it said about its system stays known.
        #expect(machine.configuration.os.productName == "Ubuntu 26.04.1 LTS")
    }

    @Test func keepsAskingAGuestThatHasNoAgentYet() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        backend.hasAgent = false
        await machine.start()
        #expect(machine.state == .running)
        // It is soon clear that nothing answers, and nobody has to wait out the whole time to learn it.
        let started = ContinuousClock.now
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(30)) == false)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await eventually { backend.attempts.count >= 3 })
        #expect(!machine.agent.isConnected)
        #expect(machine.configuration.os.productName == "Ubuntu 26.04 LTS")

        // The guest tools are installed, or the guest has got far enough in its startup.
        backend.hasAgent = true
        #expect(await eventually { machine.agent.isConnected })
        #expect(await machine.agent.waitUntilConnected(timeout: .milliseconds(10)))
        let attempts = backend.attempts.count
        try await Task.sleep(for: .milliseconds(100))
        // With an agent on the line there is nothing more to try.
        #expect(backend.attempts.count == attempts)
        await machine.forceStop()
    }

    @Test func findsAnAgentAgainThatWentAway() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))

        // The guest restarts by itself, or its agent is updated: the line drops and comes back.
        backend.hello?.agent = "1.1"
        backend.agents[0].hangUp()
        #expect(await eventually { backend.agents.count == 2 && machine.agent.version == "1.1" })
        #expect(machine.state == .running)
        await machine.forceStop()
    }

    @Test func hangsUpOnSomethingThatIsNotAnAgent() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        machine.agent.helloTimeout = .milliseconds(50)
        backend.hello = nil
        await machine.start()
        #expect(await eventually { backend.agents.count >= 2 })
        #expect(backend.agents[0].wasHungUpOn)
        #expect(!machine.agent.isConnected)
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(30)) == false)
        await machine.forceStop()
    }

    @Test func aGuestThatCannotHaveAnAgentIsNotAsked() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(family: .macOS)
        await machine.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.attempts.isEmpty)
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(30)) == false)
        await machine.forceStop()
    }

    @Test func setsTheClockOfAGuestThatWasSuspended() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        await machine.suspend()
        #expect(machine.state == .suspended)
        #expect(clockRequests(of: backend.agents[0]).isEmpty)

        // Resumed, the guest believes it is still the moment it was suspended. Its agent is told better
        // as soon as it is back on the line.
        let before = GuestProtocol.currentTimeInNanoseconds()
        await machine.start()
        #expect(await eventually { backend.agents.count == 2 && clockRequests(of: backend.agents[1]).count == 1 })
        let time = try #require(clockRequests(of: backend.agents[1]).first)
        #expect(time >= before && time <= GuestProtocol.currentTimeInNanoseconds())
        // Once is enough: an agent that reconnects during the same run isn't told again.
        backend.agents[1].hangUp()
        #expect(await eventually { backend.agents.count == 3 && machine.agent.isConnected })
        try await Task.sleep(for: .milliseconds(50))
        #expect(clockRequests(of: backend.agents[2]).isEmpty)
        await machine.forceStop()
    }

    @Test func setsTheClockWhenTheAgentOnlyTurnsUpLater() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        backend.hasAgent = false
        await machine.start()
        await machine.suspend()
        await machine.start()
        #expect(machine.state == .running)
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(1)) == false)

        // Its clock is as stale an hour later as it was at once.
        backend.hasAgent = true
        #expect(await eventually { backend.agents.count == 1 && clockRequests(of: backend.agents[0]).count == 1 })
        await machine.forceStop()
    }

    @Test func setsTheClockOfAGuestThatWasPaused() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        await machine.pause()
        #expect(machine.state == .paused)
        await machine.resume()
        #expect(machine.state == .running)
        // The line stayed open; the clock that stood still is set over it, once.
        #expect(await eventually { clockRequests(of: backend.agents[0]).count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(clockRequests(of: backend.agents[0]).count == 1)
        #expect(backend.agents.count == 1)
        await machine.forceStop()
    }

    @Test func setsTheClockAgainWhenTheGuestStoodStillWhileItWasBeingSet() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        // The agent takes its time over the first request, long enough for the guest to be paused and
        // carry on once more. The time it was sent is stale by then.
        let firstAnswer = DispatchSemaphore(value: 0)
        let requests = Counter()
        backend.answer = { message in
            if case .setClock = message, requests.next() == 1 {
                firstAnswer.wait()
            }
            return true
        }
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        await machine.pause()
        await machine.resume()
        #expect(await eventually { clockRequests(of: backend.agents[0]).count == 1 })
        await machine.pause()
        await machine.resume()
        firstAnswer.signal()

        #expect(await eventually { clockRequests(of: backend.agents[0]).count == 2 })
        let times = clockRequests(of: backend.agents[0])
        #expect(times[1] > times[0])
        try await Task.sleep(for: .milliseconds(50))
        #expect(clockRequests(of: backend.agents[0]).count == 2)
        await machine.forceStop()
    }

    @Test func mountsSharedFoldersInAGuestThatDoesNotDoItItself() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(setUpBySwiftVM: false)
        #expect(!machine.configuration.mountsSharedFoldersAutomatically)
        await machine.start()
        #expect(await eventually { machine.hasAgentMountedSharedFolders })
        #expect(backend.agents[0].received.contains(
            .mountSharedFolders(id: 1, tag: GuestIntegration.sharedFoldersTag, mountPoint: GuestIntegration.sharedFoldersMountPoint)
        ))

        // That is over when the guest stops, and done again when it next runs.
        await machine.forceStop()
        #expect(!machine.hasAgentMountedSharedFolders)
        await machine.start()
        #expect(await eventually { machine.hasAgentMountedSharedFolders && backend.agents.count == 2 })
        await machine.forceStop()
    }

    @Test func mountsSharedFoldersAgainAfterTheGuestRestartedByItself() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(setUpBySwiftVM: false)
        await machine.start()
        #expect(await eventually { machine.hasAgentMountedSharedFolders })

        // `sudo reboot` in the guest: the machine keeps running, the agent goes and comes back, and
        // nothing is mounted in the system that has come up.
        backend.agents[0].hangUp()
        #expect(await eventually { backend.agents.count == 2 })
        #expect(await eventually { machine.hasAgentMountedSharedFolders })
        #expect(backend.agents[1].received.contains(
            .mountSharedFolders(id: 1, tag: GuestIntegration.sharedFoldersTag, mountPoint: GuestIntegration.sharedFoldersMountPoint)
        ))
        #expect(machine.startCount == 1)
        await machine.forceStop()
    }

    @Test func theFoldersAreNotCalledMountedWhileTheAgentIsAway() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(setUpBySwiftVM: false)
        await machine.start()
        #expect(await eventually { machine.hasAgentMountedSharedFolders })
        // The agent is gone and nothing answers in its place.
        backend.hasAgent = false
        backend.agents[0].hangUp()
        #expect(await eventually { !machine.agent.isConnected })
        #expect(!machine.hasAgentMountedSharedFolders)
        await machine.forceStop()
    }

    @Test func saysSoWhenTheSharedFoldersCouldNotBeMounted() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(setUpBySwiftVM: false)
        backend.answer = { _ in false }
        await machine.start()
        #expect(await eventually { backend.agents.first?.received.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!machine.hasAgentMountedSharedFolders)
        await machine.forceStop()
    }

    @Test func shutsTheGuestDownThroughItsAgent() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))

        await machine.shutDown()
        #expect(machine.state == .stopping)
        #expect(backend.agents[0].received.last == .shutDown(id: 1))
        // The agent has said yes; the power button isn't needed.
        #expect(backend.stopRequests == 0)

        backend.eventHandler?(.guestDidStop)
        #expect(machine.state == .stopped)
        #expect(!machine.agent.isConnected)
    }

    @Test func pressesThePowerButtonWhenTheAgentDoesNotAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        machine.agent.requestTimeout = .milliseconds(50)
        backend.answer = { _ in nil }
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))

        await machine.shutDown()
        #expect(machine.state == .stopping)
        #expect(backend.agents[0].received.last == .shutDown(id: 1))
        #expect(backend.stopRequests == 1)
        await machine.forceStop()
    }

    @Test func pressesThePowerButtonWhenTheAgentSaysNo() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        backend.answer = { _ in false }
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        await machine.shutDown()
        #expect(machine.state == .stopping)
        #expect(backend.stopRequests == 1)
        await machine.forceStop()
    }

    @Test func aGuestWithoutAnAgentIsShutDownWithThePowerButton() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        backend.hasAgent = false
        await machine.start()
        await machine.shutDown()
        #expect(machine.state == .stopping)
        #expect(backend.stopRequests == 1)
        await machine.forceStop()
    }

    @Test func aRestartThroughTheAgentCountsAsANewRun() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(machine.startCount == 1)
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))

        await machine.restart()
        #expect(backend.agents[0].received.last == .shutDown(id: 1))
        backend.eventHandler?(.guestDidStop)
        #expect(await eventually { machine.state == .running && machine.startCount == 2 })
        #expect(await eventually { backend.agents.count == 2 && machine.agent.isConnected })
        await machine.forceStop()
    }

    @Test func aNoticeIsNotAnError() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        #expect(machine.message == nil)
        machine.notice = VMErrorInfo(title: "Installed", message: "All done.", copyableText: "sudo sh install.sh")
        #expect(machine.message?.title == "Installed")
        #expect(machine.message?.copyableText == "sudo sh install.sh")
        #expect(machine.lastError == nil)

        // An operation that starts clears errors, and leaves what the user was told to do where it is.
        await machine.start()
        #expect(machine.notice != nil)
        // An error goes first, and is the first to go.
        machine.lastError = VMErrorInfo(title: "Broken", message: "No.")
        #expect(machine.message?.title == "Broken")
        machine.dismissMessage()
        #expect(machine.lastError == nil)
        #expect(machine.message?.title == "Installed")
        machine.dismissMessage()
        #expect(machine.message == nil)
        await machine.forceStop()
    }

    @Test func aPendingRestartCanBeToldFromAStop() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        backend.hasAgent = false
        await machine.start()
        #expect(!machine.isRestartPending)
        await machine.restart()
        #expect(machine.state == .stopping)
        #expect(machine.isRestartPending)
        // Between the guest going down and its start beginning the machine looks stopped, and isn't done.
        backend.eventHandler?(.guestDidStop)
        #expect(machine.state == .stopped)
        #expect(machine.isRestartPending)
        #expect(await eventually { machine.state == .running && machine.startCount == 2 })
        #expect(!machine.isRestartPending)

        // A stop that nobody asked to follow up with a start is just a stop.
        await machine.forceStop()
        #expect(machine.state == .stopped)
        #expect(!machine.isRestartPending)
    }

    @Test func connectingNeedsAGuestThatIsUp() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await #expect(throws: VMError.self) { try await machine.connectToGuest(port: 22) }
        #expect(backend.attempts.isEmpty)
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        _ = try await machine.connectToGuest(port: 22)
        #expect(backend.attempts == [GuestProtocol.agentPort, 22])
        await machine.pause()
        await #expect(throws: VMError.self) { try await machine.connectToGuest(port: 22) }
        await machine.forceStop()
    }
}
