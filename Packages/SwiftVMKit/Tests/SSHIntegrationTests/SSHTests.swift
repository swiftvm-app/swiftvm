import Foundation
import Testing
@testable import SSHIntegration
import VMCore

@Suite struct SSHAliasTests {
    @Test func slugsMachineNames() {
        #expect(SSHAlias.slug(from: "Ubuntu 26.04") == "ubuntu-26-04")
        #expect(SSHAlias.slug(from: "Agent's Mac") == "agents-mac")
        #expect(SSHAlias.slug(from: "  Xcode   Builds!  ") == "xcode-builds")
        #expect(SSHAlias.slug(from: "Café Büro") == "cafe-buro")
        #expect(SSHAlias.slug(from: "!!!") == "vm")
    }

    @Test func makesAliasesUnique() {
        #expect(SSHAlias.unique("ubuntu", avoiding: []) == "ubuntu")
        #expect(SSHAlias.unique("ubuntu", avoiding: ["ubuntu", "ubuntu-2"]) == "ubuntu-3")
    }
}

@Suite struct SSHConfigWriterTests {
    private func makeWriter() -> (SSHConfigWriter, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm ssh \(UUID().uuidString)")
        let writer = SSHConfigWriter(
            generatedConfigURL: directory.appending(path: "app/ssh_config"),
            userConfigURL: directory.appending(path: "home/.ssh/config")
        )
        return (writer, directory)
    }

    @Test func rendersHostBlocks() {
        let knownHosts = URL(fileURLWithPath: "/tmp/known_hosts")
        let text = SSHConfigWriter.render([
            SSHHostEntry(alias: "web", hostName: "192.168.230.11", user: "deploy", port: 2222, identityFile: "/Users/me/.ssh/id_ed25519"),
            SSHHostEntry(alias: "ubuntu-26-04", hostName: "192.168.230.10", user: "me"),
            SSHHostEntry(alias: "bad alias", hostName: "192.168.230.12"),
        ], knownHostsURL: knownHosts)
        #expect(text.contains("Host ubuntu-26-04\n    HostName 192.168.230.10\n    User me\n"))
        #expect(text.contains("Host web\n    HostName 192.168.230.11\n    User deploy\n    Port 2222\n    IdentityFile /Users/me/.ssh/id_ed25519\n    IdentitiesOnly yes\n"))
        #expect(text.contains("UserKnownHostsFile /tmp/known_hosts"))
        #expect(!text.contains("bad alias"))
        // Sorted by alias.
        #expect(text.range(of: "Host ubuntu-26-04")!.lowerBound < text.range(of: "Host web")!.lowerBound)
    }

    @Test func installsIncludeOnceAndPreservesUserConfig() throws {
        let (writer, directory) = makeWriter()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "Host github.com\n    User git\n"
        try FileManager.default.createDirectory(at: writer.userConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: writer.userConfigURL, atomically: true, encoding: .utf8)

        #expect(!writer.isIncludeInstalled)
        try writer.installInclude()
        try writer.installInclude()
        #expect(writer.isIncludeInstalled)

        let updated = try String(contentsOf: writer.userConfigURL, encoding: .utf8)
        #expect(updated.components(separatedBy: "Include ").count == 2)
        #expect(updated.hasSuffix(original))
        // The path contains a space, so it must be quoted, and the Include must precede the first Host.
        #expect(updated.contains("Include \"\(writer.generatedConfigURL.path)\""))
        #expect(updated.range(of: "Include")!.lowerBound < updated.range(of: "Host github.com")!.lowerBound)

        try writer.removeInclude()
        #expect(try String(contentsOf: writer.userConfigURL, encoding: .utf8) == original)
    }

    @Test func createsUserConfigWhenMissing() throws {
        let (writer, directory) = makeWriter()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writer.installInclude()
        let attributes = try FileManager.default.attributesOfItem(atPath: writer.userConfigURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(writer.isIncludeInstalled)
    }

    @Test func writesGeneratedFileAndForgetsHostKeys() throws {
        let (writer, directory) = makeWriter()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writer.write([SSHHostEntry(alias: "web", hostName: "192.168.230.11")])
        #expect(try String(contentsOf: writer.generatedConfigURL, encoding: .utf8).contains("Host web"))

        try "web ssh-ed25519 AAAA1\nubuntu ssh-ed25519 AAAA2\n".write(to: writer.knownHostsURL, atomically: true, encoding: .utf8)
        writer.forgetHostKey(for: "web")
        let remaining = try String(contentsOf: writer.knownHostsURL, encoding: .utf8)
        #expect(!remaining.contains("AAAA1"))
        #expect(remaining.contains("AAAA2"))
    }
}

@Suite struct SSHKeyManagerTests {
    @Test func generatesKeyWhenNoneExists() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SSHKeyManager(sshDirectory: directory)
        #expect(manager.existingKeyPair() == nil)
        let pair = try manager.preferredKeyPair()
        #expect(pair.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(FileManager.default.fileExists(atPath: pair.privateKeyPath))
        // The generated key is found again instead of being regenerated.
        #expect(try manager.preferredKeyPair() == pair)
    }
}

