import Foundation
import Testing
@testable import VMCore

/// A scratch folder with a library in it, and folders next to it that stand for other places to keep
/// machines in.
@MainActor
private struct Scratch {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)").standardizedFileURL

    var root: URL { directory.appending(path: "library") }
    var elsewhere: URL { directory.appending(path: "elsewhere", directoryHint: .isDirectory) }

    func makeLibrary() -> VMLibrary {
        let library = VMLibrary(rootDirectory: root)
        library.load()
        return library
    }

    func configuration(named name: String) -> VMConfiguration {
        VMConfiguration(
            name: name, os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30,
            disks: [DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)],
            networkInterfaces: [NetworkInterfaceConfiguration(ipv4Address: "192.168.230.10")],
            ssh: SSHConfiguration(alias: "web")
        )
    }

    /// A machine that is kept in `folder`, with something on its disk.
    func addMachine(named name: String = "Web", to library: VMLibrary, in folder: URL) throws -> VirtualMachine {
        let staged = try VMBundle.create(at: library.makeStagingBundleURL(in: folder), configuration: configuration(named: name))
        try Data("disk".utf8).write(to: staged.url.appending(path: "disk.img"))
        return try library.add(staged: staged)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@MainActor
@Suite struct MachineLocationTests {
    @Test func aMachineIsMadeInTheFolderThatWasChosenForIt() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()

        let machine = try scratch.addMachine(to: library, in: scratch.elsewhere)
        #expect(machine.bundle.url.path == scratch.elsewhere.appending(path: "Web.swiftvm").path)
        // Nothing of the making is left in a folder of the user's.
        #expect(!exists(VMLibrary.stagingDirectory(in: scratch.elsewhere)))

        // What a creation leaves there when the app is cut off is cleared the next time, by a library
        // that only knows of it from the index. Another copy of the app, with a library of its own,
        // leaves it alone: to that one it may be a machine in the making.
        let abandoned = try VMBundle.create(at: library.makeStagingBundleURL(in: scratch.elsewhere), configuration: scratch.configuration(named: "Half"))
        let otherCopy = VMLibrary(rootDirectory: scratch.directory.appending(path: "other-library"))
        _ = try otherCopy.makeStagingBundleURL(in: scratch.elsewhere)
        otherCopy.removeStagedBundles()
        #expect(exists(abandoned.url))
        let relaunched = VMLibrary(rootDirectory: scratch.root)
        relaunched.removeStagedBundles()
        relaunched.load()
        #expect(!exists(abandoned.url))
        #expect(relaunched.machines.map(\.bundle.url.path) == [machine.bundle.url.path])
    }

    @Test func newMachinesGoToTheFolderThatWasSetForThem() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let first = try scratch.addMachine(named: "First", to: library, in: library.machinesDirectory)

        try library.setMachinesDirectory(scratch.elsewhere)
        let relaunched = scratch.makeLibrary()
        #expect(relaunched.machinesDirectory.path == scratch.elsewhere.path)
        let staged = try VMBundle.create(at: relaunched.makeStagingBundleURL(), configuration: scratch.configuration(named: "Second"))
        #expect(try relaunched.add(staged: staged).bundle.url.deletingLastPathComponent().path == scratch.elsewhere.path)
        // The machine that was there before stays where it is, and in the library.
        #expect(relaunched.machines.first?.bundle.url.path == first.bundle.url.path)

        #expect(throws: (any Error).self) { try library.setMachinesDirectory(first.bundle.url.appending(path: "inside")) }
    }

    @Test func machinesCannotBeKeptInsideATemplate() async throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.addMachine(to: library, in: library.machinesDirectory)
        let original = machine.bundle.url
        let templates = VMTemplateLibrary(rootDirectory: scratch.root)
        let template = try await templates.save(machine)
        let package = try #require(templates.bundle(of: template))
        let inside = package.url.appending(path: "inside")

        for folder in [package.url, inside] {
            #expect(throws: VMError.self) { try library.prepareFolder(folder) }
            #expect(throws: VMError.self) { try library.setMachinesDirectory(folder) }
            await #expect(throws: VMError.self) { try await library.move(machine, to: folder) }
        }
        #expect(library.machinesDirectory == library.defaultMachinesDirectory)
        #expect(machine.bundle.url == original)
        #expect(!exists(inside))
        try templates.remove(template, movingToTrash: false)
        #expect(try Data(contentsOf: machine.bundle.url.appending(path: "disk.img")) == Data("disk".utf8))
    }

    @Test func aMachineMovesToAnotherFolder() async throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.addMachine(to: library, in: library.machinesDirectory)
        let original = machine.bundle.url
        try machine.updateConfiguration { $0.name = "Web Server" }

        try await library.move(machine, to: scratch.elsewhere)
        // Under the name it has now, with everything that was in it.
        #expect(machine.bundle.url.path == scratch.elsewhere.appending(path: "Web Server.swiftvm").path)
        #expect(!exists(original))
        #expect(try Data(contentsOf: machine.bundle.url.appending(path: "disk.img")) == Data("disk".utf8))
        #expect(machine.activity == nil)
        // What is changed from here on is saved in the new place.
        try machine.updateConfiguration { $0.cpuCount = 6 }
        #expect(try machine.bundle.loadConfiguration().cpuCount == 6)

        let relaunched = scratch.makeLibrary()
        #expect(relaunched.machines.map(\.bundle.url.path) == [machine.bundle.url.path])
    }

    @Test func aMoveThatCanNotBeWrittenDownIsUndone() async throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.addMachine(to: library, in: library.machinesDirectory)
        let original = machine.bundle.url
        // The index can't be written: the library would not find the machine in its new place the
        // next time, so the machine must not end up there.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.root.path) }

        await #expect(throws: (any Error).self) { try await library.move(machine, to: scratch.elsewhere) }
        #expect(machine.bundle.url.path == original.path)
        #expect(exists(original))
        #expect(!exists(scratch.elsewhere.appending(path: "Web.swiftvm")))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.root.path)
        #expect(scratch.makeLibrary().machines.map(\.bundle.url.path) == [original.path])
    }

    @Test func aMachineThatIsNotShutDownStaysWhereItIs() async throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.addMachine(to: library, in: library.machinesDirectory)
        let original = machine.bundle.url
        // Suspended: its saved memory is in the bundle.
        try Data("memory".utf8).write(to: machine.bundle.savedStateURL)
        let suspended = try #require(scratch.makeLibrary().machines.first)

        await #expect(throws: (any Error).self) { try await library.move(suspended, to: scratch.elsewhere) }
        #expect(suspended.bundle.url.path == original.path)
        #expect(exists(original))
    }

    @Test func aMachineOnADiskThatIsAwayStaysInTheLibrary() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.addMachine(to: library, in: scratch.elsewhere)
        let (id, url) = (machine.id, machine.bundle.url)
        // Its disk is taken away: the files are gone, and no disk that is connected is the one they were on.
        let away = scratch.directory.appending(path: "away")
        try FileManager.default.copyItem(at: url, to: away)
        try FileManager.default.removeItem(at: url)

        library.mountedVolumeIdentifiers = { [] }
        library.load()
        #expect(library.machines.isEmpty)
        #expect(library.unavailableMachines.map(\.name) == ["Web"])
        // What it holds stays its own while it is away.
        #expect(library.unavailableMachines.first?.sshAlias == "web")
        #expect(library.unavailableMachines.first?.ipv4Addresses == ["192.168.230.10"])

        // The app is opened again without the disk, and then the disk is connected.
        let relaunched = VMLibrary(rootDirectory: scratch.root)
        relaunched.mountedVolumeIdentifiers = { [] }
        relaunched.load()
        #expect(relaunched.unavailableMachines.map(\.url.path) == [url.path])
        try FileManager.default.copyItem(at: away, to: url)
        relaunched.load()
        #expect(relaunched.machines.map(\.id) == [id])
        #expect(relaunched.unavailableMachines.isEmpty)
    }

    @Test func aMachineInUseWhenItsDiskGoesIsLookedAtAgainOnceItIsDone() async throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.addMachine(to: library, in: scratch.elsewhere)
        library.mountedVolumeIdentifiers = { [] }

        try await machine.whileStopped(.resizingDisk) {
            try FileManager.default.removeItem(at: machine.bundle.url)
            library.load()
            // Not taken off the list in the middle of what is being done with it.
            #expect(library.machines.map(\.id) == [machine.id])
        }
        for _ in 0..<200 where !library.machines.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(library.machines.isEmpty)
        #expect(library.unavailableMachines.map(\.name) == ["Web"])
    }

    @Test func aMachineThatCanNotBeLookedAtIsNotForgotten() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let machine = try scratch.addMachine(to: library, in: scratch.elsewhere)
        // macOS keeps an app out of a disk or a folder until the user has allowed it. Whatever is in
        // there is then not to be seen, which is not to say that it is gone.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scratch.elsewhere.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.elsewhere.path) }

        let relaunched = scratch.makeLibrary()
        #expect(relaunched.machines.isEmpty)
        #expect(relaunched.unavailableMachines.map(\.name) == ["Web"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.elsewhere.path)
        relaunched.load()
        #expect(relaunched.machines.map(\.id) == [machine.id])
    }

    @Test func aMachineThatWasDeletedIsForgottenAndOneThatWasMovedIsFound() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let library = scratch.makeLibrary()
        let deleted = try scratch.addMachine(named: "Deleted", to: library, in: scratch.elsewhere)
        let moved = try scratch.addMachine(named: "Moved", to: library, in: scratch.elsewhere)

        // Both are gone from where they were, on a disk that is connected.
        try FileManager.default.removeItem(at: deleted.bundle.url)
        let destination = scratch.directory.appending(path: "Renamed.swiftvm")
        try FileManager.default.moveItem(at: moved.bundle.url, to: destination)

        let relaunched = scratch.makeLibrary()
        #expect(relaunched.machines.map(\.name) == ["Moved"])
        #expect(relaunched.machines.first?.bundle.url.path == destination.path)
        #expect(relaunched.unavailableMachines.isEmpty)
    }
}

