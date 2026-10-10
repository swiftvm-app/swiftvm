import AppKit
import Foundation
import Testing
@testable import VMCore

/// A backend that keeps track of what it is asked to do with drives and can fail on demand.
@MainActor
private final class DriveBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    var starts: [VMStartOptions] = []
    var stopCount = 0
    var drives: [RemovableImage] = []
    var driveError: (any Error)?
    var saveError: (any Error)?
    var startError: (any Error)?
    /// Runs while the guest's memory is being saved, for things that happen in the middle of a suspend.
    var whileSaving: (() -> Void)?
    var capturesSystemKeys: Bool?

    func start(options: VMStartOptions) async throws {
        starts.append(options)
        if let startError { throw startError }
    }
    func requestStop() throws {}
    func stop() async throws { stopCount += 1 }
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws {
        whileSaving?()
        if let saveError { throw saveError }
        try Data("memory".utf8).write(to: url)
    }
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func invalidate() {}

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

    func connectToGuest(port: UInt32) async throws -> FileHandle {
        throw POSIXError(.ECONNRESET)
    }
}

@MainActor
private final class DriveProvider: VMBackendProvider {
    let backend = DriveBackend()

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend { backend }
    func backendDidStop(for machine: VirtualMachine) {}
}

/// A machine in a scratch folder with one small "disk" whose contents the tests can change.
@MainActor
private struct Scratch {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
    let provider = DriveProvider()

    /// Machines made here believe the Mac is unlocked, whatever the Mac running the tests is doing.
    func makeMachine(family: GuestFamily = .linux) throws -> VirtualMachine {
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(
            name: "Box", os: GuestOS(family: family), cpuCount: 2, memorySize: 4 << 30, disks: [disk],
            networkInterfaces: [NetworkInterfaceConfiguration(macAddress: "02:00:00:00:00:01", ipv4Address: "192.168.230.10")],
            ssh: SSHConfiguration(alias: "box", user: "me")
        )
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        try Data("first".utf8).write(to: bundle.diskURL(for: disk))
        try Data("nvram".utf8).write(to: bundle.efiVariableStoreURL)
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        machine.isHostLocked = { false }
        return machine
    }

    func makeImage(named name: String = "installer.iso") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data("image".utf8).write(to: url)
        return url
    }

    func diskContents(of machine: VirtualMachine) throws -> String {
        try String(contentsOf: machine.bundle.url.appending(path: "disk.img"), encoding: .utf8)
    }

    func writeDisk(_ contents: String, of machine: VirtualMachine) throws {
        try Data(contents.utf8).write(to: machine.bundle.url.appending(path: "disk.img"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite struct RemovableDriveTests {
    private let scratch = Scratch()

    @Test func aStoppedMachineJustRemembersTheDrive() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let image = RemovableImage(url: try scratch.makeImage())

        try await machine.attachImage(image)
        #expect(machine.configuration.removableImages == [image])
        #expect(try machine.bundle.loadConfiguration().removableImages == [image])
        #expect(scratch.provider.backend.drives.isEmpty)

        try await machine.ejectImage(image.id)
        #expect(machine.configuration.removableImages.isEmpty)
    }

    @Test func aRunningMachineGetsTheDriveRightAway() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        let image = RemovableImage(url: try scratch.makeImage())

        try await machine.attachImage(image)
        #expect(scratch.provider.backend.drives == [image])
        #expect(machine.configuration.removableImages == [image])

        try await machine.ejectImage(image.id)
        #expect(scratch.provider.backend.drives.isEmpty)
        #expect(try machine.bundle.loadConfiguration().removableImages.isEmpty)
    }

    @Test func aDriveTheGuestRefusesIsNotRemembered() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        scratch.provider.backend.driveError = VMError.invalidConfiguration("not a disk image")

        await #expect(throws: VMError.self) {
            try await machine.attachImage(RemovableImage(url: try scratch.makeImage()))
        }
        #expect(machine.configuration.removableImages.isEmpty)
    }

    @Test func refusesWhatCanNotBeADrive() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let image = RemovableImage(url: try scratch.makeImage())
        try await machine.attachImage(image)

        // The same image twice, a folder, and a file that isn't there.
        await #expect(throws: VMError.self) { try await machine.attachImage(RemovableImage(url: image.url)) }
        await #expect(throws: VMError.self) { try await machine.attachImage(RemovableImage(url: scratch.directory)) }
        await #expect(throws: VMError.self) {
            try await machine.attachImage(RemovableImage(url: scratch.directory.appending(path: "missing.iso")))
        }
        #expect(machine.configuration.removableImages == [image])
    }

    @Test func aSuspendedMachineKeepsTheDrivesItWasSavedWith() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let image = RemovableImage(url: try scratch.makeImage())
        try await machine.attachImage(image)
        await machine.start()
        await machine.suspend()
        #expect(machine.state == .suspended)

        await #expect(throws: VMError.self) { try await machine.ejectImage(image.id) }
        await #expect(throws: VMError.self) {
            try await machine.attachImage(RemovableImage(url: try scratch.makeImage(named: "other.iso")))
        }
        #expect(machine.configuration.removableImages == [image])
    }

    @Test func discImagesAreAlwaysReadOnly() {
        #expect(RemovableImage(url: URL(fileURLWithPath: "/tmp/Ubuntu.ISO")).readOnly)
        #expect(!RemovableImage(url: URL(fileURLWithPath: "/tmp/data.img")).readOnly)
        #expect(RemovableImage(url: URL(fileURLWithPath: "/tmp/data.img"), readOnly: true).readOnly)
        #expect(RemovableImage(url: URL(fileURLWithPath: "/tmp/a/../data.img")).path == "/tmp/data.img")
    }

    @Test func keyCaptureAppliesToARunningGuest() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        #expect(machine.configuration.keyboard.capturesSystemKeys)
        await machine.start()

        try machine.updateConfiguration { $0.keyboard.capturesSystemKeys = false }
        #expect(scratch.provider.backend.capturesSystemKeys == false)
    }
}

