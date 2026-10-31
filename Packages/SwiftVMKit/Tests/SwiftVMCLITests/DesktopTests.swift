import Foundation
import GuestChannel
import Testing
import VMControl

private final class TestBundle: NSObject {}

@Suite struct DesktopTests {
    @Test func theDeadlineIncludesTheAppsFirstAnswer() throws {
        try timesOut(fullErrorPipe: false)
    }

    @Test func aFullErrorPipeCannotHoldTheDeadline() throws {
        try timesOut(fullErrorPipe: true)
    }

    private func timesOut(fullErrorPipe: Bool) throws {
        let directory = URL(fileURLWithPath: "/tmp/swiftvm-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try ControlSocket.listen(at: directory.appending(path: "control.sock"))
        defer { close(listener) }

        let errors = Pipe()
        let errorDescriptor = errors.fileHandleForWriting.fileDescriptor
        let flags = fcntl(errorDescriptor, F_GETFL)
        if fullErrorPipe {
            // Fill it before starting the tool, then leave it unread until the tool has exited.
            try #require(fcntl(errorDescriptor, F_SETFL, flags | O_NONBLOCK) == 0)
            let bytes = [UInt8](repeating: 120, count: 4096)
            while write(errorDescriptor, bytes, bytes.count) > 0 {}
            let full = errno == EAGAIN
            try #require(fcntl(errorDescriptor, F_SETFL, flags) == 0)
            try #require(full)
        }

        let process = Process()
        process.executableURL = Bundle(for: TestBundle.self).bundleURL.deletingLastPathComponent().appending(path: "swiftvm")
        process.arguments = ["desktop", "desk", "--timeout", "1", "status"]
        process.environment = ProcessInfo.processInfo.environment.merging([ControlPaths.homeEnvironmentKey: directory.path]) { _, value in value }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors.fileHandleForWriting
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        try #require(poll(&waiting, 1, 5000) > 0)
        let connection = accept(listener, nil, nil)
        try #require(connection >= 0)
        defer { close(connection) }
        let line = try #require(GuestJobLine.read(from: connection, timeout: 5))
        let request = try JSONDecoder().decode(ControlRequest.self, from: line)
        #expect(request.job == .desktop(.init(arguments: ["status"])))
        if fullErrorPipe {
            try ControlSocket.writeLine(JSONEncoder().encode(ControlResponse(ok: true)), to: connection)
            JobFrame.write(.errorOutput, Data(repeating: 120, count: JobFrame.maximumPayloadLength), to: connection)
        }

        try #require(finished.wait(timeout: .now() + 3) == .success)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 124)
        #expect(fcntl(errorDescriptor, F_GETFL) & O_NONBLOCK == 0)
        try errors.fileHandleForWriting.close()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        #expect(!output.isEmpty)
    }
}
