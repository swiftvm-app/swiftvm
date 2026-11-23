import Darwin
import Foundation
import Testing
@testable import VMCore

@Suite struct RequiredCloneTests {
    @Test func requiredClonesHaveIndependentIdentityAndDiskWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-cow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(name: "Source", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [disk])
        let source = try VMBundle.create(at: directory.appending(path: "source.swiftvm"), configuration: configuration)
        let contents = Data(repeating: 7, count: 1 << 16)
        try contents.write(to: source.diskURL(for: disk))
        let copyConfiguration = configuration.duplicated(name: "Copy", sshAlias: "copy")
        let copy = try source.duplicate(to: directory.appending(path: "copy.swiftvm"), configuration: copyConfiguration, requiresCopyOnWrite: true)
        #expect(try copy.loadConfiguration().id != source.loadConfiguration().id)
        #expect(try Data(contentsOf: copy.diskURL(for: disk)) == contents)
        var original = stat(), cloned = stat()
        try #require(stat(source.diskURL(for: disk).path, &original) == 0)
        try #require(stat(copy.diskURL(for: disk).path, &cloned) == 0)
        #expect(original.st_ino != cloned.st_ino)

        // Write through each existing inode, so replacing a file atomically cannot hide a shared disk.
        let copyFile = try FileHandle(forUpdating: copy.diskURL(for: disk))
        defer { try? copyFile.close() }
        try copyFile.write(contentsOf: Data([1]))
        #expect(try Data(contentsOf: source.diskURL(for: disk)) == contents)
        let sourceFile = try FileHandle(forUpdating: source.diskURL(for: disk))
        defer { try? sourceFile.close() }
        try sourceFile.write(contentsOf: Data([2]))
        #expect(try Data(contentsOf: copy.diskURL(for: disk)).first == 1)
        #expect(try Data(contentsOf: source.diskURL(for: disk)).first == 2)

        #expect(throws: CocoaError.self) {
            try source.duplicate(to: copy.url, configuration: copyConfiguration, requiresCopyOnWrite: true)
        }
        #expect(try Data(contentsOf: copy.diskURL(for: disk)).first == 1)
    }

    @Test func requiredCloneCancellationRemovesItsDestinationAndPreservesTheSource() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-cow-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(name: "Source", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [disk])
        let source = try VMBundle.create(at: directory.appending(path: "source.swiftvm"), configuration: configuration)
        let contents = Data("original disk".utf8)
        try contents.write(to: source.diskURL(for: disk))
        let originalConfiguration = try Data(contentsOf: source.configurationURL)
        let destination = directory.appending(path: "cancelled.swiftvm")
        #expect(throws: CancellationError.self) {
            try source.duplicate(to: destination, configuration: configuration.duplicated(name: "Copy", sshAlias: "copy"), requiresCopyOnWrite: true, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: source.diskURL(for: disk)) == contents)
        #expect(try Data(contentsOf: source.configurationURL) == originalConfiguration)
    }

    @Test func requiredClonesCannotShareADiskThroughASymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-cow-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(name: "Source", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [disk])
        let source = try VMBundle.create(at: directory.appending(path: "source.swiftvm"), configuration: configuration)
        let external = directory.appending(path: "external.img")
        let contents = Data("must remain independent".utf8)
        try contents.write(to: external)
        try FileManager.default.createSymbolicLink(at: source.diskURL(for: disk), withDestinationURL: external)
        let destination = directory.appending(path: "copy.swiftvm")
        #expect(throws: (any Error).self) {
            try source.duplicate(to: destination, configuration: configuration.duplicated(name: "Copy", sshAlias: "copy"), requiresCopyOnWrite: true)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: external) == contents)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.diskURL(for: disk).path) == external.path)
    }
}