@Suite struct BundleCopyTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")

    /// A bundle with a disk that is almost all empty space, and a snapshot of it.
    private func makeBundle() throws -> (bundle: VMBundle, disk: DiskConfiguration) {
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 256 << 20, format: .raw)
        let configuration = VMConfiguration(name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [disk])
        let bundle = try VMBundle.create(at: directory.appending(path: "Box.swiftvm"), configuration: configuration)
        FileManager.default.createFile(atPath: bundle.diskURL(for: disk).path, contents: nil)
        let handle = try FileHandle(forWritingTo: bundle.diskURL(for: disk))
        try handle.truncate(atOffset: disk.capacity)
        try handle.seek(toOffset: 64 << 20)
        try handle.write(contentsOf: Data(repeating: 7, count: 2 << 20))
        try handle.close()
        _ = try bundle.takeSnapshot(named: "Before", of: configuration)
        return (bundle, disk)
    }

    @Test func aCopyHasEverythingAndLeavesEmptySpaceEmpty() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (bundle, disk) = try makeBundle()

        // Not cloned, as on a disk that can't share blocks with the original.
        let copy = try bundle.copy(to: directory.appending(path: "Copy.swiftvm"), cloning: false)
        #expect(FileManager.default.contentsEqual(atPath: bundle.diskURL(for: disk).path, andPath: copy.diskURL(for: disk).path))
        #expect(copy.loadSnapshots().map(\.name) == ["Before"])
        #expect(try copy.loadConfiguration().name == "Box")
        // The disk and its snapshot are 256 MB each to look at, and a few MB of that is there.
        #expect(copy.totalAllocatedSize < 64 << 20)
    }

    @Test func aCopyThatIsCalledOffLeavesNothingBehind() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (bundle, _) = try makeBundle()
        let destination = directory.appending(path: "Copy.swiftvm")

        #expect(throws: CancellationError.self) {
            try bundle.copy(to: destination, cloning: false, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