@MainActor
@Suite struct SnapshotTests {
    private let scratch = Scratch()

    @Test func goesBackToTheDiskAsItWas() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()

        let snapshot = try await machine.takeSnapshot(named: "  Clean install ")
        #expect(snapshot.name == "Clean install")
        #expect(!snapshot.includesMemory)
        #expect(machine.snapshots == [snapshot])
        #expect(machine.activity == nil)

        try scratch.writeDisk("second", of: machine)
        try Data("changed".utf8).write(to: machine.bundle.efiVariableStoreURL)
        try await machine.revert(to: snapshot)
        #expect(try scratch.diskContents(of: machine) == "first")
        #expect(try String(contentsOf: machine.bundle.efiVariableStoreURL, encoding: .utf8) == "nvram")
        #expect(machine.state == .stopped)

        // The snapshot is still there, and a machine opened later finds it.
        #expect(machine.snapshots == [snapshot])
        #expect(try VirtualMachine(bundle: machine.bundle).snapshots.map(\.id) == [snapshot.id])
    }

    @Test func aRunningGuestIsSuspendedForTheSnapshotAndCarriesOn() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()

        var resumes = 0
        machine.onResume = { _ in resumes += 1 }
        let snapshot = try await machine.takeSnapshot()
        #expect(snapshot.name == "Snapshot 1")
        #expect(snapshot.includesMemory)
        #expect(machine.state == .running)
        // The guest missed a moment, so whoever keeps its clock right is told.
        #expect(resumes == 1)
        #expect(scratch.provider.backend.starts.last?.savedState == machine.bundle.savedStateURL)
        #expect(!machine.bundle.hasSavedState)

        // Going back stops the guest and leaves it suspended at the moment of the snapshot.
        try scratch.writeDisk("second", of: machine)
        try await machine.revert(to: snapshot)
        #expect(machine.state == .suspended)
        #expect(try scratch.diskContents(of: machine) == "first")
        #expect(try String(contentsOf: machine.bundle.savedStateURL, encoding: .utf8) == "memory")
    }

    @Test func aPausedGuestIsPausedAgainAfterTheSnapshot() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        await machine.pause()

        let snapshot = try await machine.takeSnapshot()
        #expect(snapshot.includesMemory)
        #expect(machine.state == .paused)
    }

    @Test func revertingToADiskOnlySnapshotDropsSavedMemory() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let snapshot = try await machine.takeSnapshot()
        await machine.start()
        await machine.suspend()
        #expect(machine.bundle.hasSavedState)

        try await machine.revert(to: snapshot)
        #expect(machine.state == .stopped)
        #expect(!machine.bundle.hasSavedState)
    }

    @Test func theGuestCarriesOnWhenTheSnapshotCanNotBeTaken() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        scratch.provider.backend.saveError = VMError.invalidConfiguration("can't save")

        await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        #expect(machine.state == .running)
        #expect(machine.snapshots.isEmpty)
        #expect(machine.activity == nil)
        #expect(machine.lastError == nil)
    }

    @Test func aSnapshotThatCanNotBeUsedCostsTheRunningGuestNothing() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let snapshot = try await machine.takeSnapshot()
        await machine.start()
        // Gone behind the app's back.
        try FileManager.default.removeItem(at: machine.bundle.snapshotURL(for: snapshot.id))

        await #expect(throws: (any Error).self) { try await machine.revert(to: snapshot) }
        #expect(machine.state == .running)
        #expect(scratch.provider.backend.stopCount == 0)
        #expect(machine.activity == nil)
    }

    @Test func aRevertThatFailsHalfwayNeverLeavesMemoryForTheWrongDisk() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        let snapshot = try await machine.takeSnapshot()
        try scratch.writeDisk("second", of: machine)

        // The files go back, but the configuration that belongs with the saved memory can't be written.
        let configurationURL = machine.bundle.configurationURL
        try FileManager.default.removeItem(at: configurationURL)
        try FileManager.default.createDirectory(at: configurationURL.appending(path: "in the way"), withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) { try await machine.revert(to: snapshot) }
        // The machine says what its files say: shut down, on the snapshot's disk, with nothing to resume.
        #expect(machine.state == .stopped)
        #expect(!machine.bundle.hasSavedState)
        #expect(try scratch.diskContents(of: machine) == "first")
        #expect(machine.activity == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: machine.bundle.url.path).filter { $0.hasPrefix(".reverting-") }
        #expect(leftovers.isEmpty)
    }

    @Test func aBootThrowsAwayMemoryItIsNotResuming() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        // Saved memory that the machine doesn't know of, as a revert that was cut short could leave it.
        try Data("stale".utf8).write(to: machine.bundle.savedStateURL)
        #expect(machine.state == .stopped)

        await machine.start()
        #expect(scratch.provider.backend.starts.last?.savedState == nil)
        #expect(!machine.bundle.hasSavedState)
        // Had it stayed, the next launch would have offered to resume it over a disk that has moved on.
        await machine.forceStop()
        #expect(try VirtualMachine(bundle: machine.bundle).state == .stopped)
    }

    @Test func copiesOfAnUnfinishedRevertAreClearedWhenTheMachineIsOpened() throws {
        defer { scratch.cleanUp() }
        let bundle = try scratch.makeMachine().bundle
        let leftover = bundle.url.appending(path: ".reverting-disk.img")
        try Data("half a copy".utf8).write(to: leftover)

        let machine = try VirtualMachine(bundle: bundle)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try scratch.diskContents(of: machine) == "first")
    }

    @Test func aDriveTheGuestWritesToKeepsARunningMachineFromBeingSnapshotted() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        try await machine.attachImage(RemovableImage(url: try scratch.makeImage(named: "data.img")))

        // Shut down, there is no memory that could disagree with the drive later.
        #expect(try await machine.takeSnapshot().includesMemory == false)

        await machine.start()
        await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        #expect(machine.state == .running)
        #expect(machine.activity == nil)
        #expect(machine.snapshots.count == 1)

        // A disc the guest can only read is no obstacle.
        try await machine.ejectImage(machine.configuration.removableImages[0].id)
        try await machine.attachImage(RemovableImage(url: try scratch.makeImage(named: "installer.iso")))
        #expect(try await machine.takeSnapshot().includesMemory)
    }

    @Test func aRestartIsNotLostToWorkOnTheMachinesFiles() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()

        await machine.restart()
        scratch.provider.backend.eventHandler?(.guestDidStop)
        // The guest is down and its start hasn't begun: the machine looks idle, but it isn't free.
        #expect(machine.state == .stopped)
        await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        await #expect(throws: VMError.self) { try await machine.whileStopped(.duplicating) {} }

        for _ in 0..<200 where machine.state != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(machine.state == .running)
        #expect(scratch.provider.backend.starts.count == 2)
    }

    @Test func aGuestThatStopsWhileBeingSuspendedStaysStopped() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        let backend = scratch.provider.backend
        backend.whileSaving = { backend.eventHandler?(.guestDidStop) }
        backend.saveError = VMError.invalidConfiguration("the guest is gone")

        await machine.suspend()
        #expect(machine.state == .stopped)
        #expect(!machine.bundle.hasSavedState)
        #expect(machine.lastError != nil)

        // It is an ordinary shut-down machine again, not one that claims to run without a guest.
        backend.whileSaving = nil
        backend.saveError = nil
        await machine.start()
        #expect(machine.state == .running)
    }

    @Test func aRunningGuestIsNotSuspendedForASnapshotWhileTheMacIsLocked() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        machine.isHostLocked = { true }

        // It couldn't be resumed afterwards, so it is left alone.
        await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        #expect(machine.state == .running)
        #expect(scratch.provider.backend.stopCount == 0)
        #expect(machine.snapshots.isEmpty)

        // A machine that isn't running needs no resuming: suspended or shut down, it can be snapshotted.
        await machine.suspend()
        #expect(try await machine.takeSnapshot().includesMemory)
        #expect(machine.state == .suspended)
    }

    @Test func sayWhyAGuestCanNotBeResumedWhileTheMacIsLocked() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        await machine.start()
        await machine.suspend()
        machine.isHostLocked = { true }
        scratch.provider.backend.startError = VMError.invalidConfiguration("permission denied")

        await machine.start()
        #expect(machine.state == .suspended)
        #expect(machine.bundle.hasSavedState)
        #expect(machine.lastError?.message.contains("This Mac is locked") == true)
        // Nothing is wrong with the saved memory, so nobody is told to throw it away.
        #expect(machine.lastError?.message.contains("Discard") == false)

        machine.isHostLocked = { false }
        await machine.start()
        #expect(machine.lastError?.message.contains("Discard Saved State") == true)

        scratch.provider.backend.startError = nil
        await machine.start()
        #expect(machine.state == .running)
    }

    @Test func hardwareComesBackButHostSettingsStay() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let snapshot = try await machine.takeSnapshot()

        try machine.updateConfiguration { configuration in
            configuration.name = "Renamed"
            configuration.cpuCount = 8
            configuration.disks[0].capacity = 2 << 20
            configuration.sharedFolders = [SharedFolder(name: "Projects", path: "/tmp/projects")]
            configuration.networkInterfaces[0].ipv4Address = "192.168.231.10"
            configuration.networkInterfaces[0].portForwards = [PortForward(hostPort: 8080, guestPort: 80)]
            configuration.ssh.user = "admin"
        }
        try await machine.revert(to: snapshot)

        let configuration = machine.configuration
        #expect(configuration.cpuCount == 2)
        #expect(configuration.disks[0].capacity == 1 << 20)
        #expect(configuration.name == "Renamed")
        #expect(configuration.sharedFolders.map(\.name) == ["Projects"])
        #expect(configuration.networkInterfaces[0].ipv4Address == "192.168.231.10")
        #expect(configuration.networkInterfaces[0].portForwards.map(\.hostPort) == [8080])
        #expect(configuration.networkInterfaces[0].macAddress == "02:00:00:00:00:01")
        #expect(configuration.ssh.user == "admin")
        #expect(try machine.bundle.loadConfiguration() == configuration)
    }

    @Test func drivesFollowTheSnapshotOnlyWhenItHoldsMemory() throws {
        let base = VMConfiguration(name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [])
        var then = base
        then.removableImages = [RemovableImage(path: "/tmp/then.iso", readOnly: true)]
        var now = base
        now.removableImages = [RemovableImage(path: "/tmp/now.iso", readOnly: true)]

        let cold = VMSnapshot(name: "Cold", includesMemory: false, configuration: then)
        #expect(now.reverted(to: cold).removableImages.map(\.path) == ["/tmp/now.iso"])
        let warm = VMSnapshot(name: "Warm", includesMemory: true, configuration: then)
        #expect(now.reverted(to: warm).removableImages.map(\.path) == ["/tmp/then.iso"])
    }

    @Test func deletesSnapshotsAndNamesTheNextOne() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let first = try await machine.takeSnapshot()
        let second = try await machine.takeSnapshot()
        #expect([first.name, second.name] == ["Snapshot 1", "Snapshot 2"])

        try machine.deleteSnapshot(first)
        #expect(machine.snapshots == [second])
        #expect(!FileManager.default.fileExists(atPath: machine.bundle.snapshotURL(for: first.id).path))
        // "Snapshot 2" is taken, so the next one doesn't reuse it.
        #expect(try await machine.takeSnapshot().name == "Snapshot 3")
    }

    @Test func renamesASnapshot() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let snapshot = try await machine.takeSnapshot()

        try machine.renameSnapshot(snapshot, to: "  Before the upgrade ")
        #expect(machine.snapshots.map(\.name) == ["Before the upgrade"])
        #expect(machine.bundle.loadSnapshots().map(\.name) == ["Before the upgrade"])
        // Nothing else about it changes, and it can still be gone back to.
        #expect(machine.snapshots[0].id == snapshot.id)
        #expect(machine.snapshots[0].createdAt == snapshot.createdAt)
        try scratch.writeDisk("second", of: machine)
        try await machine.revert(to: machine.snapshots[0])
        #expect(try scratch.diskContents(of: machine) == "first")

        try machine.renameSnapshot(machine.snapshots[0], to: "   ")
        #expect(machine.snapshots.map(\.name) == ["Before the upgrade"])
    }

    @Test func aHalfWrittenSnapshotIsNeverListed() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()
        let leftover = machine.bundle.snapshotsDirectory.appending(path: ".new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: leftover.appending(path: "disk.img"))
        #expect(machine.bundle.loadSnapshots().isEmpty)

        // The next snapshot clears it away.
        try await machine.takeSnapshot()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(machine.bundle.loadSnapshots().count == 1)
    }

    @Test func aMachineCanNotBeStartedWhileItsFilesAreWorkedOn() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine()

        try await machine.whileStopped(.resizingDisk) {
            #expect(machine.activity == .resizingDisk)
            await machine.start()
            #expect(machine.state == .stopped)
            await #expect(throws: VMError.self) { try await machine.takeSnapshot() }
        }
        #expect(machine.activity == nil)

        await machine.start()
        #expect(machine.state == .running)
        // Work that needs the machine shut down is refused, and the claim is given back.
        await #expect(throws: VMError.self) { try await machine.whileStopped(.duplicating) {} }
        #expect(machine.activity == nil)
    }
}

