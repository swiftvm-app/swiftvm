import AppKit
import Foundation
import Testing
@testable import VMCore

@MainActor
private final class FakeBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    /// The options of every start attempt, in order.
    var starts: [VMStartOptions] = []
    var startError: (any Error)?

    func start(options: VMStartOptions) async throws {
        starts.append(options)
        if let startError { throw startError }
    }

    /// How many times the guest was asked to shut down.
    var stopRequests = 0

    func requestStop() throws { stopRequests += 1 }
    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws { try Data("state".utf8).write(to: url) }
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func invalidate() {}

    /// Drives plugged into the running guest, in order.
    var drives: [RemovableImage] = []
    var driveError: (any Error)?
    var capturesSystemKeys: Bool?

    func attachRemovableImage(_ image: RemovableImage) async throws {
        if let driveError { throw driveError }
        drives.append(image)
    }

    func detachRemovableImage(_ id: UUID) async throws {
        if let driveError { throw driveError }
        drives.removeAll { $0.id == id }
    }

    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {
        self.capturesSystemKeys = capturesSystemKeys
    }
}

@MainActor
private final class FakeProvider: VMBackendProvider {
    let backend = FakeBackend()

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend { backend }
    func backendDidStop(for machine: VirtualMachine) {}
}

@MainActor
@Suite struct VirtualMachineStartTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
    private let provider = FakeProvider()
    private let account = GuestProvisioning(fullName: "Test User", userName: "tester", password: "secret")

    private func makeMachine(family: GuestFamily = .macOS) throws -> VirtualMachine {
        let configuration = VMConfiguration(name: "Mac", os: GuestOS(family: family), cpuCount: 4, memorySize: 8 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        machine.isHostLocked = { false }
        return machine
    }

    @Test func handsOverTheAccountOnTheFirstStartOnly() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        machine.pendingProvisioning = account

        await machine.start()
        #expect(machine.state == .running)
        #expect(provider.backend.starts == [VMStartOptions(provisioning: account)])
        #expect(machine.pendingProvisioning == nil)
        #expect(machine.configuration.installation.isProvisioned)
        // The flag is on disk, so a relaunched app doesn't offer an account again either.
        #expect(try machine.bundle.loadConfiguration().installation.isProvisioned)

        await machine.forceStop()
        machine.pendingProvisioning = account
        await machine.start()
        #expect(provider.backend.starts.last == VMStartOptions())
    }

    @Test func nothingStartsOnceTheLibraryIsClosedForStarts() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(rootDirectory: directory.appending(path: "library"))
        library.backendProvider = provider
        let configuration = VMConfiguration(name: "Mac", os: GuestOS(family: .macOS), cpuCount: 4, memorySize: 8 << 30, disks: [])
        let machine = try library.add(VMBundle.create(at: library.availableBundleURL(forName: "Mac"), configuration: configuration))
        machine.isHostLocked = { false }

        library.allowsStarting = false
        await machine.start()
        #expect(machine.state == .stopped)
        #expect(provider.backend.starts.isEmpty)
        #expect(machine.lastError == nil)

        // A suspended machine is left with its saved memory, to be resumed another time.
        library.allowsStarting = true
        await machine.start()
        await machine.suspend()
        #expect(machine.state == .suspended)
        library.allowsStarting = false
        await machine.start()
        #expect(machine.state == .suspended)
        #expect(machine.bundle.hasSavedState)
        #expect(provider.backend.starts.count == 1)
    }

    @Test func keepsTheAccountWhenTheFirstStartFails() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        machine.pendingProvisioning = account
        provider.backend.startError = VMError.invalidConfiguration("no")

        await machine.start()
        #expect(machine.state == .stopped)
        #expect(machine.lastError != nil)
        #expect(machine.pendingProvisioning == account)
        #expect(!machine.configuration.installation.isProvisioned)

        provider.backend.startError = nil
        await machine.start()
        #expect(provider.backend.starts.last?.provisioning == account)
        #expect(machine.configuration.installation.isProvisioned)
    }

    @Test func recoveryStartLeavesTheAccountForTheRealFirstBoot() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        machine.pendingProvisioning = account

        await machine.start(inRecovery: true)
        #expect(provider.backend.starts == [VMStartOptions(startsInRecovery: true)])
        #expect(machine.pendingProvisioning == account)
        #expect(!machine.configuration.installation.isProvisioned)
    }

    @Test func resumesFromSavedStateWithoutOtherOptions() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try makeMachine()
        await machine.start()
        await machine.suspend()
        #expect(machine.state == .suspended)

        await machine.start(inRecovery: true)
        #expect(machine.state == .running)
        #expect(provider.backend.starts.last == VMStartOptions(savedState: machine.bundle.savedStateURL))
        #expect(!machine.bundle.hasSavedState)
    }
}

