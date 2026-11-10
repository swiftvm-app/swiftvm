import Foundation
import GuestChannel
import Testing
import VMControl
@testable import SwiftVMCLI

@Suite struct ExecCompletionTests {
    @Test(arguments: [Int32(0), 1, 124, 125, 255, 256, -1, .max])
    func guestStatusesAreKnownEvenWhenTheyMatchCLIFailures(status: Int32) throws {
        let id = UUID()
        let record = ExecCompletion(machine: "desk", machineID: id, end: JobEnd(status: status))
        #expect(record.completion == .exited)
        #expect(record.status == status)
        #expect(record.signal == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["machine"] as? String == "desk")
        #expect(json["machineID"] as? String == id.uuidString)
    }

    @Test func aSignalIsNotAnExitStatus() {
        let record = ExecCompletion(machine: "desk", machineID: nil, end: JobEnd(signal: SIGTERM))
        #expect(record.completion == .signaled)
        #expect(record.signal == SIGTERM)
        #expect(record.status == nil)
    }

    @Test(arguments: [
        nil, JobEnd(), JobEnd(signal: 0), JobEnd(signal: .max),
        JobEnd(status: 0, signal: SIGTERM), JobEnd(status: 0, error: "interrupted"), JobEnd.failure("lost"),
    ] as [JobEnd?])
    func missingOrAmbiguousCompletionStaysUnknown(end: JobEnd?) {
        let record = ExecCompletion(machine: "desk", machineID: nil, end: end)
        #expect(record.completion == .unknown)
        #expect(record.status == nil)
        #expect(record.signal == nil)
    }

    @Test func theStreamsKeepTheirBytesAndMalformedCompletionIsUnknown() throws {
        var ends: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        defer { close(ends[0]) }
        let sender = ends[1]
        let binary = Data((0..<256).map(UInt8.init))
        Thread.detachNewThread {
            JobFrame.write(.output, binary, to: sender)
            JobFrame.write(.errorOutput, Data(binary.reversed()), to: sender)
            JobFrame.write(.end, Data("not JSON".utf8), to: sender)
            close(sender)
        }
        var output = Data()
        var errors = Data()
        let end = GuestJobs.run(ends[0], output: { output.append($0); return true }, errorOutput: { errors.append($0); return true })
        #expect(output == binary)
        #expect(errors == Data(binary.reversed()))
        #expect(ExecCompletion(machine: "desk", machineID: nil, end: end).completion == .unknown)
        #expect(GuestJobs.run(ends[0], output: { _ in true }).error != nil)
    }

    @Test func invalidAndReadOnlyDescriptorsAreRejectedBeforeDispatch() throws {
        for descriptor: Int32 in [-1, 0, 1, 2, .max] {
            #expect(throws: ExecCompletionWriter.InvalidDescriptor.self) { try ExecCompletionWriter(descriptor: descriptor) }
        }
        let source = open("/dev/null", O_RDONLY)
        try #require(source > 2)
        defer { close(source) }
        #expect(throws: ExecCompletionWriter.InvalidDescriptor.self) { try ExecCompletionWriter(descriptor: source) }
    }

    @Test func aRecordHasItsOwnLineAndAFailedWriteIsReported() throws {
        let pipe = Pipe()
        let writer = try ExecCompletionWriter(descriptor: pipe.fileHandleForWriting.fileDescriptor)
        let record = ExecCompletion(machine: "desk", machineID: nil, end: JobEnd(status: 125))
        try writer.write(record)
        let line = try #require(ControlSocket.readLine(from: pipe.fileHandleForReading.fileDescriptor))
        let json = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(json["completion"] as? String == "exited")
        #expect(json["status"] as? Int == 125)
        #expect(json["machineID"] == nil)
        try pipe.fileHandleForReading.close()
        #expect(throws: (any Error).self) { try writer.write(record) }
    }

    @Test func losingTheRecordCannotExitWithGuestSuccess() async {
        await #expect(processExitsWith: .exitCode(125)) {
            let pipe = Pipe()
            let writer = try ExecCompletionWriter(descriptor: pipe.fileHandleForWriting.fileDescriptor)
            try pipe.fileHandleForReading.close()
            writer.finish(ExecCompletion(machine: "desk", machineID: nil, end: JobEnd(status: 0)), status: 0)
        }
    }
}
