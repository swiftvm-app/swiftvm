import Foundation

/// Runs a system command-line tool to completion and captures its output.
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var standardOutput: String
        public var standardError: String
    }

    public struct Failure: Error, LocalizedError {
        public var command: String
        public var output: Output

        public var errorDescription: String? {
            let detail = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? "exit status \(output.status)" : detail
            return "\(command) failed: \(reason)"
        }
    }

    /// Runs `executable` and throws ``Failure`` when it exits with a non-zero status.
    ///
    /// - Parameters:
    ///   - environment: Variables added to (or replacing those of) this process's environment.
    ///   - input: Bytes fed to the tool's standard input. They are written in one go, before anything the
    ///     tool prints is read: for a tool that takes in its input before it has much to say, as `ssh` does.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        input: Data? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
        }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        try process.run()
        if let input, let inputPipe {
            // A tool that exits without reading its input must not take this process down with SIGPIPE.
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        // Read before waiting so a chatty tool can't fill the pipe and block.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = Output(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
        guard output.status == 0 else {
            throw Failure(command: URL(fileURLWithPath: executable).lastPathComponent, output: output)
        }
        return output
    }
}
