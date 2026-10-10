import Foundation
import VMCore

/// Finds or creates the SSH key that is installed into new guests.
public struct SSHKeyManager: Sendable {
    public struct KeyPair: Sendable, Hashable {
        /// The public key line, e.g. `ssh-ed25519 AAAA… comment`.
        public var publicKey: String
        public var privateKeyPath: String
    }

    public let sshDirectory: URL

    public init(sshDirectory: URL = URL.homeDirectory.appending(path: ".ssh", directoryHint: .isDirectory)) {
        self.sshDirectory = sshDirectory
    }

    /// Name of the key SwiftVM generates when the user has none.
    static let generatedKeyName = "swiftvm_ed25519"
    static let preferredKeyNames = ["id_ed25519", "id_ecdsa", "id_rsa", generatedKeyName]

    /// The user's existing key pair, preferring Ed25519.
    public func existingKeyPair() -> KeyPair? {
        for name in Self.preferredKeyNames {
            let privateKey = sshDirectory.appending(path: name)
            let publicKey = sshDirectory.appending(path: "\(name).pub")
            guard FileManager.default.fileExists(atPath: privateKey.path),
                  let line = try? String(contentsOf: publicKey, encoding: .utf8)
            else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isPublicKeyLine(trimmed) {
                return KeyPair(publicKey: trimmed, privateKeyPath: privateKey.path)
            }
        }
        return nil
    }

    /// The user's key pair, generating a dedicated Ed25519 key (without passphrase) if they have none.
    public func preferredKeyPair() throws -> KeyPair {
        if let existing = existingKeyPair() {
            return existing
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: sshDirectory.path) {
            try fileManager.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let privateKey = sshDirectory.appending(path: Self.generatedKeyName)
        try ProcessRunner.run("/usr/bin/ssh-keygen", [
            "-q", "-t", "ed25519", "-N", "", "-C", "swiftvm", "-f", privateKey.path,
        ])
        let line = try String(contentsOf: sshDirectory.appending(path: "\(Self.generatedKeyName).pub"), encoding: .utf8)
        return KeyPair(publicKey: line.trimmingCharacters(in: .whitespacesAndNewlines), privateKeyPath: privateKey.path)
    }

    static func isPublicKeyLine(_ line: String) -> Bool {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return false }
        return parts[0].hasPrefix("ssh-") || parts[0].hasPrefix("ecdsa-") || parts[0].hasPrefix("sk-")
    }
}
