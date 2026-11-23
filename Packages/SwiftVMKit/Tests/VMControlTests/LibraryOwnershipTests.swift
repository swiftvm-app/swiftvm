import Foundation
import Testing
@testable import VMControl

@Suite(.serialized) struct LibraryOwnershipTests {
    private func folder() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/swiftvm-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    @Test func separateProcessesContendAndExitLeavesTheSameReusableInode() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "SWIFTVM_OWNERSHIP_TEST_ROOT"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, directory.path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        var original = stat()
        do {
            let owner = try LibraryOwnership(at: directory)
            try #require(lstat(directory.appending(path: "library.lock").path, &original) == 0)
            await #expect(processExitsWith: .exitCode(42)) {
                let path = ProcessInfo.processInfo.environment["SWIFTVM_OWNERSHIP_TEST_ROOT"]!
                do {
                    let owner = try LibraryOwnership(at: URL(fileURLWithPath: path))
                    withExtendedLifetime(owner) { _exit(0) }
                } catch LibraryOwnership.Problem.inUse {
                    _exit(42)
                } catch { _exit(43) }
            }
            withExtendedLifetime(owner) {}
        }
        // Deliberately skip Swift destructors: the OS, not cleanup code, must release the lock.
        await #expect(processExitsWith: .success) {
            let path = ProcessInfo.processInfo.environment["SWIFTVM_OWNERSHIP_TEST_ROOT"]!
            let owner = try LibraryOwnership(at: URL(fileURLWithPath: path))
            withExtendedLifetime(owner) { _exit(0) }
        }
        let reopened = try LibraryOwnership(at: directory)
        var current = stat()
        #expect(lstat(directory.appending(path: "library.lock").path, &current) == 0)
        #expect(current.st_dev == original.st_dev && current.st_ino == original.st_ino)
        withExtendedLifetime(reopened) {}
    }

    @Test func unsafeOwnershipFilesAreNotFollowedOrRepaired() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.lock")
        let target = directory.appending(path: "keep")
        try Data("retained".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try LibraryOwnership(at: directory) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "retained")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        #expect(throws: LibraryOwnership.Problem.unsafeFile) { try LibraryOwnership(at: directory) }
        try FileManager.default.removeItem(at: file)
        try Data().write(to: file)
        try #require(chmod(file.path, 0o666) == 0)
        #expect(throws: LibraryOwnership.Problem.unsafeFile) { try LibraryOwnership(at: directory) }
        #expect(try Data(contentsOf: file).isEmpty)
        try FileManager.default.removeItem(at: file)
        try #require(mkfifo(file.path, 0o600) == 0)
        #expect(throws: LibraryOwnership.Problem.unsafeFile) { try LibraryOwnership(at: directory) }
    }

    @Test func aLiveLegacyEndpointCannotBeReplaced() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "control.sock")
        let listener = try ControlSocket.listen(at: url)
        defer { close(listener) }
        #expect(throws: ControlSocketError.self) { try LibraryOwnership(at: directory) }
        #expect(throws: ControlSocketError.self) { try ControlSocket.listen(at: url) }
        let client = try ControlSocket.connect(to: url)
        close(client)
    }

    @Test func anUnsafeEndpointIsNotDeletedAndAStaleSocketCanBeReused() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "control.sock")
        try Data("keep".utf8).write(to: url)
        #expect(throws: ControlSocketError.self) { try LibraryOwnership(at: directory) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: url)
        let listener = try ControlSocket.listen(at: url)
        close(listener)
        let ownership = try LibraryOwnership(at: directory)
        let replacement = try ControlSocket.listen(at: url)
        close(replacement)
        withExtendedLifetime(ownership) {}
    }

    @Test(.timeLimit(.minutes(1))) func activeRequestsKeepOwnershipAfterTheServerIsReleased() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "control.sock")
        let entered = AsyncStream.makeStream(of: Bool.self)
        let finish = AsyncStream.makeStream(of: Bool.self)
        defer { entered.continuation.finish(); finish.continuation.finish() }
        var server: ControlServer? = try ControlServer(socketURL: url, handler: { _ in
            entered.continuation.yield(true)
            for await _ in finish.stream { break }
            return ControlResponse(ok: true)
        })
        let client = ControlClient(socketURL: url)
        let request = Task.detached { try client.send(ControlRequest(command: .list)) }
        var started = entered.stream.makeAsyncIterator()
        try #require(await started.next() == true)
        withExtendedLifetime(server) {}
        server = nil
        #expect(throws: LibraryOwnership.Problem.inUse) { try LibraryOwnership(at: directory) }
        finish.continuation.yield(true)
        #expect(try await request.value.ok)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let owner = try? LibraryOwnership(at: directory) {
                withExtendedLifetime(owner) {}
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The stopped server or finished request retained library ownership.")
    }

    @Test func anotherUsersWritableDirectoryIsNotAnOwnershipBoundary() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(chmod(directory.path, 0o777) == 0)
        #expect(throws: LibraryOwnership.Problem.unsafeDirectory) { try LibraryOwnership(at: directory) }
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "library.lock").path) == false)
    }

    @Test func ownershipOfAnotherFolderCannotAuthorizeAControlServer() throws {
        let first = try folder()
        let second = try folder()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let owner = try LibraryOwnership(at: first)
        let socket = second.appending(path: "control.sock")
        #expect(throws: LibraryOwnership.Problem.wrongDirectory) {
            try ControlServer(socketURL: socket, ownership: owner, handler: { _ in ControlResponse(ok: true) })
        }
        #expect(FileManager.default.fileExists(atPath: socket.path) == false)
        withExtendedLifetime(owner) {}
    }
}
