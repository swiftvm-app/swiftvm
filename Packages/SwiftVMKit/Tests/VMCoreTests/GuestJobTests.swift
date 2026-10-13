import AppKit
import Foundation
import GuestChannel
import Testing
@testable import VMCore

/// A backend whose guest has an agent: it says hello on the agent's port, and answers jobs on the
/// port for those.
@MainActor
private final class AgentBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    /// What the agent says it does, in its hello.
    var features = [GuestFeature.exec]
    /// What the agent answers a job with.
    var jobAnswer = GuestJobAnswer(ok: true)
    var jobOutput = Data()
    let jobHangups = DispatchSemaphore(value: 0)
    private let record = Record()

    /// What arrived on the port for jobs, shared with the threads that play the agent.
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        var all: [String] { lock.withLock { lines } }

        func add(_ line: String) {
            lock.withLock { lines.append(line) }
        }
    }

    /// The jobs the agent was sent, as they arrived.
    var jobs: [String] { record.all }
    /// What was done with the machine's own display, mouse and keyboard.
    var deskCalls: [String] = []

    func screenshot() async throws -> Data {
        deskCalls.append("screenshot")
        return Data("a picture".utf8)
    }

    func pointer(_ request: GuestJob.Pointer, guestTurnsWheel: Bool) async throws {
        deskCalls.append("\(request.action.rawValue) \(request.x),\(request.y)")
    }

    func keys(_ request: GuestJob.Keys) async throws {
        deskCalls.append("keys \(request.text ?? "")")
    }

    func start(options: VMStartOptions) async throws {}
    func requestStop() throws {}
    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws {}
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func invalidate() {}

    func connectToGuest(port: UInt32) async throws -> FileHandle {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.EIO) }
        let guest = descriptors[1]
        _ = fcntl(guest, F_SETNOSIGPIPE, 1)
        switch port {
        case GuestProtocol.agentPort:
            let hello = AgentMessage.hello(AgentHello(agent: "9.9", features: features))
            Thread.detachNewThread {
                _ = ByteRelay.writeAll(ArraySlice(GuestMessageCoding.line(for: hello)), to: guest)
                // The line stays open for as long as the app keeps it: what it asks goes unanswered.
                var byte: UInt8 = 0
                while read(guest, &byte, 1) > 0 {}
                close(guest)
            }
        case GuestProtocol.jobPort:
            let (answer, output, record, hangups) = (jobAnswer, jobOutput, record, jobHangups)
            Thread.detachNewThread {
                if let line = GuestJobLine.read(from: guest, timeout: 5) {
                    record.add(String(decoding: line, as: UTF8.self))
                    GuestJobLine.answer(answer, on: guest)
                    _ = ByteRelay.writeAll(ArraySlice(output), to: guest)
                }
                // A broken collection timeout must not hold the test process for good.
                var byte: UInt8 = 0
                while true {
                    var waiting = pollfd(fd: guest, events: Int16(POLLIN), revents: 0)
                    guard poll(&waiting, 1, 10_000) > 0 else { break }
                    let count = read(guest, &byte, 1)
                    if count == 0 { hangups.signal() }
                    guard count > 0 else { break }
                }
                close(guest)
            }
        default:
            close(descriptors[0])
            close(guest)
            throw POSIXError(.ECONNREFUSED)
        }
        return FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    }
}

@MainActor
private final class AgentProvider: VMBackendProvider {
    let backend = AgentBackend()

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend { backend }
    func backendDidStop(for machine: VirtualMachine) {}
}

