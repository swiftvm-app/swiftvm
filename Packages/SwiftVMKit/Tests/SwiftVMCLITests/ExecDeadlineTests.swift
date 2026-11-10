import Darwin
import Foundation
import GuestChannel
import Testing
@testable import SwiftVMCLI

@Suite struct ExecDeadlineTests {
    private static func fill(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        try #require(flags >= 0)
        try #require(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        let bytes = [UInt8](repeating: 0x78, count: 512)
        while true {
            let count = Darwin.write(descriptor, bytes, bytes.count)
            if count > 0 || (count < 0 && errno == EINTR) { continue }
            try #require(count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return
        }
    }

    @Test(.timeLimit(.minutes(1))) func deadlineCoversWorkBeforeAStreamExists() async {
        await #expect(processExitsWith: .exitCode(124)) {
            let completion = try ExecCompletionWriter(descriptor: nil)
            completion.armDeadline(0.1, machine: "fixture")
            // The deadline must interrupt synchronous work as well as an asynchronous wait.
            Darwin.sleep(2)
            _exit(99)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aBlockedRecordCannotStrandTheDeadline() async {
        await #expect(processExitsWith: .exitCode(125)) {
            let pipe = Pipe()
            try Self.fill(pipe.fileHandleForWriting.fileDescriptor)
            let completion = try ExecCompletionWriter(descriptor: pipe.fileHandleForWriting.fileDescriptor)
            completion.armDeadline(0.1, machine: "fixture")
            completion.finish(ExecCompletion(machine: "fixture", machineID: nil, end: JobEnd(status: 0)), status: 0)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aBlockedDiagnosticDoesNotTurnKnownCompletionIntoTimeout() async {
        await #expect(processExitsWith: .exitCode(7)) {
            let pipe = Pipe()
            try Self.fill(pipe.fileHandleForWriting.fileDescriptor)
            try #require(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == STDERR_FILENO)
            let completion = try ExecCompletionWriter(descriptor: nil)
            completion.armDeadline(0.1, machine: "fixture")
            completion.finish(ExecCompletion(machine: "fixture", machineID: nil, end: JobEnd(status: 7)), status: 7, diagnostic: "known completion")
        }
    }

    @Test(.timeLimit(.minutes(1))) func aBlockedTimeoutDiagnosticCannotStrandTheClient() async {
        await #expect(processExitsWith: .exitCode(124)) {
            let pipe = Pipe()
            try Self.fill(pipe.fileHandleForWriting.fileDescriptor)
            try #require(dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == STDERR_FILENO)
            let completion = try ExecCompletionWriter(descriptor: nil)
            completion.armDeadline(0.1, machine: "fixture")
            Darwin.sleep(2)
            _exit(99)
        }
    }
}
