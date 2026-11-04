import DiskTools
import Foundation
import GuestChannel
import Testing
import VMCore
@testable import Installers

@Suite struct LinuxGuestAgentTests {
    @Test func knowsTheVersionOfTheAgentItCarries() throws {
        #expect(LinuxGuestAgent.version(ofScript: "import os\nAGENT_VERSION = \"2.3\"\nPORT = 717\n") == "2.3")
        #expect(LinuxGuestAgent.version(ofScript: "print('hello')\n") == nil)
    }

    @Test func installsOverSSHAsRoot() {
        let arguments = LinuxGuestAgent.installArguments(alias: "web", configURL: URL(fileURLWithPath: "/tmp/ssh config"))
        #expect(arguments.prefix(2) == ["-F", "/tmp/ssh config"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ServerAliveInterval=5"))
        #expect(arguments.suffix(2) == [
            "web",
            "sudo -n sh -c 'umask 077; d=$(mktemp -d /tmp/swiftvm-tools.XXXXXXXX) || exit 1; "
                + "cat > \"$d/install.sh\" && sh \"$d/install.sh\"; code=$?; rm -rf \"$d\"; exit $code'",
        ])
    }

    @Test func tellsTheInstallersOwnNoFromNotGettingIn() throws {
        /// What `ssh` leaves behind when the far end printed `text` and failed.
        func failure(printing text: String) -> ProcessRunner.Failure? {
            do {
                try ProcessRunner.run("/bin/sh", ["-c", "cat >&2; exit 1"], input: Data(text.utf8))
                return nil
            } catch {
                return error as? ProcessRunner.Failure
            }
        }
        // The installer ran and refused: its reason is the answer, and a disc wouldn't change it.
        let noPython = try #require(failure(printing: "swiftvm: the guest agent needs Python 3 at /usr/bin/python3. Install it and run this again\n"))
        #expect(LinuxGuestAgent.installerComplaint(in: noPython) == "the guest agent needs Python 3 at /usr/bin/python3. Install it and run this again")
        let noisy = try #require(failure(printing: "Warning: Permanently added 'web' (ED25519) to the list of known hosts.\nswiftvm: this system doesn't use systemd, which the guest agent needs\n"))
        #expect(LinuxGuestAgent.installerComplaint(in: noisy) == "this system doesn't use systemd, which the guest agent needs")
        // It never ran: there was no way in, and the disc is one.
        for text in ["sudo: a password is required\n", "web: Permission denied (publickey).\n", "", "swiftvm:\n"] {
            let noWayIn = try #require(failure(printing: text))
            #expect(LinuxGuestAgent.installerComplaint(in: noWayIn) == nil)
        }
    }

    @Test func makesTheGuestToolsDiscOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let disc = try LinuxGuestAgent.toolsImage(in: directory)
        #expect(LinuxGuestAgent.isToolsImage(disc.path))
        #expect(!LinuxGuestAgent.isToolsImage("/Users/me/Downloads/ubuntu.iso"))
        #expect(try ISOImageBuilder.text(of: "install.sh", in: disc) == (try LinuxGuestAgent.installer()))
        // A guest finds the disc by its label.
        let label = try ProcessRunner.run("/usr/bin/tar", ["-tvf", disc.path]).standardOutput
        #expect(label.contains("install.sh"))

        // Asked again, the same disc comes back untouched: a guest may have it plugged in.
        let created = try FileManager.default.attributesOfItem(atPath: disc.path)[.modificationDate] as? Date
        #expect(try LinuxGuestAgent.toolsImage(in: directory) == disc)
        #expect(try FileManager.default.attributesOfItem(atPath: disc.path)[.modificationDate] as? Date == created)

        // Discs of other builds go, unless a machine still has one attached.
        let stale = directory.appending(path: "SwiftVM Guest Tools 000000000000.iso")
        let attached = directory.appending(path: "SwiftVM Guest Tools 111111111111.iso")
        let unrelated = directory.appending(path: "notes.txt")
        for url in [stale, attached, unrelated] {
            try Data("x".utf8).write(to: url)
        }
        #expect(try LinuxGuestAgent.toolsImage(in: directory, inUse: [attached.standardizedFileURL.path]) == disc)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: attached.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: disc.path))
    }
}
