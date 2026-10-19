import Foundation
import GuestChannel
import Testing
import VMCore
@testable import Installers

@MainActor
@Suite struct GuestToolsReinstallationTests {
    @Test func theCurrentVersionStillNeedsACompletedInstallAndAWorkingAgent() async throws {
        let install = try GuestToolsReinstallation(family: .linux)
        var jobs: [GuestJob] = []
        var polls = 0
        var version: String? = "1.0"
        try await install.run(expectedVersion: "1.0", execute: { job, _ in
            jobs.append(job)
            guard job == install.status else { return Data() }
            polls += 1
            switch polls {
            case 1: return Data("pending\n".utf8)
            case 2:
                version = nil
                throw GuestJobError.noAgent(name: "Guest")
            case 3: return Data("ok\n".utf8)
            default:
                version = "1.0"
                return Data("ok\n".utf8)
            }
        }, isRunning: { true }, connectedVersion: { version }, pollInterval: .zero)
        #expect(polls == 4)
        #expect(jobs.filter { $0 == install.launch }.count == 1)
        #expect(jobs.last == install.cleanup)
    }

    @Test func losingTheLaunchAnswerDoesNotStartASecondInstaller() async throws {
        let program = FileManager.default.temporaryDirectory.appending(path: "swiftvm-agent-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: program) }
        try Data("a test program".utf8).write(to: program)
        let install = try GuestToolsReinstallation(family: .macOS, macProgram: program)
        var launches = 0
        try await install.run(expectedVersion: "1.0", execute: { job, input in
            if job == install.launch {
                launches += 1
                #expect(input == Data(try MacGuestAgent.installer(program: program).utf8))
                throw GuestJobError.noAnswer(name: "Guest")
            }
            #expect(input == nil)
            return Data("ok\n".utf8)
        }, isRunning: { true }, connectedVersion: { "1.0" }, pollInterval: .zero)
        #expect(launches == 1)
    }

    @Test func installerFailureIsNotHiddenByAnAlreadyConnectedVersion() async throws {
        let install = try GuestToolsReinstallation(family: .windows)
        var cleaned = false
        await #expect(throws: GuestToolsReinstallation.Failure.installer("disk full")) {
            try await install.run(expectedVersion: "1.0", execute: { job, _ in
                if job == install.cleanup { cleaned = true }
                return job == install.status ? Data("failed: disk full\n".utf8) : Data()
            }, isRunning: { true }, connectedVersion: { "1.0" }, pollInterval: .zero)
        }
        #expect(!cleaned)
    }

    @Test(arguments: ["pending", "ok"])
    func anUnfinishedInstallOrWrongVersionTimesOut(receipt: String) async throws {
        let install = try GuestToolsReinstallation(family: .linux)
        var cleaned = false
        await #expect(throws: GuestToolsReinstallation.Failure.timedOut) {
            try await install.run(expectedVersion: "2.0", execute: { job, _ in
                if job == install.cleanup { cleaned = true }
                return Data(receipt.utf8)
            }, isRunning: { true }, connectedVersion: { "1.0" }, timeout: .zero, pollInterval: .zero)
        }
        #expect(!cleaned)
    }

    @Test(arguments: [false, true])
    func aStoppedOrRestartedGuestCannotCompleteThePreviousAttempt(duringCleanup: Bool) async throws {
        let install = try GuestToolsReinstallation(family: .linux)
        var running = true
        await #expect(throws: GuestToolsReinstallation.Failure.interrupted) {
            try await install.run(expectedVersion: "1.0", execute: { job, _ in
                if job == (duringCleanup ? install.cleanup : install.status) { running = false }
                return Data("ok".utf8)
            }, isRunning: { running }, connectedVersion: { "1.0" }, pollInterval: .zero)
        }
    }

    @Test func deniedAutomationIsNotRetriedAsADisconnection() async throws {
        let install = try GuestToolsReinstallation(family: .linux)
        var requests = 0
        await #expect(throws: GuestJobError.notAllowed(name: "Guest")) {
            try await install.run(expectedVersion: "1.0", execute: { _, _ in
                requests += 1
                throw GuestJobError.notAllowed(name: "Guest")
            }, isRunning: { true }, connectedVersion: { "1.0" }, pollInterval: .zero)
        }
        #expect(requests == 1)
    }

    @Test func losingAutomationAfterLaunchLeavesTheDetachedInstallerAlone() async throws {
        let install = try GuestToolsReinstallation(family: .linux)
        var jobs: [GuestJob] = []
        await #expect(throws: GuestJobError.notAllowed(name: "Guest")) {
            try await install.run(expectedVersion: "1.0", execute: { job, _ in
                jobs.append(job)
                if job == install.launch { return Data() }
                throw GuestJobError.notAllowed(name: "Guest")
            }, isRunning: { true }, connectedVersion: { "1.0" }, pollInterval: .zero)
        }
        // Failed verification must neither start another installer nor remove one that still runs.
        #expect(jobs == [install.launch, install.status])
    }

    @Test func overlappingAttemptsAreRefusedAndFailureReleasesTheMachine() async throws {
        let installation = GuestToolsInstallation()
        let id = UUID()
        await #expect(throws: CancellationError.self) {
            try await installation.perform(for: id, named: "Guest") {
                #expect(installation.machineIDs.contains(id))
                do {
                    _ = try await installation.perform(for: id, named: "Guest") {
                        Issue.record("A second installer was allowed to start.")
                    }
                    Issue.record("The overlapping attempt wasn't refused.")
                } catch is VMError {
                    // Refused before the second operation was entered.
                }
                // A different guest has no files in common with this one.
                try await installation.perform(for: UUID(), named: "Other") {}
                throw CancellationError()
            }
        }
        #expect(installation.machineIDs.isEmpty)
        try await installation.perform(for: id, named: "Guest") {}
    }
}