@Suite struct DuplicateTests {
    @Test func aCopyIsAMachineOfItsOwn() {
        var original = VMConfiguration(
            name: "Web", os: GuestOS(family: .linux), cpuCount: 4, memorySize: 8 << 30,
            disks: [DiskConfiguration(fileName: "disk.img", capacity: 64 << 30, format: .raw)],
            removableImages: [
                RemovableImage(path: "/tmp/installer.iso", readOnly: true),
                RemovableImage(path: "/tmp/data.img", readOnly: false),
            ],
            networkInterfaces: [NetworkInterfaceConfiguration(
                macAddress: "02:00:00:00:00:01", ipv4Address: "192.168.230.10",
                portForwards: [PortForward(hostPort: 8080, guestPort: 80)]
            )],
            sharedFolders: [SharedFolder(name: "Projects", path: "/tmp/projects")],
            ssh: SSHConfiguration(alias: "web", user: "me", identityFile: "/Users/me/.ssh/id_ed25519"),
            installation: InstallationConfiguration(attachesSeedImage: true, isProvisioned: true)
        )
        original.createdAt = Date(timeIntervalSince1970: 0)

        let copy = original.duplicated(name: "Web copy", sshAlias: "web-copy")
        #expect(copy.id != original.id)
        #expect(copy.name == "Web copy")
        #expect(copy.ssh == SSHConfiguration(alias: "web-copy", user: "me", identityFile: "/Users/me/.ssh/id_ed25519"))
        #expect(copy.createdAt > original.createdAt)
        // Same hardware and disks.
        #expect(copy.cpuCount == 4)
        #expect(copy.disks == original.disks)
        #expect(copy.sharedFolders == original.sharedFolders)
        #expect(copy.installation == original.installation)
        // A network card of its own, with nothing that belongs to the original's.
        #expect(copy.networkInterfaces.count == 1)
        #expect(copy.networkInterfaces[0].macAddress != "02:00:00:00:00:01")
        #expect(copy.networkInterfaces[0].ipv4Address == nil)
        #expect(copy.networkInterfaces[0].portForwards.isEmpty)
        // Only drives that two machines can safely have plugged in at once.
        #expect(copy.removableImages.map(\.path) == ["/tmp/installer.iso"])
        #expect(copy.removableImages[0].id != original.removableImages[0].id)
    }