@Suite struct SSHKeyInstallerTests {
    @Test func signsInWithThePasswordOnly() {
        let arguments = SSHKeyInstaller.arguments(alias: "macos-27", configURL: URL(fileURLWithPath: "/tmp/app/ssh_config"))
        #expect(arguments.prefix(2) == ["-F", "/tmp/app/ssh_config"])
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        // The host comes right before the command, after every option.
        #expect(arguments.suffix(2) == ["macos-27", SSHKeyInstaller.remoteCommand])
    }

    /// Runs the command the guest would run, with a scratch directory standing in for the account's home.
    @Test(arguments: ["/bin/sh", "/bin/zsh"])
    func remoteCommandAddsTheKeyOnce(shell: String) throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "swiftvm-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTests me@host"
        let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnotherKey other@host"

        for line in [key, key, other] {
            try ProcessRunner.run(
                shell, ["-c", SSHKeyInstaller.remoteCommand],
                environment: ["HOME": home.path], input: Data((line + "\n").utf8)
            )
        }

        let authorizedKeys = home.appending(path: ".ssh/authorized_keys")
        #expect(try String(contentsOf: authorizedKeys, encoding: .utf8) == "\(key)\n\(other)\n")
        let permissions = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        #expect(try permissions(authorizedKeys) == 0o600)
        #expect(try permissions(home.appending(path: ".ssh")) == 0o700)
    }
}

@Suite struct ProcessRunnerTests {
    @Test func passesEnvironmentAndInput() throws {
        let output = try ProcessRunner.run(
            "/bin/sh", ["-c", "printf '%s:' \"$SWIFTVM_TEST_VALUE\"; cat"],
            environment: ["SWIFTVM_TEST_VALUE": "from the caller"], input: Data("typed in".utf8)
        )
        #expect(output.standardOutput == "from the caller:typed in")
        // Without input the tool reads end-of-file straight away, and keeps the caller's own environment.
        #expect(try ProcessRunner.run("/bin/sh", ["-c", "cat; printf '%s' \"$HOME\""]).standardOutput == NSHomeDirectory())
    }

    @Test func survivesAToolThatIgnoresItsInput() throws {
        // Larger than a pipe buffer, so the write can't finish before the tool has gone away.
        let input = Data(repeating: 0x61, count: 1 << 20)
        #expect(throws: ProcessRunner.Failure.self) {
            try ProcessRunner.run("/bin/sh", ["-c", "exit 3"], input: input)
        }
    }
}

@Suite struct GuestTimeZoneTests {
    @Test func acceptsOnlyTimeZoneNames() {
        #expect(GuestTimeZone.isValidIdentifier("Europe/Berlin"))
        #expect(GuestTimeZone.isValidIdentifier("America/Argentina/Buenos_Aires"))
        #expect(GuestTimeZone.isValidIdentifier("Etc/GMT+5"))
        #expect(GuestTimeZone.isValidIdentifier("UTC"))
        #expect(!GuestTimeZone.isValidIdentifier(""))
        #expect(!GuestTimeZone.isValidIdentifier("Europe/Berlin'; rm -rf ~"))
        #expect(!GuestTimeZone.isValidIdentifier("../etc/passwd"))
        #expect(!GuestTimeZone.isValidIdentifier("-settimezone"))
        #expect(!GuestTimeZone.isValidIdentifier("Europe Berlin"))
    }

    @Test func refusesToRunWithAnythingElse() {
        #expect(throws: VMError.self) {
            try GuestTimeZone.set("$(reboot)", on: "mac", configURL: URL(fileURLWithPath: "/tmp/ssh_config"), password: "x")
        }
    }

    @Test func usesTheInstalledKeyAndKeepsThePasswordOffTheCommandLine() {
        let arguments = GuestTimeZone.arguments(identifier: "Europe/Berlin", alias: "macos-27", configURL: URL(fileURLWithPath: "/tmp/ssh_config"))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.last?.contains("sudo -S") == true)
        #expect(arguments.last?.contains("-settimezone 'Europe/Berlin'") == true)
        #expect(arguments[arguments.count - 2] == "macos-27")
    }
}
