import AppKit
import Foundation
import Testing
@testable import VMCore

/// A guest that starts, saves its memory and stops at once, and does nothing else.
@MainActor
private final class StubBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true

    func start(options: VMStartOptions) async throws {}
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
private final class StubProvider: VMBackendProvider {
    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend { StubBackend() }
    func backendDidStop(for machine: VirtualMachine) {}
}

/// A scratch folder with a library of templates in it, and machines to save as templates.
@MainActor
private struct Scratch {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)").standardizedFileURL
    let provider = StubProvider()

    var root: URL { directory.appending(path: "library") }

    func makeLibrary() -> VMTemplateLibrary {
        let library = VMTemplateLibrary(rootDirectory: root)
        library.load()
        return library
    }

    /// A Mac that is shut down, with everything in its bundle that a machine can have there.
    func makeMachine() throws -> VirtualMachine {
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(
            name: "Box", os: GuestOS(family: .macOS), cpuCount: 2, memorySize: 4 << 30, disks: [disk],
            networkInterfaces: [NetworkInterfaceConfiguration(macAddress: "02:00:00:00:00:01", ipv4Address: "192.168.230.10")],
            ssh: SSHConfiguration(alias: "box", user: "me")
        )
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        try Data("first".utf8).write(to: bundle.diskURL(for: disk))
        for url in [bundle.auxiliaryStorageURL, bundle.hardwareModelURL, bundle.machineIdentifierURL, bundle.consoleLogURL] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        // Whatever the Mac running the tests is doing.
        machine.isHostLocked = { false }
        return machine
    }

    func writeDisk(_ contents: String, of machine: VirtualMachine) throws {
        try Data(contents.utf8).write(to: machine.bundle.url.appending(path: "disk.img"))
    }

    func diskContents(of template: VMTemplate, in library: VMTemplateLibrary) throws -> String {
        let package = try #require(library.bundle(of: template))
        return try String(contentsOf: package.url.appending(path: "disk.img"), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite struct TemplateTests {
    private let scratch = Scratch()

    @Test func aTemplateKeepsDisksAndFirmwareButNotIdentityOrHistory() async throws {
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.makeMachine()
        try await machine.takeSnapshot(named: "Before")

        let template = try await library.save(machine, named: "Golden")
        let package = try #require(library.bundle(of: template))
        #expect(package.url.lastPathComponent == "Golden.swiftvmtemplate")
        let names = try FileManager.default.contentsOfDirectory(atPath: package.url.path).sorted()
        #expect(names == ["aux.img", "disk.img", "hardware-model.bin", "template.json"])
        #expect(library.templates == [template])
        #expect(machine.activity == nil)

        // What happens in the machine afterwards doesn't reach the template.
        try scratch.writeDisk("second", of: machine)
        #expect(try scratch.diskContents(of: template, in: library) == "first")
        // A library that starts afresh finds the template in its folder.
        #expect(scratch.makeLibrary().templates.map(\.id) == [template.id])
    }

    @Test func onlyAMachineThatIsShutDownIsSaved() async throws {
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.makeMachine()
        await machine.start()

        await #expect(throws: VMError.self) { try await library.save(machine) }
        #expect(library.templates.isEmpty)
        #expect(machine.activity == nil)
        // Nothing of a template that wasn't saved is in the folder, or taking up a name.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: library.directory.path)) ?? []).isEmpty)
        #expect(!library.isNameTaken("Box"))
    }

    @Test func aSaveThatIsCalledOffLeavesNothingBehind() async throws {
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.makeMachine()

        // Called off before it has begun, which is the same to it as at any moment later.
        let save = Task { try await library.save(machine) }
        save.cancel()
        await #expect(throws: CancellationError.self) { try await save.value }
        #expect(library.templates.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: library.directory.path)) ?? []).isEmpty)
        // The machine and the name are free for the next try.
        #expect(machine.activity == nil)
        #expect(try await library.save(machine).name == "Box")
    }

    @Test func aMachineMadeFromATemplateIsAMachineOfItsOwn() async throws {
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.makeMachine()
        let template = try await library.save(machine)
        #expect(template.name == "Box")

        let configuration = template.machineConfiguration(
            name: "Box 2", sshAlias: "box-2", cpuCount: 6, memorySize: 8 << 30, diskCapacity: 2 << 20
        )
        #expect(configuration.id != machine.id)
        #expect(configuration.name == "Box 2")
        #expect(configuration.ssh == SSHConfiguration(alias: "box-2", user: "me"))
        #expect(configuration.cpuCount == 6)
        #expect(configuration.memorySize == 8 << 30)
        #expect(configuration.disks[0].capacity == 2 << 20)
        #expect(configuration.networkInterfaces[0].macAddress != "02:00:00:00:00:01")
        #expect(configuration.networkInterfaces[0].ipv4Address == nil)
        // Without anything asked for it has the template's hardware. A disk doesn't shrink.
        let plain = template.machineConfiguration(name: "Box 3", sshAlias: "box-3", diskCapacity: 1)
        #expect(plain.cpuCount == 2)
        #expect(plain.memorySize == 4 << 30)
        #expect(plain.disks[0].capacity == 1 << 20)

        let source = try #require(library.bundle(of: template))
        let copy = try source.duplicate(to: scratch.directory.appending(path: "Box 2.swiftvm"), configuration: configuration)
        let names = try FileManager.default.contentsOfDirectory(atPath: copy.url.path).sorted()
        #expect(names == ["aux.img", "config.json", "disk.img", "hardware-model.bin", "logs"])
        #expect(try String(contentsOf: copy.diskURL(for: configuration.disks[0]), encoding: .utf8) == "first")
        #expect(try copy.loadConfiguration().id == configuration.id)
    }

    @Test func aSnapshotTakenWhileShutDownMakesATemplate() async throws {
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.makeMachine()
        let clean = try await machine.takeSnapshot(named: "Clean")
        try scratch.writeDisk("second", of: machine)

        // Nothing writes to a snapshot, so the machine can be up meanwhile, and stays up.
        await machine.start()
        let template = try await library.save(machine, at: clean)
        #expect(template.name == "Box (Clean)")
        #expect(try scratch.diskContents(of: template, in: library) == "first")
        #expect(machine.state == .running)
        #expect(machine.activity == nil)

        // The memory of a guest that was running belongs to its machine, and makes no template.
        let live = try await machine.takeSnapshot(named: "Live")
        #expect(live.includesMemory)
        await #expect(throws: VMError.self) { try await library.save(machine, at: live) }
        #expect(library.templates.map(\.id) == [template.id])
    }

    @Test func templatesAreRenamedAndDeleted() async throws {
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.makeMachine()
        let golden = try await library.save(machine, named: "Golden")
        let second = try await library.save(machine)

        // A template is asked for by its name, so no two have the same.
        await #expect(throws: VMError.self) { try await library.save(machine, named: "golden") }
        #expect(throws: VMError.self) { try library.rename(second, to: "Golden") }
        try library.rename(second, to: "Silver")
        #expect(scratch.makeLibrary().templates.map(\.name) == ["Golden", "Silver"])

        // A template that a machine is being made from stays until that is over.
        await library.whileUsing(golden) { () -> Void in
            #expect(throws: VMError.self) { try library.remove(golden, movingToTrash: false) }
        }
        try library.remove(golden, movingToTrash: false)
        #expect(library.templates.map(\.name) == ["Silver"])
        #expect(scratch.makeLibrary().templates.map(\.name) == ["Silver"])
    }

    @Test func templatesAreKeptInTheFolderThatWasChosen() async throws {
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let elsewhere = scratch.directory.appending(path: "elsewhere", directoryHint: .isDirectory)
        try library.setDirectory(elsewhere)

        let template = try await library.save(try scratch.makeMachine())
        #expect(library.bundle(of: template)?.url.deletingLastPathComponent().path == elsewhere.path)

        // The choice outlives the app.
        let reloaded = scratch.makeLibrary()
        #expect(reloaded.directory.path == elsewhere.path)
        #expect(reloaded.templates.map(\.id) == [template.id])
        // Back in the default folder, what is kept elsewhere stays there and isn't listed.
        try reloaded.setDirectory(nil)
        #expect(reloaded.templates.isEmpty)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "Box.swiftvmtemplate").path))
    }
}