    @Test func copiesDisksAndFirmwareButNotIdentityOrHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(name: "Mac", os: GuestOS(family: .macOS), cpuCount: 4, memorySize: 8 << 30, disks: [disk])
        let original = try VMBundle.create(at: directory.appending(path: "Mac.swiftvm"), configuration: configuration)
        for url in [
            original.diskURL(for: disk), original.auxiliaryStorageURL, original.hardwareModelURL,
            original.machineIdentifierURL, original.savedStateURL, original.consoleLogURL,
        ] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        _ = try original.takeSnapshot(named: "Before", of: configuration)

        let copyConfiguration = configuration.duplicated(name: "Mac copy", sshAlias: "mac-copy")
        let copy = try original.duplicate(to: directory.appending(path: "Mac copy.swiftvm"), configuration: copyConfiguration)
        let names = try FileManager.default.contentsOfDirectory(atPath: copy.url.path).sorted()
        #expect(names == ["aux.img", "config.json", "disk.img", "hardware-model.bin", "logs"])
        #expect(try String(contentsOf: copy.diskURL(for: disk), encoding: .utf8) == "disk.img")
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.logsDirectory.path).isEmpty)
        #expect(try copy.loadConfiguration().name == "Mac copy")
        #expect(copy.loadSnapshots().isEmpty)

        // A bundle that is already there is never written over.
        #expect(throws: (any Error).self) { try original.duplicate(to: copy.url, configuration: copyConfiguration) }
    }
}

