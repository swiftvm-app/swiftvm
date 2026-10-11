import Foundation
import Testing

/// The scripts that build the app replace an app with a new one, and must never do that to an app a copy
/// is running from, nor to anything that isn't theirs. `scripts/common.sh` decides; this runs what it
/// decides with, against stand-ins for the app.
@Suite struct BuildScriptsTests {
    /// This file is four folders below the repository: Packages/SwiftVMKit/Tests/VMControlTests.
    private static let sharedScript: URL = {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repository.deleteLastPathComponent()
        }
        return repository.appending(path: "scripts/common.sh")
    }()

    private struct Scratch {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-scripts-\(UUID().uuidString)")

        /// Makes a stand-in for the app: its `Info.plist`, a program that does nothing for a minute, and
        /// a file that tells this stand-in from another.
        func makeApp(at path: String, identifier: String, marked mark: String) throws -> URL {
            let app = root.appending(path: path)
            let programs = app.appending(path: "Contents/MacOS")
            try FileManager.default.createDirectory(at: programs, withIntermediateDirectories: true)
            let properties = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
            try properties.write(to: app.appending(path: "Contents/Info.plist"))
            try Data(mark.utf8).write(to: app.appending(path: "Contents/mark"))

            // A copy of a system program wouldn't do: macOS ends those at once outside their own place.
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            compiler.arguments = ["-x", "c", "-o", programs.appending(path: "SwiftVM").path, "-"]
            let source = Pipe()
            compiler.standardInput = source
            compiler.standardError = FileHandle.nullDevice
            try compiler.run()
            source.fileHandleForWriting.write(Data("#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n".utf8))
            try source.fileHandleForWriting.close()
            compiler.waitUntilExit()
            try #require(compiler.terminationStatus == 0)
            return app
        }

        func mark(of app: URL) -> String? {
            try? String(contentsOf: app.appending(path: "Contents/mark"), encoding: .utf8)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// Runs `script` in zsh with `scripts/common.sh` loaded, the way the build scripts run.
    private func run(_ script: String, _ arguments: String...) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "set -euo pipefail; source \"$1\"; shift; \(script)", "zsh", Self.sharedScript.path] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let complained = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: printed, as: UTF8.self), String(decoding: complained, as: UTF8.self))
    }

    /// The process IDs that `running_from` finds for `app`.
    private func copiesRunning(from app: URL) throws -> Set<Int32> {
        let result = try run("running_from \"$1\"; print -l -- $reply", app.path)
        try #require(result.status == 0, "running_from failed: \(result.errors)")
        return Set(result.output.split(separator: "\n").compactMap { Int32($0) })
    }

    /// Starts `command` in a shell that becomes the program, in `folder`.
    private func start(_ command: String, in folder: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "exec \(command)"]
        process.currentDirectoryURL = folder
        try process.run()
        return process
    }

    /// Waits until `running_from` sees exactly `expected` for `app`, which takes a moment after a start.
    private func waitForCopies(_ expected: Set<Int32>, from app: URL) async throws -> Set<Int32> {
        var found: Set<Int32> = []
        for _ in 0..<40 {
            found = try copiesRunning(from: app)
            if found == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return found
    }

    @Test func findsTheCopiesThatRunFromAnApp() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let app = try scratch.makeApp(at: "A Folder (1)/SwiftVM.app", identifier: "com.swiftvm.app", marked: "app")
        let other = try scratch.makeApp(at: "Other/SwiftVM.app", identifier: "com.swiftvm.app", marked: "other")
        let link = scratch.root.appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(try copiesRunning(from: app).isEmpty)

        // One copy started by a path that says little, the way a shell or a debugger starts it, and one
        // through a link to the app.
        let relative = try start("./SwiftVM.app/Contents/MacOS/SwiftVM", in: app.deletingLastPathComponent())
        let linked = try start("'\(link.path)/Contents/MacOS/SwiftVM'", in: scratch.root)
        defer {
            relative.terminate()
            linked.terminate()
        }
        let both: Set<Int32> = [relative.processIdentifier, linked.processIdentifier]
        #expect(try await waitForCopies(both, from: app) == both)
        #expect(try copiesRunning(from: link) == both)
        #expect(try copiesRunning(from: other).isEmpty)

        let refusal = try run("refuse_if_running \"$1\"", app.path)
        #expect(refusal.status == 1)
        #expect(refusal.errors.contains("is running from"))
        #expect(try run("refuse_if_running \"$1\"", other.path).status == 0)

        relative.terminate()
        linked.terminate()
        relative.waitUntilExit()
        linked.waitUntilExit()
        #expect(try await waitForCopies([], from: app).isEmpty)
        #expect(try run("refuse_if_running \"$1\"", app.path).status == 0)
    }

    @Test func replacesOnlyACopyOfSwiftVMThatIsntRunning() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fileManager = FileManager.default
        let app = try scratch.makeApp(at: "Place/SwiftVM.app", identifier: "com.swiftvm.app", marked: "old")
        let new = try scratch.makeApp(at: "Staged/SwiftVM.app", identifier: "com.swiftvm.app", marked: "new")

        // Somebody else's app in the place.
        let foreign = try scratch.makeApp(at: "Foreign/Notes.app", identifier: "org.example.notes", marked: "theirs")
        let refused = try run("replace_app \"$1\" \"$2\"", new.path, foreign.path)
        #expect(refused.status == 1)
        #expect(refused.errors.contains("isn't a copy of SwiftVM"))
        #expect(scratch.mark(of: foreign) == "theirs")

        // A place that isn't an app at all.
        #expect(try run("replace_app \"$1\" \"$2\"", new.path, scratch.root.appending(path: "Place/SwiftVM").path).status == 1)

        // A copy running from the place.
        let running = try start("'\(app.path)/Contents/MacOS/SwiftVM'", in: scratch.root)
        defer { running.terminate() }
        #expect(try await waitForCopies([running.processIdentifier], from: app) == [running.processIdentifier])
        let busy = try run("replace_app \"$1\" \"$2\"", new.path, app.path)
        #expect(busy.status == 1)
        #expect(busy.errors.contains("is running from"))
        #expect(scratch.mark(of: app) == "old")
        #expect(scratch.mark(of: new) == "new")

        // Once it has quit, the new app takes the place and nothing is left lying next to it.
        running.terminate()
        running.waitUntilExit()
        #expect(try await waitForCopies([], from: app).isEmpty)
        let replaced = try run("replace_app \"$1\" \"$2\"", new.path, app.path)
        #expect(replaced.status == 0, "\(replaced.errors)")
        #expect(scratch.mark(of: app) == "new")
        #expect(!fileManager.fileExists(atPath: new.path))
        #expect(try fileManager.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["SwiftVM.app"])

        // A place where nothing is yet, in a folder that isn't there yet either.
        let fresh = scratch.root.appending(path: "Not Yet/SwiftVM Dev.app")
        #expect(try run("replace_app \"$1\" \"$2\"", app.path, fresh.path).status == 0)
        #expect(scratch.mark(of: fresh) == "new")
    }
}
