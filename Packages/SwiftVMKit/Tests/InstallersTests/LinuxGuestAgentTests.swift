import DiskTools
import Foundation
import GuestChannel
import Testing
import VMCore
@testable import Installers

@Suite struct LinuxGuestAgentTests {
    @Test func theInstallerCarriesEverythingItInstalls() throws {
        let installer = try LinuxGuestAgent.installer()
        for name in LinuxGuestAgent.fileNames {
            let contents = try LinuxGuestAgent.resource(name)
            #expect(contents.hasSuffix("\n"))
            #expect(installer.contains("<<'SWIFTVM_END_OF_FILE'\n\(contents)SWIFTVM_END_OF_FILE\n"), "\(name) isn't in the installer as it is")
        }
        // No place is left unfilled, and nothing that was filled in ends its own file early: four files
        // open and close, and that is all.
        #expect(!installer.contains("@@"))
        #expect(installer.components(separatedBy: "SWIFTVM_END_OF_FILE").count == 9)
        #expect(installer.hasPrefix("#!/bin/sh\n"))
        // The shell at least reads it to the end.
        try ProcessRunner.run("/bin/sh", ["-n"], input: Data(installer.utf8))
    }

    @Test func knowsTheVersionOfTheAgentItCarries() throws {
        let version = try #require(LinuxGuestAgent.version)
        #expect(!version.isEmpty)
        #expect(LinuxGuestAgent.version(ofScript: "import os\nAGENT_VERSION = \"2.3\"\nPORT = 717\n") == "2.3")
        #expect(LinuxGuestAgent.version(ofScript: "print('hello')\n") == nil)
    }

    @Test func theAgentListensWhereTheAppConnects() throws {
        // The port is written down twice, once in each language.
        let script = try LinuxGuestAgent.resource("swiftvm-agent.py")
        #expect(script.contains("\nPORT = \(GuestProtocol.agentPort)\n"))
        #expect(script.contains("\nPROTOCOL_VERSION = \(GuestProtocol.version)\n"))
        #expect(script.contains("\nMAX_LINE = 256 * 1024\n"))
        #expect(GuestProtocol.maximumLineLength == 256 * 1024)
        #expect(GuestProtocol.agentPort < 1024)
        let unit = try LinuxGuestAgent.resource("swiftvm-agent.service")
        #expect(unit.contains("ExecStart=/usr/bin/python3 -I \(LinuxGuestAgent.directory)/swiftvm-agent.py\n"))
    }

    @Test func installsOverSSHAsRoot() {
        let arguments = LinuxGuestAgent.installArguments(alias: "web", configURL: URL(fileURLWithPath: "/tmp/ssh config"))
        #expect(arguments.prefix(2) == ["-F", "/tmp/ssh config"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ServerAliveInterval=5"))
        #expect(arguments.suffix(2) == [
            "web",
            "sudo -n sh -c 'mkdir -p /usr/local/lib/swiftvm && cat > /usr/local/lib/swiftvm/install.sh && sh /usr/local/lib/swiftvm/install.sh'",
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
        // The installer does start what it says on failing the way this looks for.
        #expect(try LinuxGuestAgent.resource("install.sh").contains("echo \"\(LinuxGuestAgent.installerPrefix) $*\" >&2"))
    }

    @Test func makesTheGuestToolsDiscOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let disc = try LinuxGuestAgent.toolsImage(in: directory)
        #expect(LinuxGuestAgent.isToolsImage(disc.path))
        #expect(!LinuxGuestAgent.isToolsImage("/Users/me/Downloads/ubuntu.iso"))
        #expect(try ISOImageBuilder.text(of: "install.sh", in: disc) == (try LinuxGuestAgent.installer()))
        let readMe = try ISOImageBuilder.text(of: "README.txt", in: disc)
        #expect(readMe.contains("    \(LinuxGuestAgent.toolsInstallCommand)\n"))
        #expect(!readMe.contains("@@"))
        // A guest finds the disc by its label.
        let label = try ProcessRunner.run("/usr/bin/tar", ["-tvf", disc.path]).standardOutput
        #expect(label.contains("install.sh"))
        #expect(LinuxGuestAgent.toolsInstallCommand.contains("/dev/disk/by-label/SWIFTVM "))

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

/// The agent itself, run on this Mac in the mode where it only says what it would do, against the app's
/// own end of the line. This is the one place where the two languages meet without a virtual machine.
///
/// It needs the `python3` that comes with Xcode or the command-line tools, which building this package
/// needs anyway.
@Suite(.serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
struct LinuxGuestAgentConversationTests {
    /// A running agent on a Unix socket of its own. It is stopped when this is released.
    private final class RunningAgent: @unchecked Sendable {
        let process = Process()
        let socketPath = "/tmp/swiftvm-agent-test-\(UInt32.random(in: 0...UInt32.max)).sock"
        private let output = Pipe()

        /// - Parameter setupDirectory: Where the agent looks for word of a setup script, as a guest
        ///   that was created with one has it.
        init(setupDirectory: URL? = nil) throws {
            let script = try #require(LinuxGuestAgent.resourceURL("swiftvm-agent.py"))
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", script.path, "--pretend-on", socketPath] + (setupDirectory.map { ["--setup-in", $0.path] } ?? [])
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: socketPath) {
                guard process.isRunning, Date() < deadline else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: socketPath])
                }
                usleep(20_000)
            }
        }

        deinit {
            process.terminate()
            unlink(socketPath)
        }

        /// A new connection to the agent, as a plain descriptor.
        func connectDescriptor() throws -> Int32 {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8) }
            // The socket's file is there a moment before the agent listens on it.
            let deadline = Date().addingTimeInterval(5)
            while true {
                let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if descriptor >= 0, result == 0 { return descriptor }
                let code = errno
                close(descriptor)
                guard code == ECONNREFUSED, Date() < deadline else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                usleep(10_000)
            }
        }

        /// The app's end of a new line to the agent.
        func connect() throws -> GuestAgentConnection {
            GuestAgentConnection(handle: FileHandle(fileDescriptor: try connectDescriptor(), closeOnDealloc: true))
        }

        /// What the agent has printed, once it has been stopped.
        func stopAndReadLog() -> String {
            process.terminate()
            // Reading up to the end is the wait: the pipe closes when the agent is gone. `waitUntilExit`
            // waits on the thread it is called on, which after an `await` may not be the one the agent
            // was started on, and then it never hears of the end.
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
    }

    @Test func theAgentAndTheAppUnderstandEachOther() async throws {
        let agent = try RunningAgent()
        let connection = try agent.connect()
        var messages = connection.messages.makeAsyncIterator()

        // It introduces itself and says what it holds, unasked.
        guard case .hello(let hello) = await messages.next() else {
            Issue.record("the agent didn't say hello first")
            return
        }
        #expect(hello.protocol == GuestProtocol.version)
        #expect(hello.agent == LinuxGuestAgent.version)
        #expect(hello.system.displayName?.isEmpty == false)
        #expect(hello.system.kernel?.isEmpty == false)
        #expect(hello.hostName?.isEmpty == false)
        guard case .addresses = await messages.next() else {
            Issue.record("the agent didn't report its addresses")
            return
        }

        connection.send(.hello(protocol: GuestProtocol.version))
        #expect(await connection.request { .setClock(id: $0, nanoseconds: 1_790_000_000_123_456_789) } == GuestRequestResult(id: 1, ok: true))
        #expect(await connection.request { .mountSharedFolders(id: $0, tag: "swiftvm", mountPoint: "/mnt/shared") }?.ok == true)
        #expect(await connection.request { .shutDown(id: $0) }?.ok == true)

        // What it can't do it refuses, and says why.
        let noTime = await connection.request { .setClock(id: $0, nanoseconds: -5) }
        #expect(noTime?.ok == false)
        #expect(noTime?.error?.isEmpty == false)
        #expect(await connection.request { .mountSharedFolders(id: $0, tag: "../etc", mountPoint: "/mnt/shared") }?.ok == false)
        #expect(await connection.request { .mountSharedFolders(id: $0, tag: "swiftvm", mountPoint: "mnt") }?.ok == false)
        // Shared folders go where things get mounted, not over the system, by whatever spelling.
        for elsewhere in ["/etc", "/mnt/../etc", "/mnt", "//etc", "/usr/local/mnt/shared"] {
            #expect(await connection.request { .mountSharedFolders(id: $0, tag: "swiftvm", mountPoint: elsewhere) }?.ok == false, "\(elsewhere)")
        }
        #expect(await connection.request { .mountSharedFolders(id: $0, tag: "swiftvm", mountPoint: "/media/shared/./folders") }?.ok == true)
        // A name that `mount` would take for an option isn't one.
        #expect(await connection.request { .mountSharedFolders(id: $0, tag: "-a", mountPoint: "/mnt/shared") }?.ok == false)
        // Something from a later version of the app gets a no rather than silence.
        connection.send(.unknown(type: "clipboard"))
        let stillThere = await connection.request { .setClock(id: $0, nanoseconds: 1) }
        #expect(stillThere?.ok == true)

        connection.close()
        let log = agent.stopAndReadLog()
        #expect(log.contains("Would set the clock to 1790000000123456789."))
        #expect(log.contains("Would mount swiftvm at /mnt/shared."))
        #expect(log.contains("Would mount swiftvm at /media/shared/folders."))
        #expect(!log.contains("etc"))
        #expect(log.contains("Would shut down."))
        #expect(!log.contains("Traceback"))
    }

    @Test func theAgentPassesOnHowTheSetupScriptIsDoing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-setup-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        /// Leaves word the way the runner in a guest does.
        func leaveWord(status: String, step: String) throws {
            try Data(step.utf8).write(to: directory.appending(path: "step"), options: .atomic)
            try Data(status.utf8).write(to: directory.appending(path: "status"), options: .atomic)
        }
        /// Whether what the agent says next about the setup comes to `wanted`. The runner writes the
        /// step and the state one after the other, and the agent may look in between.
        func hears(_ wanted: GuestSetupStatus, on messages: inout AsyncStream<AgentMessage>.AsyncIterator) async -> Bool {
            for _ in 0..<4 {
                guard case .setup(let status) = await messages.next() else { return false }
                if status == wanted { return true }
            }
            return false
        }
        // A script can call itself anything. What is passed on is one short line.
        let longName = "KDE \u{1B}[31mPlasma " + String(repeating: "x", count: 300)
        try leaveWord(status: "state=running\nname=\(longName)\nlater=ignored\n", step: "Downloading KDE Plasma\n")

        let agent = try RunningAgent(setupDirectory: directory)
        let connection = try agent.connect()
        var messages = connection.messages.makeAsyncIterator()
        guard case .hello(let hello) = await messages.next(), case .addresses = await messages.next() else {
            Issue.record("no greeting")
            return
        }
        #expect(hello.agent == LinuxGuestAgent.version)
        // Unasked, right after the greeting.
        guard case .setup(let first) = await messages.next() else {
            Issue.record("the agent said nothing about the setup")
            return
        }
        #expect(first.state == .running)
        #expect(first.step == "Downloading KDE Plasma")
        #expect(first.name?.hasPrefix("KDE [31mPlasma xxx") == true)
        #expect(first.name?.count == GuestSetupStatus.maximumTextLength)

        // The script gets on, and so does what the agent says.
        try leaveWord(status: "state=running\nname=KDE Plasma\n", step: "Installing KDE Plasma\n")
        #expect(await hears(GuestSetupStatus(state: .running, name: "KDE Plasma", step: "Installing KDE Plasma"), on: &messages))
        try leaveWord(status: "state=failed\nname=KDE Plasma\n", step: "Installing KDE Plasma\n")
        #expect(await hears(GuestSetupStatus(state: .failed, name: "KDE Plasma", step: "Installing KDE Plasma"), on: &messages))

        // The app, connecting anew, is told where things stand.
        let second = try agent.connect()
        var secondMessages = second.messages.makeAsyncIterator()
        guard case .hello = await secondMessages.next(), case .addresses = await secondMessages.next() else {
            Issue.record("no greeting on the second line")
            return
        }
        #expect(await secondMessages.next() == .setup(GuestSetupStatus(state: .failed, name: "KDE Plasma", step: "Installing KDE Plasma")))
        #expect(await second.request { .setClock(id: $0, nanoseconds: 5) }?.ok == true)
        second.close()
        #expect(!agent.stopAndReadLog().contains("Traceback"))
    }

    @Test func aNewConnectionTakesTheOldOnesPlace() async throws {
        // The app connects anew after a machine was suspended, without having hung up on the old line.
        let agent = try RunningAgent()
        let first = try agent.connect()
        var firstMessages = first.messages.makeAsyncIterator()
        guard case .hello = await firstMessages.next(), case .addresses = await firstMessages.next() else {
            Issue.record("no greeting on the first line")
            return
        }

        let second = try agent.connect()
        var secondMessages = second.messages.makeAsyncIterator()
        guard case .hello = await secondMessages.next() else {
            Issue.record("no greeting on the second line")
            return
        }
        // The first line is closed by the agent, the second one works.
        #expect(await firstMessages.next() == nil)
        #expect(await second.request { .setClock(id: $0, nanoseconds: 2) }?.ok == true)
        #expect(await first.request { .setClock(id: $0, nanoseconds: 3) } == nil)
    }

    @Test func theAgentSurvivesWhatIsNotTheProtocol() async throws {
        let agent = try RunningAgent()
        // Someone who sends half a megabyte without a line break. That isn't the protocol, and the agent
        // doesn't wait for the line to end: it hangs up.
        let rude = try agent.connectDescriptor()
        let wasHungUpOn = await Task.detached { () -> Bool in
            defer { close(rude) }
            _ = fcntl(rude, F_SETNOSIGPIPE, 1)
            let rubbish = [UInt8](repeating: UInt8(ascii: "x"), count: 64 * 1024)
            for _ in 0..<8 where write(rude, rubbish, rubbish.count) <= 0 {
                // Cut off in the middle of it.
                return true
            }
            // Everything fitted in somewhere on the way. The end of the line shows when reading: after
            // the agent's greeting comes nothing more.
            var buffer = [UInt8](repeating: 0, count: 4096)
            var waiting = pollfd(fd: rude, events: Int16(POLLIN), revents: 0)
            while poll(&waiting, 1, 10_000) == 1 {
                if read(rude, &buffer, buffer.count) <= 0 { return true }
            }
            return false
        }.value
        #expect(wasHungUpOn)

        // The next caller is served as if nothing had happened.
        let polite = try agent.connect()
        var politeMessages = polite.messages.makeAsyncIterator()
        guard case .hello = await politeMessages.next() else {
            Issue.record("the agent is gone")
            return
        }
        #expect(await polite.request { .setClock(id: $0, nanoseconds: 4) }?.ok == true)
        polite.close()
        #expect(!agent.stopAndReadLog().contains("Traceback"))
    }
}
