import AppKit
import Foundation
import Testing
@testable import VMCore

@MainActor
private final class ColdBootBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    var starts: [VMStartOptions] = []
    var onStart: (() async throws -> Void)?
    var onSave: (() async throws -> Void)?
    var invalidated = false
    func start(options: VMStartOptions) async throws {
        starts.append(options)
        try await onStart?()
    }
    func requestStop() throws {}
    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws {
        try await onSave?()
        try Data("memory".utf8).write(to: url)
    }
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func invalidate() { invalidated = true }
    func connectToGuest(port: UInt32) async throws -> FileHandle { throw POSIXError(.ECONNRESET) }
}

@MainActor
private final class ColdBootProvider: VMBackendProvider {
    let backend = ColdBootBackend()
    var onMake: (() async throws -> Void)?
    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        try await onMake?()
        return backend
    }
    func backendDidStop(for machine: VirtualMachine) {}
}

@MainActor
@Suite struct ColdBootTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-cold-boot-\(UUID())")
    private let provider = ColdBootProvider()

    private func machine() throws -> VirtualMachine {
        let configuration = VMConfiguration(name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory.appending(path: "Box.swiftvm"), configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        machine.isHostLocked = { false }
        return machine
    }

    @Test func stoppedMachineBootsWithoutReadinessOrRestore() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        try await machine.coldBoot()
        #expect(machine.state == .running)
        #expect(machine.startCount == 1)
        #expect(provider.backend.starts.count == 1)
        #expect(provider.backend.starts.first?.savedState == nil)
        #expect(!machine.agent.isConnected)
        await machine.forceStop()
    }

    @Test func savedMemoryIsPreservedAndOrdinaryStartStillResumes() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        let bytes = Data("saved memory".utf8)
        try bytes.write(to: machine.bundle.savedStateURL)
        // The local view predates the file. It must not choose a fresh boot and remove it.
        #expect(machine.state == .stopped)
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        #expect(try Data(contentsOf: machine.bundle.savedStateURL) == bytes)
        #expect(provider.backend.starts.isEmpty)

        let suspended = try VirtualMachine(bundle: machine.bundle)
        suspended.backendProvider = provider
        suspended.isHostLocked = { false }
        await #expect(throws: VMError.self) { try await suspended.coldBoot() }
        #expect(suspended.state == .suspended)
        #expect(try Data(contentsOf: machine.bundle.savedStateURL) == bytes)
        await suspended.start()
        #expect(suspended.state == .running)
        #expect(provider.backend.starts.first?.savedState == machine.bundle.savedStateURL)
        await suspended.forceStop()
    }

    @Test func memoryAppearingDuringConstructionIsPreserved() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        let bytes = Data("arrived while awaiting the provider".utf8)
        provider.onMake = { try bytes.write(to: machine.bundle.savedStateURL) }
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        #expect(try Data(contentsOf: machine.bundle.savedStateURL) == bytes)
        #expect(provider.backend.starts.isEmpty)
        #expect(provider.backend.invalidated)
        #expect(machine.state == .stopped)
    }

    @Test func ambiguousSavedStateAndMissingPackageAreRefused() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        try FileManager.default.createSymbolicLink(at: machine.bundle.savedStateURL, withDestinationURL: directory.appending(path: "absent"))
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: machine.bundle.savedStateURL.path).hasSuffix("absent"))
        try FileManager.default.removeItem(at: machine.bundle.url)
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        #expect(provider.backend.starts.isEmpty)
    }

    @Test(arguments: [VMState.running, .paused, .stopping])
    func activeMachinesAreNotRestarted(_ state: VMState) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        await machine.start()
        if state == .paused { await machine.pause() }
        if state == .stopping { await machine.shutDown() }
        #expect(machine.state == state)
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        #expect(provider.backend.starts.count == 1)
        #expect(machine.state == state)
        await machine.forceStop()
    }

    @Test(arguments: [false, true])
    func startsAndRestoresCannotBeReentered(_ restoring: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var machine = try machine()
        if restoring {
            try Data("memory".utf8).write(to: machine.bundle.savedStateURL)
            machine = try VirtualMachine(bundle: machine.bundle)
            machine.backendProvider = provider
            machine.isHostLocked = { false }
        }
        let starting = machine
        provider.backend.onStart = {
            #expect(starting.state == (restoring ? .restoring : .starting))
            await #expect(throws: VMError.self) { try await starting.coldBoot() }
        }
        await machine.start()
        #expect(provider.backend.starts.count == 1)
        await machine.forceStop()
    }

    @Test func suspensionBusyWorkAndDeniedStartsAreRefused() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        _ = try await machine.whileStopped(.duplicating) {
            await #expect(throws: VMError.self) { try await machine.coldBoot() }
        }
        machine.isStartAllowed = { false }
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        #expect(provider.backend.starts.isEmpty)
        machine.isStartAllowed = { true }
        await machine.start()
        provider.backend.onSave = {
            #expect(machine.state == .suspending)
            await #expect(throws: VMError.self) { try await machine.coldBoot() }
        }
        await machine.suspend()
        #expect(machine.state == .suspended)
        #expect(provider.backend.starts.count == 1)
    }

    @Test func pendingRestartAndFailedBootAreNotReportedAsColdBoots() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        provider.backend.onStart = { throw VMError.invalidConfiguration("backend failed") }
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        #expect(machine.state == .stopped)
        #expect(machine.startCount == 0)
        #expect(provider.backend.invalidated)
        provider.backend.onStart = nil
        await machine.start()
        await machine.restart()
        provider.backend.eventHandler?(.guestDidStop)
        #expect(machine.state == .stopped)
        #expect(machine.isRestartPending)
        await #expect(throws: VMError.self) { try await machine.coldBoot() }
        // Let the already-requested restart finish before cleaning up.
        for _ in 0..<200 where machine.state != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(machine.state == .running)
        #expect(provider.backend.starts.count == 3)
        await machine.forceStop()
    }
}
