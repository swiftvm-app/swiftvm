import Darwin
import Foundation
import Testing
@testable import VMCore

@Suite(.serialized) struct PackageOwnershipTests {
    private func bundle() throws -> (VMBundle, VMConfiguration) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-package-\(UUID()).swiftvm")
        let configuration = VMConfiguration(
            name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30,
            disks: [DiskConfiguration(fileName: "disk.img", capacity: 1024, format: .raw)]
        )
        let bundle = try VMBundle.create(at: directory, configuration: configuration)
        try Data("disk".utf8).write(to: bundle.url.appending(path: "disk.img"))
        return (bundle, configuration)
    }

    @Test func separateProcessesContendAndAbruptExitReusesTheInode() async throws {
        let (bundle, configuration) = try bundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let key = "SWIFTVM_PACKAGE_TEST_ROOT"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, bundle.url.path, 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        var original = stat()
        try #require(lstat(bundle.url.appending(path: "package.lock").path, &original) == 0)
        do {
            let owner = try PackageOwnership(in: bundle, configuration: configuration)
            await #expect(processExitsWith: .exitCode(42)) {
                let bundle = VMBundle(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTVM_PACKAGE_TEST_ROOT"]!))
                do {
                    let owner = try PackageOwnership(in: bundle, configuration: bundle.loadConfiguration())
                    withExtendedLifetime(owner) { _exit(0) }
                } catch PackageOwnership.Problem.inUse { _exit(42) }
                catch { _exit(43) }
            }
            withExtendedLifetime(owner) {}
        }
        await #expect(processExitsWith: .success) {
            let bundle = VMBundle(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTVM_PACKAGE_TEST_ROOT"]!))
            let owner = try PackageOwnership(in: bundle, configuration: bundle.loadConfiguration())
            withExtendedLifetime(owner) { _exit(0) }
        }
        let owner = try PackageOwnership(in: bundle, configuration: configuration)
        var current = stat()
        #expect(lstat(bundle.url.appending(path: "package.lock").path, &current) == 0)
        #expect(original.st_dev == current.st_dev && original.st_ino == current.st_ino)
        withExtendedLifetime(owner) {}
    }

    @Test func aDuplicateRetainsOwnershipAfterTheControllerReleasesIt() throws {
        let (bundle, configuration) = try bundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        var owner: PackageOwnership? = try PackageOwnership(in: bundle, configuration: configuration)
        let duplicate = try #require(owner).duplicateDescriptor()
        owner = nil
        #expect(throws: PackageOwnership.Problem.inUse) { try PackageOwnership(in: bundle, configuration: configuration) }
        close(duplicate)
        let next = try PackageOwnership(in: bundle, configuration: configuration)
        withExtendedLifetime(next) {}
    }

    @Test func nativeLocksInTheSameProcessAreNotMistakenForRelease() throws {
        let (bundle, configuration) = try bundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let file = open(bundle.url.appending(path: "disk.img").path, O_RDWR | O_CLOEXEC)
        try #require(file >= 0)
        defer { close(file) }
        var lock = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        try #require(fcntl(file, F_SETLK, &lock) == 0)
        #expect(throws: PackageOwnership.Problem.resourcesInUse) { try PackageOwnership(in: bundle, configuration: configuration) }
        var query = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        try #require(fcntl(file, F_OFD_GETLK, &query) == 0)
        #expect(query.l_type == F_WRLCK && query.l_pid == getpid())
        lock.l_type = Int16(F_UNLCK)
        try #require(fcntl(file, F_SETLK, &lock) == 0)
        try #require(flock(file, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: PackageOwnership.Problem.resourcesInUse) { try PackageOwnership(in: bundle, configuration: configuration) }
        try #require(flock(file, LOCK_UN) == 0)
        let owner = try PackageOwnership(in: bundle, configuration: configuration)
        withExtendedLifetime(owner) {}
    }

    @Test func missingUnsafeOrChangedEvidenceRefusesWithoutRepair() throws {
        let (bundle, configuration) = try bundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let disk = bundle.url.appending(path: "disk.img")
        try FileManager.default.removeItem(at: disk)
        #expect(throws: POSIXError.self) { try PackageOwnership(in: bundle, configuration: configuration) }
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: bundle.configurationURL)
        #expect(throws: (any Error).self) { try PackageOwnership(in: bundle, configuration: configuration) }
        try FileManager.default.removeItem(at: disk)
        try Data("disk".utf8).write(to: disk)
        var changed = configuration
        changed.cpuCount = 4
        try bundle.save(changed)
        #expect(throws: PackageOwnership.Problem.changedConfiguration) { try PackageOwnership(in: bundle, configuration: configuration) }
        try bundle.save(configuration)
        let lock = bundle.url.appending(path: "package.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: bundle.configurationURL)
        #expect(throws: (any Error).self) { try PackageOwnership(in: bundle, configuration: configuration) }
        #expect(try bundle.loadConfiguration().id == configuration.id)
        try FileManager.default.removeItem(at: lock)
        try #require(mkfifo(lock.path, 0o600) == 0)
        #expect(throws: PackageOwnership.Problem.unsafeFile) { try PackageOwnership(in: bundle, configuration: configuration) }
    }

    @Test(.timeLimit(.minutes(1))) func anInstallerWaitsForNativeFilesWithoutDroppingOwnership() async throws {
        let (bundle, configuration) = try bundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let owner = try PackageOwnership(in: bundle, configuration: configuration)
        let holder = open(bundle.url.appending(path: "disk.img").path, O_RDONLY | O_CLOEXEC)
        try #require(holder >= 0)
        defer { close(holder) }
        try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: PackageOwnership.Problem.resourcesInUse) { try owner.requireReleasedResources(for: configuration) }
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(200))
            try #require(flock(holder, LOCK_UN) == 0)
        }
        try await owner.waitForReleasedResources(for: configuration)
        try await release.value
        #expect(throws: PackageOwnership.Problem.inUse) { try PackageOwnership(in: bundle, configuration: configuration) }
    }

    @Test(arguments: ["efi-vars.fd", "tpm-state.bin"])
    func firstBootFilesBecomeRequiredOnceTheBackendUsesThem(_ name: String) throws {
        let (bundle, configuration) = try bundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let owner = try PackageOwnership(in: bundle, configuration: configuration)
        try owner.expectRuntimeResource(name)
        #expect(throws: POSIXError.self) { try owner.requireReleasedResources(for: configuration) }
        let file = bundle.url.appending(path: name)
        try Data("runtime state".utf8).write(to: file)
        try owner.requireReleasedResources(for: configuration)
        try FileManager.default.removeItem(at: file)
        #expect(throws: POSIXError.self) { try owner.requireReleasedResources(for: configuration) }
    }

    @Test func clonesHaveIndependentOwnershipAndLockReplacementIsRefused() throws {
        let (bundle, configuration) = try bundle()
        let destination = bundle.url.deletingLastPathComponent().appending(path: "swiftvm-copy-\(UUID()).swiftvm")
        defer {
            try? FileManager.default.removeItem(at: bundle.url)
            try? FileManager.default.removeItem(at: destination)
        }
        let owner = try PackageOwnership(in: bundle, configuration: configuration)
        let copyConfiguration = configuration.duplicated(name: "Copy", sshAlias: "copy")
        let copy = try bundle.duplicate(to: destination, configuration: copyConfiguration)
        let copyOwner = try PackageOwnership(in: copy, configuration: copyConfiguration)
        var source = stat(), cloned = stat()
        #expect(lstat(bundle.url.appending(path: "package.lock").path, &source) == 0)
        #expect(lstat(copy.url.appending(path: "package.lock").path, &cloned) == 0)
        #expect(source.st_ino != cloned.st_ino)
        try FileManager.default.removeItem(at: bundle.url.appending(path: "package.lock"))
        try Data().write(to: bundle.url.appending(path: "package.lock"))
        #expect(throws: PackageOwnership.Problem.unsafeFile) { try owner.requireMatches(bundle) }
        #expect(throws: PackageOwnership.Problem.unsafeFile) { try owner.duplicateDescriptor() }
        withExtendedLifetime(copyOwner) {}
    }
}
