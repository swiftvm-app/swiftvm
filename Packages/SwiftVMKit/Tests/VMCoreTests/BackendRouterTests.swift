import AppKit
import Foundation
import Testing
@testable import VMCore

@MainActor
private final class NamedBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
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
    func connectToGuest(port: UInt32) async throws -> FileHandle { throw POSIXError(.ECONNRESET) }
    func invalidate() {}
}

@MainActor
private final class CountingProvider: VMBackendProvider {
    var made = 0
    var stopped = 0

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        made += 1
        return NamedBackend()
    }

    func backendDidStop(for machine: VirtualMachine) {
        stopped += 1
    }
}

@MainActor
@Suite struct BackendRouterTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")

    private func machine(_ family: GuestFamily) throws -> VirtualMachine {
        let configuration = VMConfiguration(name: family.displayName, os: GuestOS(family: family), cpuCount: 2, memorySize: 4 << 30, disks: [])
        return try VirtualMachine(bundle: VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration))
    }

    @Test func handsEachMachineToItsEngine() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let virtualization = CountingProvider()
        let qemu = CountingProvider()
        let router = BackendRouter(providers: [.virtualization: virtualization, .qemu: qemu])

        let windows = try machine(.windows)
        windows.backendProvider = router
        windows.isHostLocked = { false }
        await windows.start()
        let linux = try machine(.linux)
        linux.backendProvider = router
        await linux.start()

        #expect(qemu.made == 1)
        #expect(virtualization.made == 1)
        await windows.forceStop()
        #expect(qemu.stopped == 1)
        #expect(virtualization.stopped == 0)
    }

    @Test func saysSoWhenAnEngineIsMissing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let windows = try machine(.windows)
        let router = BackendRouter(providers: [.virtualization: CountingProvider()])
        windows.backendProvider = router
        await windows.start()
        #expect(windows.state == .stopped)
        #expect(windows.lastError?.message == VMError.unsupportedEngine(.qemu).localizedDescription)
    }
}
