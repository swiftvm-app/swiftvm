import CryptoKit
import Foundation
import GuestChannel
import Observation
import VMCore

/// Installs, including disc preparation, take turns per machine across the menus and command line.
@MainActor
@Observable
public final class GuestToolsInstallation {
    public private(set) var machineIDs: Set<UUID> = []

    public init() {}

    public func perform<Result>(for id: UUID, named name: String, operation: () async throws -> Result) async throws -> Result {
        guard machineIDs.insert(id).inserted else {
            throw VMError.invalidConfiguration("The guest tools are already being installed in “\(name)”.")
        }
        defer { machineIDs.remove(id) }
        return try await operation()
    }
}

/// Replaces connected tools with the app's bundled copy, without SSH or a password. The installer runs under
/// the guest's service manager: a child of the agent would be killed when it replaces that agent.
public struct GuestToolsReinstallation: Sendable {
    public let launch: GuestJob
    public let input: Data?
    public let status: GuestJob
    public let cleanup: GuestJob

    public init(family: GuestFamily, macProgram: URL? = nil) throws {
        // Only a host-made name enters commands. Neither a machine's name nor a guest's reply does.
        let token = UUID().uuidString.lowercased()
        let scriptName: String
        let directory: String
        switch family {
        case .linux:
            scriptName = "linux-reinstall.sh"
            directory = "/run/swiftvm-reinstall-\(token)"
        case .macOS:
            scriptName = "macos-reinstall.sh"
            directory = "/var/root/swiftvm-reinstall-\(token)"
        case .windows:
            scriptName = "windows-reinstall.ps1"
            directory = ""
        }
        var script = try LinuxGuestAgent.resource(scriptName).replacingOccurrences(of: "@@token@@", with: token)
        if family == .macOS {
            guard let macProgram else { throw MacGuestAgent.AgentError.missingProgram }
            let payload = Data(try MacGuestAgent.installer(program: macProgram).utf8)
            input = payload
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            script = script.replacingOccurrences(of: "@@sha256@@", with: digest)
        } else {
            input = nil
        }
        if family == .windows {
            let place = "$d = Join-Path $env:ProgramFiles 'SwiftVM\\Reinstall-\(token)'; "
            launch = Self.powershell(script)
            status = Self.powershell(place + "if (Test-Path -LiteralPath ($d + '\\status')) { Get-Content -Raw -LiteralPath ($d + '\\status') } else { 'pending' }")
            cleanup = Self.powershell(place + "Unregister-ScheduledTask -TaskName 'SwiftVM-Reinstall-\(token)' -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $d -Recurse -Force")
        } else {
            launch = Self.shell(script)
            status = Self.shell("if [ -f '\(directory)/status' ]; then cat '\(directory)/status'; else echo pending; fi")
            let unload = family == .macOS ? "launchctl remove com.swiftvm.reinstall.\(token) >/dev/null 2>&1; " : ""
            cleanup = Self.shell(unload + "rm -rf '\(directory)'")
        }
    }

    private static func shell(_ script: String) -> GuestJob {
        .exec(.init(arguments: ["/bin/sh", "-c", script], user: "root"))
    }

    private static func powershell(_ script: String) -> GuestJob {
        let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
        return .exec(.init(arguments: ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded], user: "root"))
    }

    /// A receipt belongs to this attempt, not merely to a version. Reinstalling an identical version
    /// must still wait for the installer to finish and for the replacement agent to answer.
    @MainActor
    public func run(
        expectedVersion: String,
        execute: (GuestJob, Data?) async throws -> Data,
        isRunning: () -> Bool,
        connectedVersion: () -> String?,
        timeout: Duration = .seconds(180),
        pollInterval: Duration = .seconds(1)
    ) async throws {
        try Task.checkCancellation()
        guard isRunning() else { throw Failure.interrupted }
        do {
            _ = try await execute(launch, input)
        } catch let error as GuestJobError where Self.isReconnect(error) {
            // The service manager may already have started replacing the agent before its answer left.
            // Never launch again: that would put two installers over the same files.
        }
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            guard isRunning() else { throw Failure.interrupted }
            do {
                let reply = try await execute(status, nil)
                guard isRunning() else { throw Failure.interrupted }
                let receipt = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if receipt == "ok", connectedVersion() == expectedVersion {
                    _ = try? await execute(cleanup, nil)
                    try Task.checkCancellation()
                    guard isRunning() else { throw Failure.interrupted }
                    return
                }
                if receipt.hasPrefix("failed:") {
                    throw Failure.installer(ShownText.line(String(receipt.dropFirst(7)), limit: 500))
                }
                guard receipt == "pending" || receipt == "ok" else { throw Failure.invalidReceipt }
            } catch let error as GuestJobError where Self.isReconnect(error) {
                // The old agent stops before the new one is listening.
            }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func isReconnect(_ error: GuestJobError) -> Bool {
        switch error {
        case .noAgent, .noAnswer: true
        default: false
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case interrupted, timedOut, invalidReceipt
        case installer(String)

        public var errorDescription: String? {
            switch self {
            case .interrupted: "The virtual machine stopped or restarted before the guest tools installation could be verified."
            case .timedOut: "The guest tools installation couldn't be verified in time. The installer may still be running. Check the guest before trying again, or use the guest tools disc to recover."
            case .invalidReceipt: "The guest tools returned an installation result that couldn't be read."
            case .installer(let reason): "The guest tools installer failed: \(reason)"
            }
        }
    }
}
