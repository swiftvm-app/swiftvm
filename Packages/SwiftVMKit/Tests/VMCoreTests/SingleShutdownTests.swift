import AppKit
import Foundation
import GuestChannel
import Testing
@testable import VMCore

@MainActor
private final class ShutdownBackend: VMBackend, VMBackendProvider {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    var canRequestStop = true
    var stopRequests = 0
    var forceStops = 0
    var requestError: (any Error)?

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend { self }
    func backendDidStop(for machine: VirtualMachine) {}
    func connectToGuest(port: UInt32) async throws -> FileHandle { throw POSIXError(.ECONNRESET) }
    func start(options: VMStartOptions) async throws {}
    func requestStop() throws {
        stopRequests += 1
        if let requestError { throw requestError }
    }
    func stop() async throws { forceStops += 1 }
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws {}
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func invalidate() {}
}

@MainActor
@Suite struct SingleShutdownTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-shutdown-\(UUID().uuidString)")
    private let backend = ShutdownBackend()

    private func machine() async throws -> VirtualMachine {
        let configuration = VMConfiguration(name: "Test", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 2 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory.appending(path: "Test.swiftvm"), configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = backend
        machine.isHostLocked = { false }
        machine.shutdownRequestRepeatInterval = .milliseconds(5)
        machine.shutdownRequestTimeout = .milliseconds(15)
        await machine.start()
        try #require(machine.state == .running)
        return machine
    }

    @Test func aPowerButtonTimeoutNeverRepeatsOrForcesAndALaterCallIsANewAttempt() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await machine()
        machine.lastError = VMErrorInfo(title: "Keep", message: "Existing evidence")
        let result = await machine.shutDownOnce(using: .powerButton, timeout: .milliseconds(50))
        #expect(result == SingleShutdownResult(delivery: .unknown, state: .running, timedOut: true))
        #expect(backend.stopRequests == 1)
        #expect(backend.forceStops == 0)
        #expect(machine.lastError?.message == "Existing evidence")
        try await Task.sleep(for: .milliseconds(40))
        #expect(backend.stopRequests == 1)
        _ = await machine.shutDownOnce(using: .powerButton, timeout: .milliseconds(10))
        #expect(backend.stopRequests == 2)
        #expect(backend.forceStops == 0)
    }

    @Test func aFailedButtonRequestDoesNotFallBackOrForce() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await machine()
        backend.requestError = POSIXError(.EIO)
        let result = await machine.shutDownOnce(using: .powerButton, timeout: .milliseconds(10))
        #expect(result.delivery == .unknown)
        #expect(result.state == .running)
        #expect(result.requestError != nil)
        #expect(backend.stopRequests == 1)
        #expect(backend.forceStops == 0)
    }

    @Test func unsupportedAndAlreadyStoppedMachinesGetNoRequest() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await machine()
        backend.canRequestStop = false
        #expect(await machine.shutDownOnce(using: .powerButton).delivery == .unsupported)
        #expect(await machine.shutDownOnce(using: .agent).delivery == .unsupported)
        #expect(machine.state == .running)
        backend.eventHandler?(.guestDidStop)
        #expect(await machine.shutDownOnce(using: .powerButton).delivery == .alreadyStopped)
        #expect(backend.stopRequests == 0)
        #expect(backend.forceStops == 0)
    }

    @Test func observationEndsWhenTheBackendReportsStopped() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await machine()
        let stopped = Task {
            try await Task.sleep(for: .milliseconds(10))
            backend.eventHandler?(.guestDidStop)
        }
        let result = await machine.shutDownOnce(using: .powerButton, timeout: .seconds(1))
        try await stopped.value
        #expect(result == SingleShutdownResult(delivery: .unknown, state: .stopped))
        #expect(backend.stopRequests == 1)
        #expect(backend.forceStops == 0)
    }

    @Test func callerCancellationDoesNotRepeatOrForceTheRequest() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await machine()
        let request = Task { await machine.shutDownOnce(using: .powerButton, timeout: .seconds(1)) }
        while backend.stopRequests == 0 { await Task.yield() }
        request.cancel()
        let result = await request.value
        try await Task.sleep(for: .milliseconds(40))
        #expect(result.state == .running)
        #expect(backend.stopRequests == 1)
        #expect(backend.forceStops == 0)
    }

    enum Answer: Sendable, CaseIterable { case accepted, rejected, silent, disconnected }

    @Test(arguments: Answer.allCases)
    func anAgentAnswerNeverTriggersAFallback(answer: Answer) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await machine()
        machine.agent.stop()
        var descriptors: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let app = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let far = peer.fileDescriptor
        _ = fcntl(far, F_SETNOSIGPIPE, 1)
        defer { machine.agent.stop(); try? peer.close() }
        _ = ByteRelay.writeAll(ArraySlice(GuestMessageCoding.line(for: AgentMessage.hello(AgentHello(agent: "1.8")))), to: far)
        machine.agent.start { app }
        try #require(await machine.agent.waitUntilConnected(timeout: .seconds(1)))
        let responding = Task.detached {
            var count = 0
            while let line = GuestJobLine.read(from: far, timeout: 0.2) {
                guard case .shutDown(let id) = GuestMessageCoding.message(HostMessage.self, from: line) else { continue }
                count += 1
                switch answer {
                case .accepted, .rejected:
                    let message = AgentMessage.result(GuestRequestResult(id: id, ok: answer == .accepted))
                    _ = ByteRelay.writeAll(ArraySlice(GuestMessageCoding.line(for: message)), to: far)
                case .silent: break
                case .disconnected:
                    shutdown(far, SHUT_RDWR)
                    return count
                }
            }
            return count
        }
        let result = await machine.shutDownOnce(using: .agent, timeout: .milliseconds(50))
        let expected: SingleShutdownResult.Delivery = switch answer {
        case .accepted: .accepted
        case .rejected: .rejected
        case .silent, .disconnected: .unknown
        }
        #expect(result.delivery == expected)
        #expect(result.state == .running)
        if answer != .rejected { #expect(result.timedOut) }
        #expect(await responding.value == 1)
        #expect(backend.stopRequests == 0)
        #expect(backend.forceStops == 0)
    }
}
