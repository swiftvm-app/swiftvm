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
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
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
