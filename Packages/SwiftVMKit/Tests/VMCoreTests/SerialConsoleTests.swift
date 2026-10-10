import Foundation
import Testing
@testable import VMCore

/// Collects what a console reports, for tests to wait on.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var changes: [Bool] = []

    func record(_ event: SerialConsole.Event) {
        lock.withLock {
            switch event {
            case .output(let data): bytes.append(data)
            case .connectionChanged(let isConnected): changes.append(isConnected)
            }
        }
    }

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var connectionChanges: [Bool] { lock.withLock { changes } }

    func waitForText(_ expected: String) async -> String {
        for _ in 0..<300 where text != expected {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return text
    }
}

@Suite struct SerialConsoleTests {
    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "swiftvm-console-\(UUID().uuidString)/logs/console.log")
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func carriesTextBothWays() async throws {
        let console = SerialConsole()
        let recorder = Recorder()
        _ = console.addListener(recorder.record)
        let guest = console.connect()
        #expect(console.isConnected)
        #expect(recorder.connectionChanges == [true])

        try guest.output.write(contentsOf: Data("login: ".utf8))
        #expect(await recorder.waitForText("login: ") == "login: ")
        #expect(console.transcript == Data("login: ".utf8))

        console.send(Data("root\n".utf8))
        #expect(guest.input.availableData == Data("root\n".utf8))
    }

    @Test func listenersStayAcrossRestarts() async throws {
        let console = SerialConsole()
        let recorder = Recorder()
        let token = console.addListener(recorder.record)

        var guest = console.connect()
        try guest.output.write(contentsOf: Data("first boot\n".utf8))
        _ = await recorder.waitForText("first boot\n")
        console.disconnect()
        #expect(!console.isConnected)

        guest = console.connect()
        try guest.output.write(contentsOf: Data("second boot\n".utf8))
        #expect(await recorder.waitForText("first boot\nsecond boot\n") == "first boot\nsecond boot\n")
        #expect(recorder.connectionChanges == [true, false, true])
        // A booting machine starts with a clean slate.
        #expect(console.transcript == Data("second boot\n".utf8))

        console.removeListener(token)
        try guest.output.write(contentsOf: Data("unheard".utf8))
        await waitFor { console.transcript.count > 12 }
        #expect(recorder.text == "first boot\nsecond boot\n")
    }

    @Test func keepsWhatTheGuestPrintedLastWhenItStops() throws {
        let logURL = temporaryLog()
        defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().deletingLastPathComponent()) }
        let console = SerialConsole(logURL: logURL)
        let recorder = Recorder()
        _ = console.addListener(recorder.record)

        // Nothing waits between the guest's last words and its stop, so whether they were read in time
        // used to be a matter of luck. Often enough to lose that race at least once.
        for round in 0..<200 {
            let guest = console.connect()
            let first = "[\(round)] Stopping…\n"
            let last = String(repeating: "x", count: round * 40) + "\n[\(round)] reboot: Power down\n"
            try guest.output.write(contentsOf: Data(first.utf8))
            try guest.output.write(contentsOf: Data(last.utf8))
            console.disconnect()

            #expect(try String(contentsOf: logURL, encoding: .utf8) == first + last)
            #expect(console.transcript == Data((first + last).utf8))
            #expect(recorder.text.hasSuffix(first + last))
        }
        // Listeners hear the last words before they hear that the guest is gone.
        #expect(recorder.connectionChanges == Array(repeating: [true, false], count: 200).flatMap { $0 })
    }

    @Test func typingToNobodyIsHarmless() {
        let console = SerialConsole()
        console.send(Data("hello?".utf8))

        // A guest that never reads fills the line; what doesn't fit is dropped rather than waited for.
        let guest = console.connect()
        let megabyte = Data(repeating: 0x41, count: 1 << 20)
        console.send(megabyte)
        console.disconnect()
        // And a guest that has gone doesn't take the app with it.
        console.send(megabyte)
        _ = guest
    }

    @Test func keepsOnlyTheRecentPast() async throws {
        let console = SerialConsole()
        let guest = console.connect()
        let chunk = Data(repeating: 0x42, count: 64 * 1024)
        for _ in 0..<6 {
            try guest.output.write(contentsOf: chunk)
        }
        try guest.output.write(contentsOf: Data("the end".utf8))
        await waitFor { console.transcript.suffix(7) == Data("the end".utf8) }
        let transcript = console.transcript
        #expect(transcript.count == SerialConsole.transcriptLimit)
        #expect(transcript.suffix(7) == Data("the end".utf8))
        // A plain value that can be indexed from the start, not a window into a larger buffer.
        #expect(transcript.startIndex == 0)
        #expect(transcript[0] == 0x42)
    }

    @Test func writesALogThatStartsOverOnBootAndCarriesOnAfterResume() async throws {
        let logURL = temporaryLog()
        defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().deletingLastPathComponent()) }
        let console = SerialConsole(logURL: logURL)
        func logText() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

        var guest = console.connect()
        try guest.output.write(contentsOf: Data("boot one\n".utf8))
        await waitFor { logText() == "boot one\n" }
        console.disconnect()
        #expect(logText() == "boot one\n")

        // Resumed: the same session carries on.
        guest = console.connect(continuing: true)
        try guest.output.write(contentsOf: Data("still here\n".utf8))
        await waitFor { logText() == "boot one\nstill here\n" }
        #expect(logText() == "boot one\nstill here\n")
        #expect(console.transcript == Data("boot one\nstill here\n".utf8))
        console.disconnect()

        // Booted: a new log.
        guest = console.connect()
        try guest.output.write(contentsOf: Data("boot two\n".utf8))
        await waitFor { logText() == "boot two\n" }
        #expect(logText() == "boot two\n")
    }

    @Test func theLogDoesNotGrowWithoutBound() async throws {
        let logURL = temporaryLog()
        defer { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().deletingLastPathComponent()) }
        let console = SerialConsole(logURL: logURL)
        let guest = console.connect()

        let chunk = Data(repeating: 0x43, count: 512 * 1024)
        let chunkCount = SerialConsole.logLimit / chunk.count + 2
        for _ in 0..<chunkCount {
            try guest.output.write(contentsOf: chunk)
        }
        try guest.output.write(contentsOf: Data("tail".utf8))
        await waitFor { console.transcript.suffix(4) == Data("tail".utf8) }
        console.disconnect()

        let previous = logURL.deletingPathExtension().appendingPathExtension("previous.log")
        let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        #expect(size(logURL) <= SerialConsole.logLimit)
        #expect(size(previous) <= SerialConsole.logLimit)
        #expect(size(logURL) + size(previous) == chunkCount * chunk.count + 4)
        #expect(try Data(contentsOf: logURL).suffix(4) == Data("tail".utf8))
    }
}
