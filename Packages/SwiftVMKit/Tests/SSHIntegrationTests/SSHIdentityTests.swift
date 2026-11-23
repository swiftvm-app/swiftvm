import Darwin
import Foundation
import Testing
@testable import SSHIntegration
import VMCore

@Suite struct SSHIdentityTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm identities \(UUID())")

    private func pair(in name: String) throws -> SSHKeyManager.KeyPair {
        try SSHKeyManager(sshDirectory: root.appending(path: name)).preferredKeyPair()
    }

    @Test func explicitSelectionValidatesThePairWithoutSelectingAnotherKey() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = try pair(in: "personal")
        let chosen = try pair(in: "chosen")
        let selected = try SSHKeyManager.selectedKeyPair(at: URL(fileURLWithPath: chosen.privateKeyPath))
        #expect(selected.privateKeyPath == chosen.privateKeyPath)
        #expect(selected.publicKey == chosen.publicKey.split(separator: " ").prefix(2).joined(separator: " "))
        #expect(selected.publicKey != personal.publicKey)
        try personal.publicKey.write(toFile: chosen.privateKeyPath + ".pub", atomically: true, encoding: .utf8)
        #expect(throws: SSHKeyManager.IdentityProblem.mismatchedPair) {
            try SSHKeyManager.selectedKeyPair(at: URL(fileURLWithPath: chosen.privateKeyPath))
        }
        #expect(try SSHKeyManager(sshDirectory: root.appending(path: "personal")).preferredKeyPair() == personal)
    }

    @Test(.timeLimit(.minutes(1))) func encryptedSelectionFailsWithoutPromptingOrFallingBack() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try pair(in: "personal")
        let key = root.appending(path: "encrypted")
        try ProcessRunner.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "password", "-f", key.path])
        #expect(throws: SSHKeyManager.IdentityProblem.unusableKey) { try SSHKeyManager.selectedKeyPair(at: key) }
    }

    @Test(arguments: ["mode", "private-link", "public-link", "hard-link"])
    func unsafeFilesAreRefused(_ kind: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = try pair(in: "chosen")
        let privateKey = URL(fileURLWithPath: chosen.privateKeyPath)
        let publicKey = URL(fileURLWithPath: chosen.privateKeyPath + ".pub")
        switch kind {
        case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privateKey.path)
        case "private-link", "public-link":
            let file = kind == "private-link" ? privateKey : publicKey
            let moved = file.appendingPathExtension("moved")
            try FileManager.default.moveItem(at: file, to: moved)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        default:
            try #require(link(privateKey.path, root.appending(path: "another-name").path) == 0)
        }
        #expect(throws: SSHKeyManager.IdentityProblem.unsafeFile) { try SSHKeyManager.selectedKeyPair(at: privateKey) }
    }

    @Test func concurrentManagedCreationPublishesOnePairAndReusesIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = try pair(in: "personal")
        let personalBytes = try Data(contentsOf: URL(fileURLWithPath: personal.privateKeyPath))
        let destination = root.appending(path: "SSH Identity")
        let results = try await withThrowingTaskGroup(of: SSHKeyManager.KeyPair.self) { group in
            for _ in 0..<4 { group.addTask { try SSHKeyManager.managedKeyPair(in: destination) } }
            var pairs: [SSHKeyManager.KeyPair] = []
            for try await pair in group { pairs.append(pair) }
            return pairs
        }
        let first = try #require(results.first)
        #expect(results.count == 4 && results.allSatisfy { $0 == first })
        #expect(try SSHKeyManager.managedKeyPair(in: destination) == first)
        #expect(first.privateKeyPath.hasPrefix(destination.path + "/"))
        let unchanged = try Data(contentsOf: URL(fileURLWithPath: personal.privateKeyPath)) == personalBytes
        #expect(unchanged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["SSH Identity", "personal"])
    }

    @Test func partialManagedIdentitiesArePreservedWithoutRepair() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try pair(in: "personal")
        let destination = root.appending(path: "SSH Identity")
        let first = try SSHKeyManager.managedKeyPair(in: destination)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: first.privateKeyPath))
        try FileManager.default.removeItem(atPath: first.privateKeyPath + ".pub")
        #expect(throws: SSHKeyManager.IdentityProblem.missingPair) { try SSHKeyManager.managedKeyPair(in: destination) }
        let unchanged = try Data(contentsOf: URL(fileURLWithPath: first.privateKeyPath)) == bytes
        #expect(unchanged)
        #expect(!FileManager.default.fileExists(atPath: first.privateKeyPath + ".pub"))
    }

    @Test(arguments: ["\n", "'", "\"", "\\", "%", "$", "#"])
    func pathsThatSSHWouldParseOrExpandAreRefused(_ character: String) throws {
        #expect(throws: SSHKeyManager.IdentityProblem.unsafePath) {
            try SSHKeyManager.selectedKeyPair(at: root.appending(path: "key" + character))
        }
    }
}
