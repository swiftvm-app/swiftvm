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
                if let id = message.requestID, let isOK = answer(message) {
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

    private func timeZoneRequests(of agent: FakeAgent) -> [String] {
        agent.received.compactMap { if case .setTimeZone(_, let identifier) = $0 { identifier } else { nil } }
    }

    /// What the agent in a macOS guest says about itself.
    private static let macHello = AgentHello(
        agent: "1.0",
        system: GuestSystem(id: "macos", name: "macOS", version: "27.1", prettyName: "macOS 27.1", build: "26B100", kernel: "27.1.0"),
        features: [GuestFeature.clipboard, GuestFeature.timeZone]
    )

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
        let machine = try makeMachine(family: .windows)
        await machine.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.attempts.isEmpty)
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(30)) == false)
        await machine.forceStop()
    }

    @Test func aMacSaysWhichMacOSItRuns() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(family: .macOS)
        try machine.updateConfiguration { $0.os = GuestOS(family: .macOS, productName: "macOS 27.0.1", build: "26A434") }
        backend.hello = Self.macHello
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        // The guest was updated since it was installed, and says so.
        #expect(machine.configuration.os.summary == "macOS 27.1 (26B100)")
        // It is no Linux distribution, whatever it calls itself.
        #expect(machine.configuration.os.distribution == nil)
        #expect(machine.agent.sharesClipboard)
        #expect(machine.agent.setsTimeZone)
        await machine.forceStop()
        #expect(!machine.agent.sharesClipboard)
    }

    @Test func givesAGuestThisMacsTimeZoneOnce() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(family: .macOS)
        machine.hostTimeZone = { "Europe/Berlin" }
        backend.hello = Self.macHello
        #expect(!machine.configuration.installation.hasHostTimeZone)

        await machine.start()
        #expect(await eventually { machine.configuration.installation.hasHostTimeZone })
        #expect(timeZoneRequests(of: backend.agents[0]) == ["Europe/Berlin"])
        #expect(try machine.bundle.loadConfiguration().installation.hasHostTimeZone)

        // Once in its life. Whoever picks another time zone in the guest afterwards keeps it, also
        // when its agent comes back, the Mac travels, or the machine starts again.
        machine.hostTimeZone = { "Asia/Tokyo" }
        backend.agents[0].hangUp()
        #expect(await eventually { backend.agents.count == 2 && machine.agent.isConnected })
        await machine.forceStop()
        await machine.start()
        #expect(await eventually { backend.agents.count == 3 && machine.agent.isConnected })
        try await Task.sleep(for: .milliseconds(50))
        #expect(timeZoneRequests(of: backend.agents[1]).isEmpty)
        #expect(timeZoneRequests(of: backend.agents[2]).isEmpty)
        await machine.forceStop()
    }

    @Test func asksForTheTimeZoneAgainUntilItWorked() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine(family: .macOS)
        machine.hostTimeZone = { "Europe/Berlin" }
        backend.hello = Self.macHello
        backend.answer = { message in
            if case .setTimeZone = message { false } else { true }
        }
        await machine.start()
        #expect(await eventually { backend.agents.count == 1 && timeZoneRequests(of: backend.agents[0]) == ["Europe/Berlin"] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!machine.configuration.installation.hasHostTimeZone)

        // The next time its agent turns up, it is asked again.
        backend.answer = { _ in true }
        backend.agents[0].hangUp()
        #expect(await eventually { machine.configuration.installation.hasHostTimeZone })
        #expect(timeZoneRequests(of: backend.agents[1]) == ["Europe/Berlin"])
        await machine.forceStop()
    }

    @Test func anAgentThatCannotSetTheTimeZoneIsNotAsked() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // The agent for Linux doesn't offer it, and a Linux guest was asked where it is when it was set up.
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        #expect(!machine.agent.setsTimeZone)
        #expect(await machine.agent.setTimeZone("Europe/Berlin") == false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(backend.agents[0].received == [.hello(protocol: GuestProtocol.version)])
        #expect(!machine.configuration.installation.hasHostTimeZone)
        await machine.forceStop()
    }

    @Test func saysWhenAnAgentComesAndGoes() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        var changes: [Bool] = []
        machine.onGuestAgentChange = { changes.append($0.agent.isConnected) }
        await machine.start()
        #expect(await eventually { changes == [true] })
        backend.agents[0].hangUp()
        #expect(await eventually { changes == [true, false, true] })
        await machine.forceStop()
        #expect(changes == [true, false, true, false])
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

        #expect(await machine.shutDown() == .agent)
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

        #expect(await machine.shutDown() == .powerButton)
        #expect(machine.state == .stopping)
        #expect(backend.agents[0].received.last == .shutDown(id: 1))
        #expect(backend.stopRequests == 1)
        await machine.forceStop()
        // Nothing is asked of a machine that isn't running.
        #expect(await machine.shutDown() == nil)
        #expect(await machine.restart() == nil)
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

    @Test func passesOnHowTheGuestsSetupIsDoing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        // A guest without a setup script says nothing about one.
        #expect(machine.agent.setup == nil)

        #expect(machine.setupTitle == nil && machine.setupActivity == nil)

        backend.agents[0].send(.setup(GuestSetupStatus(state: .pending, name: "KDE Plasma")))
        #expect(await eventually { machine.agent.setup?.state == .pending })
        // Until the script names a step, what it is called has to do.
        #expect(machine.setupTitle == "Setting up KDE Plasma")
        #expect(machine.setupActivity == "Setting up KDE Plasma")
        backend.agents[0].send(.setup(GuestSetupStatus(state: .running, name: "KDE Plasma", step: "Installing KDE Plasma")))
        #expect(await eventually { machine.agent.setup?.step == "Installing KDE Plasma" })
        #expect(machine.agent.setup?.name == "KDE Plasma")
        #expect(machine.setupTitle == "Setting up KDE Plasma")
        #expect(machine.setupActivity == "Installing KDE Plasma")
        #expect(machine.message == nil)
        // A script of the user's own may have no name to go by.
        backend.agents[0].send(.setup(GuestSetupStatus(state: .running)))
        #expect(await eventually { machine.setupActivity == "Setting up" })

        // The guest restarts into its desktop: what was known of its setup goes with the agent, and
        // comes back with it.
        backend.agents[0].send(.setup(GuestSetupStatus(state: .finished, name: "KDE Plasma")))
        #expect(await eventually { machine.agent.setup?.state == .finished })
        // What is over is no longer in the way of where the machine is reached.
        #expect(machine.setupTitle == nil && machine.setupActivity == nil)
        backend.agents[0].hangUp()
        #expect(await eventually { backend.agents.count == 2 && machine.agent.isConnected })
        #expect(machine.agent.setup == nil)
        backend.agents[1].send(.setup(GuestSetupStatus(state: .finished, name: "KDE Plasma")))
        #expect(await eventually { machine.agent.setup?.state == .finished })
        // Nothing of this is worth a message.
        #expect(machine.message == nil)

        await machine.forceStop()
        #expect(machine.agent.setup == nil)
    }

    @Test func saysSoOnceWhenTheSetupFails() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))

        backend.agents[0].send(.setup(GuestSetupStatus(state: .running, name: "KDE Plasma", step: "Installing KDE Plasma")))
        backend.agents[0].send(.setup(GuestSetupStatus(state: .failed, name: "KDE Plasma", step: "Installing KDE Plasma")))
        #expect(await eventually { machine.notice != nil })
        #expect(machine.notice?.title == "KDE Plasma couldn't be set up in “Box”")
        #expect(machine.notice?.message.contains("at “Installing KDE Plasma”") == true)
        #expect(machine.notice?.message.contains(GuestIntegration.setupLogPath) == true)
        #expect(machine.notice?.copyableText == GuestIntegration.setupRetryCommand)
        // It is something to tell, not an error of the machine's: commands that follow don't fail over it.
        #expect(machine.lastError == nil)
        // That the user has been told is on record, with the machine.
        #expect(try machine.bundle.loadConfiguration().installation.hasReportedSetupFailure)
        machine.dismissMessage()

        // Run again by hand it is at work again, and the next failure is news again. With several
        // scripts that is the ordinary way: one is put right, and the one after it fails.
        backend.agents[0].send(.setup(GuestSetupStatus(state: .running, name: "Docker (2 of 3)")))
        backend.agents[0].send(.setup(GuestSetupStatus(state: .failed, name: "Docker (2 of 3)", step: "Installing Docker")))
        #expect(await eventually { machine.notice?.title == "Docker (2 of 3) couldn't be set up in “Box”" })
        #expect(machine.configuration.installation.hasReportedSetupFailure)
        machine.dismissMessage()

        // The next time it starts, a script that failed long ago is no news.
        await machine.forceStop()
        await machine.start()
        #expect(await eventually { backend.agents.count == 2 && machine.agent.isConnected })
        backend.agents[1].send(.setup(GuestSetupStatus(state: .failed, name: "KDE Plasma", step: "Installing KDE Plasma")))
        #expect(await eventually { machine.agent.setup?.state == .failed })
        #expect(machine.message == nil)

        // Tried again by hand, it is at work again, and that it failed once more is news once more.
        backend.agents[1].send(.setup(GuestSetupStatus(state: .running, name: "KDE Plasma")))
        #expect(await eventually { !machine.configuration.installation.hasReportedSetupFailure })
        backend.agents[1].send(.setup(GuestSetupStatus(state: .failed)))
        #expect(await eventually { machine.notice != nil })
        // A script that has no name to go by is called what it is.
        #expect(machine.notice?.title == "The setup script failed in “Box”")
        #expect(machine.notice?.message.hasPrefix("The setup script stopped with an error. What it printed") == true)
        machine.dismissMessage()

        // A guest that keeps saying one thing and then the other is heard a few times in a run, and
        // then no more: what it reports is up to the guest, and how often the user is told isn't.
        for round in 0..<20 {
            backend.agents[1].send(.setup(GuestSetupStatus(state: .running, name: "Flap \(round)")))
            backend.agents[1].send(.setup(GuestSetupStatus(state: .failed, name: "Flap \(round)")))
        }
        #expect(await eventually { machine.agent.setup?.name == "Flap 19" })
        let lastHeard = try #require(machine.notice?.title)
        #expect(lastHeard.hasPrefix("Flap ") && lastHeard != "Flap 19 couldn't be set up in “Box”")
        machine.dismissMessage()
        backend.agents[1].send(.setup(GuestSetupStatus(state: .running, name: "Once more")))
        backend.agents[1].send(.setup(GuestSetupStatus(state: .failed, name: "Once more", step: "Again")))
        #expect(await eventually { machine.agent.setup?.step == "Again" })
        #expect(machine.message == nil)
        await machine.forceStop()
    }

    @Test func aSetupThatFailedWhileNobodyLookedIsStillNews() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        // The script was over before the app first reached the agent: its first word is that it failed.
        backend.agents[0].send(.setup(GuestSetupStatus(state: .failed, name: "Docker", step: "Installing Docker")))
        #expect(await eventually { machine.notice != nil })
        #expect(machine.notice?.title == "Docker couldn't be set up in “Box”")
        #expect(machine.configuration.installation.hasReportedSetupFailure)

        // A machine that was made before any of this has no such record.
        let older = try JSONDecoder().decode(InstallationConfiguration.self, from: Data(#"{"attachesSeedImage":true}"#.utf8))
        #expect(!older.hasReportedSetupFailure)
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

/// The Mac's clipboard, played by the test.
@MainActor
private final class PretendClipboard: Clipboard {
    private(set) var changeCount = 0
    private var contents: String?
    /// How often the clipboard's contents were read, which is what a system could ask the user about.
    private(set) var reads = 0

    var text: String? {
        reads += 1
        return contents
    }

    /// What is on the clipboard, without that counting as a read.
    var current: String? { contents }

    func setText(_ text: String) {
        copy(text)
    }

    /// Someone copies something on the Mac. `nil` is something that isn't text, such as a picture.
    func copy(_ text: String?) {
        contents = text
        changeCount += 1
    }
}

@MainActor
@Suite struct ClipboardSharingTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
    private let clipboard = PretendClipboard()
    private let sharing: ClipboardSharing

    init() {
        sharing = ClipboardSharing(clipboard: clipboard, lookInterval: .milliseconds(10))
    }

    private static let sharingHello = AgentHello(
        agent: "1.0", system: GuestSystem(id: "macos", prettyName: "macOS 27.0.1"), features: [GuestFeature.clipboard, GuestFeature.timeZone]
    )

    /// A machine with a guest of its own, wired to the sharing the way the app wires its machines.
    private func makeMachine(hello: AgentHello = ClipboardSharingTests.sharingHello) throws -> (machine: VirtualMachine, provider: AgentProvider) {
        var configuration = VMConfiguration(name: "Mac", os: GuestOS(family: .macOS), cpuCount: 4, memorySize: 8 << 30, disks: [])
        configuration.installation.hasHostTimeZone = true
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        let provider = AgentProvider()
        provider.backend.hello = hello
        machine.backendProvider = provider
        machine.isHostLocked = { false }
        machine.agent.retryInterval = .milliseconds(10)
        machine.onGuestAgentChange = { [sharing] in sharing.update($0) }
        machine.onGuestClipboard = { [sharing] in sharing.guest($0, didCopy: $1) }
        machine.onGuestClipboardRequest = { [sharing] in sharing.guestWantsClipboard($0) }
        machine.onConfigurationChange = { [sharing] in sharing.update($0) }
        return (machine, provider)
    }

    private func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// The texts a guest was told were copied on the Mac, in order.
    private func copies(toldTo provider: AgentProvider, line: Int = 0) -> [String] {
        guard provider.backend.agents.indices.contains(line) else { return [] }
        return provider.backend.agents[line].received.compactMap { if case .clipboard(let text) = $0 { text } else { nil } }
    }

    @Test func whatIsCopiedOnTheMacReachesTheGuest() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        clipboard.copy("copied before the guest was up")
        let (machine, provider) = try makeMachine()
        #expect(!sharing.isWatching)

        // A guest that joins finds on its clipboard what is on the Mac's.
        await machine.start()
        #expect(await eventually { copies(toldTo: provider) == ["copied before the guest was up"] })
        #expect(sharing.isWatching)

        clipboard.copy("copied while it runs")
        #expect(await eventually { copies(toldTo: provider).last == "copied while it runs" })
        // While nothing is copied the clipboard isn't read: looking at its counter is all it takes.
        let reads = clipboard.reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(clipboard.reads == reads)

        // A picture isn't text, and nothing is said about it.
        clipboard.copy(nil)
        clipboard.copy("")
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: provider).count == 2)

        // Nobody watches the clipboard for a guest that is gone.
        await machine.forceStop()
        #expect(!sharing.isWatching)
        let before = clipboard.reads
        clipboard.copy("copied after it stopped")
        try await Task.sleep(for: .milliseconds(100))
        #expect(clipboard.reads == before)
    }

    @Test func whatIsCopiedInAGuestReachesTheMacAndTheOtherGuests() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, firstProvider) = try makeMachine()
        let (second, secondProvider) = try makeMachine()
        await first.start()
        await second.start()
        #expect(await eventually { first.agent.sharesClipboard && second.agent.sharesClipboard })

        firstProvider.backend.agents[0].send(.clipboard(text: "copied in the first guest"))
        #expect(await eventually { clipboard.current == "copied in the first guest" })
        #expect(await eventually { copies(toldTo: secondProvider) == ["copied in the first guest"] })
        // The guest it came from isn't told what it already has, now or when the Mac's clipboard is
        // next looked at.
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: firstProvider).isEmpty)
        #expect(copies(toldTo: secondProvider).count == 1)

        // The same text again doesn't touch the Mac's clipboard.
        let count = clipboard.changeCount
        secondProvider.backend.agents[0].send(.clipboard(text: "copied in the first guest"))
        secondProvider.backend.agents[0].send(.clipboard(text: ""))
        #expect(await eventually { copies(toldTo: firstProvider) == ["copied in the first guest"] })
        #expect(clipboard.changeCount == count)

        // And what is copied on the Mac goes to both.
        clipboard.copy("copied on the Mac")
        #expect(await eventually { copies(toldTo: firstProvider).last == "copied on the Mac" && copies(toldTo: secondProvider).last == "copied on the Mac" })
        await first.forceStop()
        #expect(sharing.isWatching)
        await second.forceStop()
        #expect(!sharing.isWatching)
    }

    @Test func aGuestThatDoesNotShareIsLeftOut() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        clipboard.copy("on the Mac")
        // Its agent doesn't offer to.
        let (plain, plainProvider) = try makeMachine(hello: AgentHello(agent: "1.0", system: GuestSystem(id: "ubuntu")))
        await plain.start()
        #expect(await plain.agent.waitUntilConnected(timeout: .seconds(5)))
        plainProvider.backend.agents[0].send(.clipboard(text: "from a guest that doesn't share"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: plainProvider).isEmpty)
        #expect(clipboard.current == "on the Mac")
        #expect(!sharing.isWatching)

        // Or sharing is turned off for the machine.
        let (machine, provider) = try makeMachine()
        try machine.updateConfiguration { $0.clipboard.isShared = false }
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        provider.backend.agents[0].send(.clipboard(text: "from a guest that is kept apart"))
        clipboard.copy("more on the Mac")
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: provider).isEmpty)
        #expect(clipboard.current == "more on the Mac")
        #expect(clipboard.reads == 0)

        // Turned on while the guest runs, it joins at once, and leaves when it is turned off again.
        try machine.updateConfiguration { $0.clipboard.isShared = true }
        #expect(await eventually { copies(toldTo: provider) == ["more on the Mac"] })
        #expect(sharing.isWatching)
        // A change that has nothing to do with the clipboard doesn't send it all again.
        try machine.updateConfiguration { $0.name = "Renamed" }
        try await Task.sleep(for: .milliseconds(50))
        #expect(copies(toldTo: provider).count == 1)
        try machine.updateConfiguration { $0.clipboard.isShared = false }
        #expect(!sharing.isWatching)
        clipboard.copy("not for the guest")
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: provider).count == 1)
        await machine.forceStop()
        await plain.forceStop()
    }

    @Test func aGuestThatComesBackKeepsWhatItCopiedSince() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (machine, provider) = try makeMachine()
        clipboard.copy("first")
        await machine.start()
        #expect(await eventually { copies(toldTo: provider) == ["first"] })

        // Suspended and resumed with nothing new on the Mac. The guest has that text already, and may
        // have copied a picture since, which sending it again would wipe out.
        await machine.suspend()
        await machine.start()
        #expect(await eventually { provider.backend.agents.count == 2 && machine.agent.sharesClipboard })
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: provider, line: 1).isEmpty)

        // Someone logs in afresh in the guest, with a clipboard that has nothing from the Mac on it.
        // The guest asks, and is told, the same text or not.
        provider.backend.agents[1].send(.clipboardRequest)
        #expect(await eventually { copies(toldTo: provider, line: 1) == ["first"] })

        // What came from the guest isn't sent back to it when it comes back either.
        provider.backend.agents[1].send(.clipboard(text: "copied in the guest"))
        #expect(await eventually { clipboard.current == "copied in the guest" })
        await machine.suspend()
        await machine.start()
        #expect(await eventually { provider.backend.agents.count == 3 && machine.agent.sharesClipboard })
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: provider, line: 2).isEmpty)

        // A guest that isn't shared with is told nothing, however it asks.
        try machine.updateConfiguration { $0.clipboard.isShared = false }
        provider.backend.agents[2].send(.clipboardRequest)
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: provider, line: 2).isEmpty)
        // And with a picture on the Mac's clipboard there is nothing to tell.
        try machine.updateConfiguration { $0.clipboard.isShared = true }
        clipboard.copy(nil)
        provider.backend.agents[2].send(.clipboardRequest)
        try await Task.sleep(for: .milliseconds(100))
        #expect(copies(toldTo: provider, line: 2).isEmpty)
        await machine.forceStop()
    }

    @Test func aGuestThatComesBackIsToldAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (machine, provider) = try makeMachine()
        clipboard.copy("first")
        await machine.start()
        #expect(await eventually { copies(toldTo: provider) == ["first"] })
        await machine.suspend()
        #expect(!sharing.isWatching)
        // Copied while the guest was suspended: it finds it when it is back.
        clipboard.copy("second")
        await machine.start()
        #expect(await eventually { copies(toldTo: provider, line: 1) == ["second"] })
        // Text that is too long for a message isn't shared, and breaks nothing.
        clipboard.copy(String(repeating: "x", count: GuestProtocol.maximumLineLength))
        clipboard.copy("third")
        #expect(await eventually { copies(toldTo: provider, line: 1).last == "third" })
        #expect(copies(toldTo: provider, line: 1).count == 2)
        await machine.forceStop()
    }
}
