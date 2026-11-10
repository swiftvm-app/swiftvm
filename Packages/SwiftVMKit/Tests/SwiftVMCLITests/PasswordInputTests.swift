import Foundation
import GuestChannel
import Testing
@testable import SwiftVMCLI

@Suite struct PasswordInputTests {
    private func read(_ chunks: [Data]) throws -> String {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let descriptor = writer.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { try? writer.close(); finished.signal() }
            for chunk in chunks {
                guard ByteRelay.writeAll(ArraySlice(chunk), to: descriptor) else { return }
            }
        }
        defer {
            try? pipe.fileHandleForReading.close()
            #expect(finished.wait(timeout: .now() + 2) == .success)
        }
        return try PasswordInput.read(from: pipe.fileHandleForReading.fileDescriptor)
    }

    @Test(arguments: ["", "\n", "\r\n"])
    func onlyOneOptionalLineEndingIsRemoved(ending: String) throws {
        let password = "  quotes'\"\t🔑  "
        #expect(try read([Data((password + ending).utf8)]) == password)
    }

    @Test func partialReadsAndASplitUTF8CharacterAreNotTruncated() throws {
        let pieces = [Data([0xF0, 0x9F]), Data([0x94]), Data([0x91]), Data(repeating: 0x61, count: 3000), Data(" \r\n".utf8)]
        #expect(try read(pieces) == "🔑" + String(repeating: "a", count: 3000) + " ")
    }

    @Test func theLimitCountsPasswordBytesRatherThanTheLineEnding() throws {
        let password = String(repeating: "a", count: 4096)
        #expect(try read([Data((password + "\r\n").utf8)]) == password)
        #expect(try read([Data(("\u{FEFF}" + "value").utf8)]) == "\u{FEFF}value")
    }

    @Test(arguments: [
        Data(), Data("\n".utf8), Data("\r\n".utf8), Data([0xFF]), Data([0xF0, 0x9F]),
        Data("a\0b".utf8), Data("a\nb\n".utf8), Data("a\n\n".utf8), Data("a\r".utf8),
        Data(repeating: 0x61, count: 4097), Data(repeating: 0x61, count: 10_000),
    ])
    func invalidInputIsRejectedWithoutEchoingIt(input: Data) {
        #expect(throws: PasswordInput.Problem.self) { try read([input]) }
    }

    @Test func anUnreadableDescriptorIsNotTreatedAsEOF() {
        #expect(throws: PasswordInput.Problem.unreadable) { try PasswordInput.read(from: .max) }
    }
}
