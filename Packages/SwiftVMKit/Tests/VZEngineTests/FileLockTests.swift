import Foundation
import Testing
@testable import VZEngine

struct FileLockTests {
    /// A Mac that was just installed is started as soon as the installer's process lets go of it.
    @Test func waitsForTheLockToBeGivenBack() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "aux-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let holder = open(file.path, O_RDONLY)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX) == 0)

        #expect(try await FileLock.waitUntilFree(file, timeout: .milliseconds(300)) == false)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            flock(holder, LOCK_UN)
        }
        #expect(try await FileLock.waitUntilFree(file, timeout: .seconds(5)))
    }
}