@MainActor
@Suite struct VirtualMachineShutdownTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
    private let provider = FakeProvider()

    private func makeRunningMachine(family: GuestFamily = .macOS) async throws -> VirtualMachine {
        let configuration = VMConfiguration(name: "Mac", os: GuestOS(family: family), cpuCount: 4, memorySize: 8 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        machine.isHostLocked = { false }
        await machine.start()
        return machine
    }

    private func wait(for machine: VirtualMachine, toBe state: VMState) async {
        for _ in 0..<200 where machine.state != state {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func goesBackToRunningWhenTheGuestDoesNotShutDown() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await makeRunningMachine()
        machine.shutdownRequestTimeout = .milliseconds(50)

        await machine.shutDown()
        #expect(machine.state == .stopping)
        await wait(for: machine, toBe: .running)
        #expect(machine.state == .running)
        #expect(machine.lastError == nil)

        // It can be asked again, and a guest that does shut down ends up stopped.
        await machine.shutDown()
        #expect(machine.state == .stopping)
        provider.backend.eventHandler?(.guestDidStop)
        #expect(machine.state == .stopped)
    }

    @Test func anUnansweredRestartDoesNotRestartLater() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await makeRunningMachine()
        machine.shutdownRequestTimeout = .milliseconds(50)

        await machine.restart()
        await wait(for: machine, toBe: .running)
        #expect(provider.backend.starts.count == 1)

        // The guest shuts down on its own much later: that is not the restart that was asked for.
        provider.backend.eventHandler?(.guestDidStop)
        try await Task.sleep(for: .milliseconds(50))
        #expect(machine.state == .stopped)
        #expect(provider.backend.starts.count == 1)
    }

    @Test func aStoppedGuestIsNotRevivedByTheExpiredRequest() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await makeRunningMachine()
        machine.shutdownRequestTimeout = .milliseconds(50)

        await machine.shutDown()
        provider.backend.eventHandler?(.guestDidStop)
        try await Task.sleep(for: .milliseconds(150))
        #expect(machine.state == .stopped)
    }

    @Test func keepsAskingAGuestThatWasNotListeningYet() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await makeRunningMachine(family: .linux)
        machine.shutdownRequestTimeout = .milliseconds(400)
        machine.shutdownRequestRepeatInterval = .milliseconds(30)

        await machine.shutDown()
        #expect(provider.backend.stopRequests == 1)
        for _ in 0..<100 where provider.backend.stopRequests < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(provider.backend.stopRequests >= 3)

        // Once the guest has gone, nobody asks any more.
        provider.backend.eventHandler?(.guestDidStop)
        let requests = provider.backend.stopRequests
        try await Task.sleep(for: .milliseconds(120))
        #expect(provider.backend.stopRequests == requests)
        #expect(machine.state == .stopped)
    }

    @Test func aGuestThatAsksOnItsScreenIsOnlyAskedOnce() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = try await makeRunningMachine(family: .macOS)
        machine.shutdownRequestTimeout = .milliseconds(200)
        machine.shutdownRequestRepeatInterval = .milliseconds(20)

        await machine.shutDown()
        await wait(for: machine, toBe: .running)
        #expect(provider.backend.stopRequests == 1)
    }

    @Test func macOSGuestsAskBeforeShuttingDown() {
        let mac = VMConfiguration(name: "Mac", os: GuestOS(family: .macOS), cpuCount: 4, memorySize: 8 << 30, disks: [])
        let linux = VMConfiguration(name: "Linux", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [])
        #expect(mac.asksBeforeShuttingDown)
        #expect(!linux.asksBeforeShuttingDown)
    }
}

@Suite struct GuestProvisioningTests {
    @Test func acceptsOrdinaryAccountNames() {
        #expect(GuestProvisioning.problem(withUserName: "saeed") == nil)
        #expect(GuestProvisioning.problem(withUserName: "build-agent_2") == nil)
        #expect(GuestProvisioning.problem(withUserName: "j.appleseed") == nil)
    }

    @Test func rejectsNamesMacOSWouldRefuse() {
        #expect(GuestProvisioning.problem(withUserName: "") != nil)
        #expect(GuestProvisioning.problem(withUserName: "Saeed") != nil)
        #expect(GuestProvisioning.problem(withUserName: "2fast") != nil)
        #expect(GuestProvisioning.problem(withUserName: "with space") != nil)
        #expect(GuestProvisioning.problem(withUserName: "root") != nil)
        #expect(GuestProvisioning.problem(withUserName: String(repeating: "a", count: 33)) != nil)
    }
}

@MainActor
@Suite struct VMLibraryStagingTests {
    private func configuration(named name: String) -> VMConfiguration {
        VMConfiguration(name: name, os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [])
    }

    @Test func stagedBundlesJoinTheLibraryUnderTheMachineName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VMLibrary(rootDirectory: root)
        library.load()

        let staged = try VMBundle.create(at: library.makeStagingBundleURL(), configuration: configuration(named: "Web Server"))
        // Not a machine yet, even if the library is reloaded while it is being put together.
        library.load()
        #expect(library.machines.isEmpty)

        let machine = try library.add(staged: staged)
        #expect(machine.bundle.url.lastPathComponent == "Web Server.swiftvm")
        #expect(machine.bundle.url.deletingLastPathComponent().path == library.machinesDirectory.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
        #expect(library.machines.map(\.name) == ["Web Server"])

        // A second machine with the same name gets its own bundle.
        let twin = try VMBundle.create(at: library.makeStagingBundleURL(), configuration: configuration(named: "Web Server"))
        #expect(try library.add(staged: twin).bundle.url.lastPathComponent == "Web Server 2.swiftvm")
    }

    @Test func leftoversOfUnfinishedCreationsAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VMLibrary(rootDirectory: root)
        library.load()
        let finished = try library.add(staged: VMBundle.create(at: library.makeStagingBundleURL(), configuration: configuration(named: "Done")))
        let abandoned = try VMBundle.create(at: library.makeStagingBundleURL(), configuration: configuration(named: "Half"))

        library.removeStagedBundles()
        library.load()
        #expect(!FileManager.default.fileExists(atPath: abandoned.url.path))
        #expect(FileManager.default.fileExists(atPath: finished.bundle.url.path))
        #expect(library.machines.map(\.name) == ["Done"])
    }
}
