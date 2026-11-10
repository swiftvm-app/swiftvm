import Darwin
import Foundation
import Testing
import VMCore
@testable import QEMUEngine

@Suite struct QEMUOwnershipTests {
    @Test @MainActor func startupCleanupOnlyClaimsPackagesWithALeftoverMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-cleanup-ownership-\(UUID()).swiftvm")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = VMConfiguration(name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory, configuration: configuration)
        let owner = try PackageOwnership(in: bundle, configuration: configuration)
        try await QEMUBackend.endLeftover(of: configuration, in: bundle)
        try Data("123\n".utf8).write(to: directory.appending(path: "qemu.pid"))
        await #expect(throws: PackageOwnership.Problem.inUse) {
            try await QEMUBackend.endLeftover(of: configuration, in: bundle)
        }
        withExtendedLifetime(owner) {}
    }

    @Test(.timeLimit(.minutes(1))) func launcherHandsOwnershipToAChildUntilItsActualExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-spawn-ownership-\(UUID()).swiftvm")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = VMConfiguration(name: "Box", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory, configuration: configuration)
        var owner: PackageOwnership? = try PackageOwnership(in: bundle, configuration: configuration)
        let descriptor = try #require(owner).duplicateDescriptor()
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOFORK != 0)
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer { for end in ends where end >= 0 { close(end) } }
        for end in ends { try #require(fcntl(end, F_SETFD, FD_CLOEXEC | FD_CLOFORK) == 0) }
        // The real launcher maps the pipe to3 and lease to4. This child waits for pipe EOF, with
        // no VM or guest involved, while the controller drops every copy of the lease it held.
        let process = try QEMUProcess.launch(
            program: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "read value <&3"], descriptors: [ends[0], descriptor],
            log: bundle.logsDirectory.appending(path: "handoff.log"), pidFile: directory.appending(path: "handoff.pid")
        )
        defer { if !process.hasExited { process.forceKill() } }
        close(descriptor)
        owner = nil
        try #require(!process.hasExited)
        #expect(throws: PackageOwnership.Problem.inUse) { try PackageOwnership(in: bundle, configuration: configuration) }
        close(ends[1])
        ends[1] = -1
        try #require(await process.waitForExit(timeout: .seconds(5)))
        let next = try PackageOwnership(in: bundle, configuration: configuration)
        withExtendedLifetime(next) {}
    }
}