@Suite struct ConfigurationMigrationTests {
    @Test func theInstallerDiscOfOlderMachinesBecomesADrive() throws {
        let json = """
        {"id":"7B0C8D56-3A8E-4B43-9C0E-0C5E7B2B8A11","name":"Old","os":{"family":"linux"},"cpuCount":2,"memorySize":4294967296,
         "installation":{"attachesSeedImage":false,"installMediaPath":"/tmp/ubuntu.iso","isProvisioned":false}}
        """
        let first = try JSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))
        #expect(first.removableImages.map(\.path) == ["/tmp/ubuntu.iso"])
        #expect(first.removableImages[0].readOnly)
        // A suspended guest looks for the drive by its identifier, so reading the file twice must agree.
        let second = try JSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))
        #expect(first.removableImages == second.removableImages)

        // Once ejected and saved, the disc doesn't come back.
        var ejected = first
        ejected.removableImages = []
        let saved = try JSONEncoder().encode(ejected)
        #expect(try JSONDecoder().decode(VMConfiguration.self, from: saved).removableImages.isEmpty)
    }

    @Test func forwardedPortsOfOlderMachinesStayPrivate() throws {
        // Written before a forward could be opened to other devices.
        let json = #"{"id":"0D501723-ECC6-4BC6-B65F-0D9A49C3F7BC","transport":"udp","hostPort":5353,"guestPort":53}"#
        let forward = try JSONDecoder().decode(PortForward.self, from: Data(json.utf8))
        #expect(forward == PortForward(
            id: UUID(uuidString: "0D501723-ECC6-4BC6-B65F-0D9A49C3F7BC")!, transport: .udp, hostPort: 5353, guestPort: 53
        ))
        #expect(!forward.allowsOtherDevices)
        #expect(forward.summary == "5353 → 53 (UDP)")
        #expect(PortForward(hostPort: 8080, guestPort: 80).summary == "8080 → 80")
    }

    @Test func newSettingsHaveDefaultsInOlderMachines() throws {
        let json = """
        {"id":"7B0C8D56-3A8E-4B43-9C0E-0C5E7B2B8A11","name":"Old","os":{"family":"macOS"},"cpuCount":2,"memorySize":4294967296,
         "installation":{"attachesSeedImage":false,"isProvisioned":true}}
        """
        let configuration = try JSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))
        #expect(configuration.removableImages.isEmpty)
        #expect(configuration.keyboard.capturesSystemKeys)
        #expect(configuration.installation.isProvisioned)
    }
}
