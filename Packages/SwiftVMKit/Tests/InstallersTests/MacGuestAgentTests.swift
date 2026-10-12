import DiskTools
import Foundation
import GuestChannel
import Testing
import VMCore
@testable import Installers

@Suite struct MacGuestAgentTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tools-\(UUID().uuidString)")

    /// Something to carry in place of the agent, which is built with the app and not with this package.
    /// It has every byte in it, as a program has.
    private func makeProgram() throws -> (url: URL, contents: Data) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = directory.appending(path: "swiftvm-agent")
        try contents.write(to: url)
        return (url, contents)
    }

    @Test func aCopyOfTheAppWithoutTheProgramSaysSo() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = directory.appending(path: "nothing-here")
        #expect(throws: MacGuestAgent.AgentError.self) { try MacGuestAgent.installer(program: missing) }
        let empty = directory.appending(path: "empty")
        try Data().write(to: empty)
        #expect(throws: MacGuestAgent.AgentError.self) { try MacGuestAgent.installer(program: empty) }
        #expect(throws: MacGuestAgent.AgentError.self) { try MacGuestAgent.toolsImage(in: directory, program: missing) }
    }

    @Test func installsOverSSHAsRoot() {
        let config = URL(fileURLWithPath: "/tmp/ssh config")
        let arguments = MacGuestAgent.installArguments(alias: "mac", configURL: config, marker: "the-marker", readsPassword: true)
        #expect(arguments.prefix(2) == ["-F", "/tmp/ssh config"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ServerAliveInterval=5"))
        #expect(arguments[arguments.count - 2] == "mac")
        // sudo reads the password from its standard input, and root's own `sh` does the rest, whatever
        // the account's shell is. Nothing in it is quoted the way the whole is.
        let command = try! #require(arguments.last)
        #expect(command.hasPrefix("sudo -S -p \"\" /bin/sh -c '"))
        #expect(command.hasSuffix("'"))
        #expect(command.dropFirst("sudo -S -p \"\" /bin/sh -c '".count).dropLast().contains("'") == false)
        #expect(command.contains("\"the-marker\""))
        // Without a password it only works where sudo asks for none, and never stops to ask.
        let unattended = MacGuestAgent.installArguments(alias: "mac", configURL: config, marker: "the-marker", readsPassword: false)
        #expect(unattended.last?.hasPrefix("sudo -n /bin/sh -c '") == true)

        // The password comes first, on a line of its own, where sudo reads it. Then the marker, then
        // the installer.
        let input = MacGuestAgent.installInput(installer: "#!/bin/sh\necho hi\n", marker: "the-marker", password: "se cret\"$1")
        #expect(String(decoding: input, as: UTF8.self) == "se cret\"$1\nthe-marker\n#!/bin/sh\necho hi\n")
        #expect(String(decoding: MacGuestAgent.installInput(installer: "x\n", marker: "m", password: nil), as: UTF8.self) == "m\nx\n")
    }

    /// What root's shell is given to do, run here as an ordinary user with a script that only says
    /// what it was run as.
    private func runAsRootWould(input: String, marker: String = "the-marker") throws -> ProcessRunner.Output {
        let arguments = MacGuestAgent.installArguments(alias: "mac", configURL: URL(fileURLWithPath: "/tmp/c"), marker: marker, readsPassword: true)
        let prefix = "sudo -S -p \"\" /bin/sh -c '"
        let command = try #require(arguments.last)
        return try ProcessRunner.run("/bin/sh", ["-c", String(command.dropFirst(prefix.count).dropLast())], input: Data(input.utf8))
    }

    @Test func rootTakesTheInstallerFromStandardInputAndNothingElse() throws {
        let script = "echo \"ran as $0\"\ncat\n"
        // sudo took the password's line: the marker comes first.
        let plain = try runAsRootWould(input: "the-marker\n" + script)
        let ranAs = try #require(plain.standardOutput.split(separator: "\n").first.map(String.init))
        #expect(ranAs.hasPrefix("ran as /tmp/swiftvm-tools."))
        #expect(ranAs.hasSuffix("/install.sh"))
        // The installer is run from a folder of root's own and the folder is gone afterwards.
        #expect(!FileManager.default.fileExists(atPath: String(ranAs.dropFirst("ran as ".count))))

        // sudo didn't ask after all, and the password's line is still there. It is skipped, not run:
        // a password that happens to be a command does nothing.
        let leftOver = try runAsRootWould(input: "touch /tmp/swiftvm-test-must-not-exist\nthe-marker\n" + script)
        #expect(leftOver.standardOutput.hasPrefix("ran as /tmp/swiftvm-tools."))
        #expect(!leftOver.standardOutput.contains("touch"))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/swiftvm-test-must-not-exist"))

        // The installer's own status is what comes back.
        #expect(throws: ProcessRunner.Failure.self) { try runAsRootWould(input: "the-marker\necho \"swiftvm: no\" >&2\nexit 7\n") }
        do {
            _ = try runAsRootWould(input: "the-marker\necho \"swiftvm: not on this system\" >&2\nexit 7\n")
            Issue.record("a failing installer was reported as done")
        } catch let failure as ProcessRunner.Failure {
            #expect(failure.output.status == 7)
            #expect(MacGuestAgent.installerComplaint(in: failure) == "not on this system")
        }
        // Without the marker nothing is run at all: what came isn't what the app sends.
        #expect(throws: ProcessRunner.Failure.self) { try runAsRootWould(input: "echo ran\n") }
        #expect(throws: ProcessRunner.Failure.self) { try runAsRootWould(input: "") }
    }

    @Test func makesAGuestToolsDiscOfItsOwn() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = try makeProgram().url
        let discs = directory.appending(path: "Guest Tools")

        let disc = try MacGuestAgent.toolsImage(in: discs, program: program)
        #expect(try ISOImageBuilder.text(of: "install.sh", in: disc) == (try MacGuestAgent.installer(program: program)))

        // The discs for Linux live in the same folder. Neither kind clears the other's away.
        let linuxDisc = try LinuxGuestAgent.toolsImage(in: discs)
        #expect(linuxDisc != disc)
        #expect(FileManager.default.fileExists(atPath: disc.path))
        #expect(try MacGuestAgent.toolsImage(in: discs, program: program) == disc)
        #expect(FileManager.default.fileExists(atPath: linuxDisc.path))
        // Each kind knows its own discs.
        #expect(MacGuestAgent.isToolsImage(disc.path) && !MacGuestAgent.isToolsImage(linuxDisc.path))
        #expect(LinuxGuestAgent.isToolsImage(linuxDisc.path) && !LinuxGuestAgent.isToolsImage(disc.path))
        #expect(!MacGuestAgent.isToolsImage("/Users/me/Downloads/macOS.iso"))

        // A build with another agent makes another disc, and the one before goes unless a machine has it.
        let newer = directory.appending(path: "newer-agent")
        try Data("a newer agent".utf8).write(to: newer)
        let newerDisc = try MacGuestAgent.toolsImage(in: discs, inUse: [disc.standardizedFileURL.path], program: newer)
        #expect(newerDisc != disc)
        #expect(FileManager.default.fileExists(atPath: disc.path))
        #expect(try MacGuestAgent.toolsImage(in: discs, program: newer) == newerDisc)
        #expect(!FileManager.default.fileExists(atPath: disc.path))
        #expect(FileManager.default.fileExists(atPath: linuxDisc.path))
    }
}
