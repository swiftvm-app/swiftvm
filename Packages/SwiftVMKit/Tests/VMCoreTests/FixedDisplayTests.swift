import AppKit
import Foundation
import Testing
@testable import VMCore

@MainActor
private final class DisplayProvider: VMBackendProvider, VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    let canSaveState = true
    var validate: ((VMConfiguration, VMBundle) throws -> Void)?
    var starting: (() async throws -> Void)?
    var validations = 0

    func validateFixedDisplay(_ configuration: VMConfiguration, in bundle: VMBundle) throws {
        validations += 1
        try validate?(configuration, bundle)
    }
    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd, ownership: PackageOwnership) async throws -> any VMBackend { self }
    func backendDidStop(for machine: VirtualMachine) {}
    func start(options: VMStartOptions) async throws { try await starting?() }
    func requestStop() throws {}
    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws { try Data("memory".utf8).write(to: url) }
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func connectToGuest(port: UInt32) async throws -> FileHandle { throw POSIXError(.ECONNRESET) }
    func invalidate() {}
}

@MainActor
@Suite struct FixedDisplayTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-display-\(UUID()).swiftvm")
    private let provider: DisplayProvider
    private let router: BackendRouter

    init() {
        let provider = DisplayProvider()
        self.provider = provider
        router = BackendRouter(providers: [.virtualization: provider])
    }

    private func machine() throws -> VirtualMachine {
        let configuration = VMConfiguration(name: "Box", os: GuestOS(family: .macOS), cpuCount: 2, memorySize: 4 << 30, disks: [])
        let machine = try VirtualMachine(bundle: VMBundle.create(at: directory, configuration: configuration))
        try Data("firmware".utf8).write(to: machine.bundle.auxiliaryStorageURL)
        machine.backendProvider = router
        machine.isHostLocked = { false }
        return machine
    }

    @Test func validatesUnderOwnershipThenPersistsOnlyThePanel() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        let original = machine.configuration
        provider.validate = { candidate, bundle in
            #expect(candidate.display.widthInPixels == 2560)
            #expect(candidate.display.heightInPixels == 1664)
            #expect(candidate.display.pixelsPerInch == 220)
            #expect(candidate.display.automaticallyResizes == false)
            let saved = try bundle.loadConfiguration()
            #expect(saved == original)
            #expect(throws: PackageOwnership.Problem.inUse) { try PackageOwnership(in: bundle, configuration: original) }
        }
        try await machine.setFixedDisplay(widthInPixels: 2560, heightInPixels: 1664, pixelsPerInch: 220)
        var expected = original
        expected.display.widthInPixels = 2560
        expected.display.heightInPixels = 1664
        expected.display.pixelsPerInch = 220
        expected.display.automaticallyResizes = false
        #expect(machine.configuration == expected)
        #expect(try VirtualMachine(bundle: machine.bundle).configuration == expected)
        #expect(machine.activity == nil)
        let owner = try PackageOwnership(in: machine.bundle, configuration: expected)
        withExtendedLifetime(owner) {}
    }

    @Test func invalidOrUnsupportedPanelsLeaveTheConfigurationUntouched() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        let original = machine.configuration
        let bytes = try Data(contentsOf: machine.bundle.configurationURL)
        for values in [(0, 1200, 144), (1920, -1, 144), (1920, 1200, 0)] {
            await #expect(throws: VMError.self) {
                try await machine.setFixedDisplay(widthInPixels: values.0, heightInPixels: values.1, pixelsPerInch: values.2)
            }
        }
        #expect(provider.validations == 0)
        provider.validate = { _, _ in throw VMError.invalidConfiguration("Unsupported panel") }
        await #expect(throws: VMError.self) { try await machine.setFixedDisplay(widthInPixels: Int.max, heightInPixels: 1200, pixelsPerInch: 144) }
        #expect(provider.validations == 1)
        #expect(machine.configuration == original)
        #expect(try Data(contentsOf: machine.bundle.configurationURL) == bytes)
        #expect(machine.activity == nil)
        let owner = try PackageOwnership(in: machine.bundle, configuration: original)
        withExtendedLifetime(owner) {}
    }

    @Test func activeBusyAndSavedMemoryCannotChangeThePanel() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        let original = machine.configuration.display
        func refuses() async {
            await #expect(throws: VMError.self) { try await machine.setFixedDisplay(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144) }
        }
        provider.starting = { await refuses() }
        await machine.start()
        try #require(machine.state == .running)
        await refuses()
        await machine.pause()
        try #require(machine.state == .paused)
        await refuses()
        await machine.suspend()
        try #require(machine.state == .suspended)
        await refuses()
        machine.discardSavedState()
        try #require(machine.state == .stopped)
        try await machine.whileStopped(.duplicating) { await refuses() }
        // A stale memory file is unsafe even if this controller still reports stopped.
        try Data("memory".utf8).write(to: machine.bundle.savedStateURL)
        await refuses()
        #expect(provider.validations == 0)
        #expect(machine.configuration.display == original)
        #expect(try machine.bundle.loadConfiguration().display == original)
    }

    @Test func anotherOwnerOrExternalConfigurationChangeRefusesBeforeValidation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try machine()
        let original = machine.configuration
        do {
            let owner = try PackageOwnership(in: machine.bundle, configuration: original)
            await #expect(throws: PackageOwnership.Problem.inUse) {
                try await machine.setFixedDisplay(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)
            }
            withExtendedLifetime(owner) {}
        }
        var changed = original
        changed.cpuCount += 1
        try machine.bundle.save(changed)
        await #expect(throws: PackageOwnership.Problem.changedConfiguration) {
            try await machine.setFixedDisplay(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)
        }
        #expect(provider.validations == 0)
        #expect(machine.configuration == original)
        #expect(try machine.bundle.loadConfiguration() == changed)
        #expect(machine.activity == nil)
    }
}
