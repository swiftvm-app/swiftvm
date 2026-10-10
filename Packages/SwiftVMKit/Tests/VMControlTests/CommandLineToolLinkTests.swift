import Foundation
import Testing
@testable import VMControl

@Suite struct CommandLineToolLinkTests {
    /// A folder to install into, with a stand-in for the tool inside an app.
    private struct Scratch {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-link-\(UUID().uuidString)")
        var tool: URL { root.appending(path: "SwiftVM.app/Contents/Helpers/swiftvm") }
        var link: CommandLineToolLink { CommandLineToolLink(toolURL: tool, linkURL: root.appending(path: "bin/swiftvm")) }

        init() throws {
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: tool)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func installsAndRemovesTheLink() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let link = scratch.link
        #expect(link.status == .notInstalled)

        // The folder doesn't have to exist yet; on many Macs /usr/local/bin doesn't.
        try link.install()
        #expect(link.status == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.linkURL.path) == scratch.tool.path)
        // Doing it again changes nothing.
        try link.install()
        #expect(link.status == .installed)

        try link.remove()
        #expect(link.status == .notInstalled)
    }

    @Test func tellsALinkToAnotherCopyFromItsOwn() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let link = scratch.link
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: link.linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // The app was moved or deleted: the link still points at where its tool used to be.
        let gone = scratch.root.appending(path: "Old/SwiftVM.app/Contents/Helpers/swiftvm")
        try fileManager.createSymbolicLink(at: link.linkURL, withDestinationURL: gone)
        #expect(link.status == .occupied(linkedTo: gone.path))
        try link.install()
        #expect(link.status == .installed)

        // A link that names the tool relative to its own folder is the same link.
        try fileManager.removeItem(at: link.linkURL)
        try fileManager.createSymbolicLink(atPath: link.linkURL.path, withDestinationPath: "../SwiftVM.app/Contents/Helpers/swiftvm")
        #expect(link.status == .installed)

        // Somebody else's file of that name is replaced only when asked to install.
        try fileManager.removeItem(at: link.linkURL)
        try Data("another tool".utf8).write(to: link.linkURL)
        #expect(link.status == .occupied(linkedTo: nil))
        try link.install()
        #expect(link.status == .installed)
    }

    @Test func leavesAFolderOfThatNameAlone() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let link = scratch.link
        let inside = link.linkURL.appending(path: "keep.txt")
        try FileManager.default.createDirectory(at: link.linkURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: inside)

        #expect(link.status == .occupied(linkedTo: nil))
        #expect(throws: CommandLineToolLink.LinkError.self) { try link.install() }
        #expect(FileManager.default.fileExists(atPath: inside.path))
    }

    @Test func onlyALackOfRightsCallsForAnAdministrator() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let link = scratch.link
        let folder = link.linkURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        // Taking away a link that isn't there is done already.
        try link.remove()

        // A folder that belongs to someone else, the way /usr/local/bin belongs to the system.
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        do {
            try link.install()
            Issue.record("Installing into a folder that can't be written to should fail.")
        } catch {
            #expect(CommandLineToolLink.isLackOfRights(error))
        }

        // The same for taking the link away again.
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try link.install()
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        do {
            try link.remove()
            Issue.record("Removing from a folder that can't be written to should fail.")
        } catch {
            #expect(CommandLineToolLink.isLackOfRights(error))
        }
        #expect(link.status == .installed)

        // Other troubles aren't cured by a password.
        #expect(!CommandLineToolLink.isLackOfRights(CommandLineToolLink.LinkError.folderInTheWay("/x")))
        #expect(!CommandLineToolLink.isLackOfRights(CocoaError(.fileWriteVolumeReadOnly)))
        #expect(!CommandLineToolLink.isLackOfRights(CocoaError(.fileNoSuchFile)))
    }

    /// Runs `command` the way the app runs the commands that need an administrator, minus the administrator.
    private func runThroughAppleScript(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(CommandLineToolLink.appleScriptQuoted(command))"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    @Test func theCommandsDoWhatTheMethodsDo() throws {
        // A path with everything in it that a shell or AppleScript could trip over.
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let awkward = scratch.root.appending(path: #"It's a "test" \ folder $HOME"#)
        let tool = awkward.appending(path: "SwiftVM.app/Contents/Helpers/swiftvm")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        let link = CommandLineToolLink(toolURL: tool, linkURL: awkward.appending(path: "bin/swiftvm"))

        _ = try runThroughAppleScript(link.installCommand)
        #expect(link.status == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.linkURL.path) == tool.path)

        // Over a link that leads to a folder, the new link replaces it instead of landing inside.
        try FileManager.default.removeItem(at: link.linkURL)
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: scratch.root)
        _ = try runThroughAppleScript(link.installCommand)
        #expect(link.status == .installed)
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appending(path: "swiftvm").path))

        _ = try runThroughAppleScript(link.removeCommand)
        #expect(link.status == .notInstalled)
    }

    @Test func asksForAnAdministratorWithAnExplanation() {
        let script = CommandLineToolLink.administratorScript(running: #"/bin/ln -sfh '/a "b"' /c"#, prompt: "SwiftVM wants to install “swiftvm”.")
        #expect(script == #"do shell script "/bin/ln -sfh '/a \"b\"' /c" with prompt "SwiftVM wants to install “swiftvm”." with administrator privileges"#)
        #expect(CommandLineToolLink.isCancellation("0:117: execution error: User canceled. (-128)"))
        #expect(!CommandLineToolLink.isCancellation("0:117: execution error: ln: /usr/local/bin/swiftvm: Read-only file system (1)"))
    }
}