/// Who gets to give a guest's agent a job, and what the agent is asked for.
@MainActor
@Suite struct GuestJobGateTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
    private let provider = AgentProvider()

    /// A running machine whose agent has said hello.
    private func startMachine(automation: Bool = true, family: GuestFamily = .linux) async throws -> VirtualMachine {
        let configuration = VMConfiguration(
            name: "Web", os: GuestOS(family: family), cpuCount: 2, memorySize: 2 << 30, disks: [],
            automation: AutomationConfiguration(isAllowed: automation)
        )
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        // What the app asks of this agent by itself goes unanswered, and isn't worth waiting for.
        machine.agent.requestTimeout = .milliseconds(20)
        await machine.start()
        #expect(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        return machine
    }

    @Test func aMachineThatIsNotToBeDrivenIsGivenNoJobs() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await startMachine(automation: false)
        await #expect(throws: GuestJobError.notAllowed(name: "Web")) {
            _ = try await machine.openJob(.exec(.init(arguments: ["rm", "-rf", "/"])))
        }
        // Not asked and refused: never asked.
        #expect(provider.backend.jobs.isEmpty)

        // Turned on, the same machine takes the job.
        try machine.updateConfiguration { $0.automation.isAllowed = true }
        _ = try await machine.openJob(.exec(.init(arguments: ["true"])))
        #expect(provider.backend.jobs == [#"{"arguments":["true"],"type":"exec"}"#])
        await machine.forceStop()
    }

    @Test func anAgentIsOnlyAskedForWhatItSaysItDoes() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // An agent from before it could show the screen.
        let machine = try await startMachine()
        await #expect(throws: GuestJobError.notOffered(name: "Web", version: "9.9")) {
            _ = try await machine.openJob(.screenshot)
        }
        await #expect(throws: GuestJobError.notOffered(name: "Web", version: "9.9")) {
            _ = try await machine.openJob(.unknown(type: "later"))
        }
        // A job that is longer than a line may be would be passed over without a word. It isn't sent.
        await #expect(throws: GuestJobError.tooLong) {
            _ = try await machine.openJob(.exec(.init(arguments: ["echo", String(repeating: "x", count: GuestProtocol.maximumLineLength)])))
        }
        #expect(provider.backend.jobs.isEmpty)

        // What the agent says to a job it is given is the answer.
        provider.backend.jobAnswer = .refusal("This system has no account named “nobody”.")
        await #expect(throws: GuestJobError.refused("This system has no account named “nobody”.")) {
            _ = try await machine.openJob(.exec(.init(arguments: ["true"], user: "nobody")))
        }
        await machine.forceStop()

        // A guest that is down has no agent to ask.
        await #expect(throws: VMError.self) { _ = try await machine.openJob(.exec(.init(arguments: ["true"]))) }
    }

    @Test(arguments: [Data([1]), Data([1, 0, 0, 0, 3, 7])])
    func anUnfinishedPermissionFrameIsHungUpOnAndCanBeRetried(prefix: Data) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let hangups = provider.backend.jobHangups
        func wasHungUp() async -> Bool {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: hangups.wait(timeout: .now() + 5) == .success)
                }
            }
        }
        provider.backend.features = [GuestFeature.permission]
        provider.backend.jobOutput = prefix
        let machine = try await startMachine(family: .macOS)
        let job = GuestJob.permission(.init(action: .check))
        let started = ContinuousClock.now
        await #expect(throws: GuestJobError.noAnswer(name: "Web")) {
            _ = try await machine.collect(job, patience: 0.1)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await wasHungUp())

        // The unfinished job is gone; the next request has a connection of its own.
        let said = try JSONEncoder().encode(GuestPermissionState(isAllowed: true))
        provider.backend.jobOutput = JobFrame(.output, said).encoded + JobFrame.end(.success).encoded
        #expect(try await machine.collect(job, patience: 5) == said)
        #expect(await wasHungUp())
        await machine.forceStop()
    }

    @Test func aMacGuestsScreenMouseAndKeyboardAreTheMachinesOwn() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // An agent that would do all of it, if macOS in the guest let it.
        provider.backend.features = [GuestFeature.exec, GuestFeature.screen, GuestFeature.input, GuestFeature.accessibility]
        let machine = try await startMachine(family: .macOS)
        #expect(machine.doesItself(.screenshot))
        #expect(machine.doesItself(.pointer(.init(action: .click, x: 4, y: 2))))
        #expect(machine.doesItself(.keys(.init(text: "ls -la\n", keys: ["cmd+k"]))))
        // Text that the machine's keyboard has no keys for is left to an agent that types.
        #expect(!machine.doesItself(.keys(.init(text: "grüße"))))
        // Commands and the screen as a tree are in the guest, and an agent's to do.
        #expect(!machine.doesItself(.exec(.init(arguments: ["true"]))))
        #expect(!machine.doesItself(.tree(.init())))

        #expect(try await machine.carryOut(.screenshot) == Data("a picture".utf8))
        _ = try await machine.carryOut(.pointer(.init(action: .click, x: 4, y: 2)))
        _ = try await machine.carryOut(.keys(.init(text: "ls")))
        #expect(provider.backend.deskCalls == ["screenshot", "click 4,2", "keys ls"])
        // None of it went to the agent.
        #expect(provider.backend.jobs.isEmpty)

        // A machine that is not to be driven is not driven this way either.
        try machine.updateConfiguration { $0.automation.isAllowed = false }
        await #expect(throws: GuestJobError.notAllowed(name: "Web")) { _ = try await machine.carryOut(.screenshot) }
        #expect(provider.backend.deskCalls.count == 3)
        await machine.forceStop()
    }

    @Test func aLinuxGuestsScreenIsItsAgentsToShow() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await startMachine()
        #expect(!machine.doesItself(.screenshot))
        #expect(!machine.doesItself(.keys(.init(text: "ls"))))
        await machine.forceStop()
    }

    @Test func goingBackToASnapshotKeepsTheSwitchAsItIsNow() {
        // What was allowed when the snapshot was taken doesn't come back with it.
        var configuration = VMConfiguration(name: "Web", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 2 << 30, disks: [])
        let snapshot = VMSnapshot(name: "Before", includesMemory: false, configuration: configuration)
        configuration.automation.isAllowed = false
        #expect(!configuration.reverted(to: snapshot).automation.isAllowed)
    }
}
