import AppKit
import Foundation
import Testing
@testable import VMCore

@MainActor
private final class OwnedBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    var ownership: PackageOwnership?
    func start(options: VMStartOptions) async throws {}
    func requestStop() throws {}
    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws { try Data("memory".utf8).write(to: url) }
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func invalidate() {}
    func connectToGuest(port: UInt32) async throws -> FileHandle { throw POSIXError(.ECONNRESET) }
}

@MainActor
private final class OwnedProvider: VMBackendProvider {
    let backend = OwnedBackend()
    var constructing: (() async throws -> Void)?
    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd, ownership: PackageOwnership) async throws -> any VMBackend {
        #expect(throws: PackageOwnership.Problem.inUse) { try PackageOwnership(in: machine.bundle, configuration: machine.configuration) }
        try await constructing?()
        backend.ownership = ownership
        return backend
    }
    func backendDidStop(for machine: VirtualMachine) {}
}

@MainActor
@Suite struct PackageOwnershipLifecycleTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-package-lifecycle-\(UUID()).swiftvm")

    private func machine(provider: OwnedProvider) throws -> VirtualMachine {
        let configuration = VMConfiguration(name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory, configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        return machine
    }

    @Test func backendRetentionOutlivesStoppedStateAndBlocksAllIdleWriters() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = OwnedProvider()
        let machine = try machine(provider: provider)
        await machine.start()
        try #require(machine.state == .running)
        await machine.forceStop()
        #expect(machine.state == .stopped)
        var ran = false
        await #expect(throws: PackageOwnership.Problem.inUse) {
            try await machine.whileStopped(.duplicating) { ran = true }
        }
        #expect(!ran)
        #expect(throws: PackageOwnership.Problem.inUse) { try machine.updateConfiguration { $0.cpuCount = 4 } }
        let library = VMLibrary(rootDirectory: directory.deletingLastPathComponent().appending(path: "unused-library-\(UUID())"))
        #expect(throws: PackageOwnership.Problem.inUse) { try library.remove(machine, movingToTrash: false) }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        provider.backend.ownership = nil
        try await machine.whileStopped(.duplicating) { ran = true }
        #expect(ran)
        try machine.updateConfiguration { $0.cpuCount = 4 }
        #expect(machine.configuration.cpuCount == 4)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationCannotReleaseOwnershipBeforeTheFactoryReturns() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = OwnedProvider()
        let machine = try machine(provider: provider)
        let entered = AsyncStream.makeStream(of: Bool.self)
        var finish: CheckedContinuation<Void, Never>?
        defer { entered.continuation.finish(); finish?.resume() }
        provider.constructing = {
            await withCheckedContinuation { continuation in
                finish = continuation
                entered.continuation.yield(true)
            }
            throw CancellationError()
        }
        let start = Task { await machine.start() }
        var events = entered.stream.makeAsyncIterator()
        try #require(await events.next() == true)
        start.cancel()
        await Task.yield()
        #expect(throws: PackageOwnership.Problem.inUse) { try PackageOwnership(in: machine.bundle, configuration: machine.configuration) }
        let completion = try #require(finish)
        finish = nil
        completion.resume()
        await start.value
        #expect(machine.state == .stopped)
        #expect(machine.lastError != nil)
        let next = try PackageOwnership(in: machine.bundle, configuration: machine.configuration)
        withExtendedLifetime(next) {}
    }

    @Test(arguments: ["package.lock", "PACKAGE.LOCK", "PACKAGE.LOCK"])
    func malformedSnapshotsCannotReplaceTheOwnershipInodeOrDiscardMemory(_ name: String) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = OwnedProvider()
        let machine = try machine(provider: provider)
        let snapshot = try await machine.takeSnapshot(named: "Before")
        let owner = try PackageOwnership(in: machine.bundle, configuration: machine.configuration)
        var original = stat()
        try #require(lstat(directory.appending(path: "package.lock").path, &original) == 0)
        try Data("not an ownership file".utf8).write(to: machine.bundle.snapshotURL(for: snapshot.id).appending(path: name))
        #expect(throws: CocoaError.self) { try machine.bundle.stageRestore(of: snapshot) }
        let memory = Data("saved memory".utf8)
        try memory.write(to: machine.bundle.savedStateURL)
        let malformed = VMBundle.StagedRestore(snapshot: snapshot, fileNames: [name])
        #expect(throws: CocoaError.self) { try machine.bundle.commitRestore(malformed, replacing: machine.configuration) }
        #expect(try Data(contentsOf: machine.bundle.savedStateURL) == memory)
        try owner.requireMatches(machine.bundle)
        var current = stat()
        #expect(lstat(directory.appending(path: "package.lock").path, &current) == 0)
        #expect(current.st_ino == original.st_ino && current.st_dev == original.st_dev)
    }
}
