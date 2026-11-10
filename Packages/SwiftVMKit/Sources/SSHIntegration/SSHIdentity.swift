import Darwin
import Foundation
import VMCore

extension SSHKeyManager {
    public enum IdentityProblem: Error, LocalizedError, Equatable {
        case unsafePath, unsafeFile, missingPair, mismatchedPair, unusableKey, creationFailed

        public var errorDescription: String? {
            switch self {
            case .unsafePath: "SSH identity paths cannot contain control characters, quotes, backslashes, #, $, or %."
            case .unsafeFile: "The SSH identity must use regular files owned by this user, with no symbolic or multiple links. Its private key must not be accessible to other users, and its folder and public key must not be writable by them."
            case .missingPair: "An explicit SSH identity needs an existing private key and its adjacent .pub file. Partial managed identities are not replaced."
            case .mismatchedPair: "The selected SSH public and private keys do not match. No other identity was selected."
            case .unusableKey: "Explicit SSH selection needs a valid unencrypted key pair for noninteractive provisioning. Encrypted keys are refused even when loaded in an SSH agent."
            case .creationFailed: "The managed SSH identity could not be created safely. Existing key material was not replaced."
            }
        }
    }

    /// Validates an explicit, unencrypted pair without selecting any other key or prompting for a
    /// passphrase. Only the canonical public key leaves the host; the private key is used by its path.
    public static func selectedKeyPair(at privateKey: URL) throws -> KeyPair {
        try requireSafePath(privateKey)
        try requireSafeDirectory(privateKey.deletingLastPathComponent())
        try requireSafeFile(privateKey, isPrivate: true)
        let publicKey = URL(fileURLWithPath: privateKey.path + ".pub")
        try requireSafeFile(publicKey, isPrivate: false)
        let derived: String
        do {
            derived = try ProcessRunner.run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", privateKey.path]).standardOutput
        } catch {
            // Tool diagnostics and malformed input are not allowed to echo private key material.
            throw IdentityProblem.unusableKey
        }
        let saved = try String(contentsOf: publicKey, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.contains(where: \.isNewline),
              let savedKey = canonicalPublicKey(saved), let actualKey = canonicalPublicKey(derived),
              savedKey == actualKey else { throw IdentityProblem.mismatchedPair }
        return KeyPair(publicKey: actualKey, privateKeyPath: privateKey.path)
    }

    /// Creates or reuses a dedicated identity directory, without reading or replacing personal keys.
    /// The complete pair is published together, so another creator never observes our half-written key.
    public static func managedKeyPair(in directory: URL) throws -> KeyPair {
        try requireSafePath(directory)
        let parent = directory.deletingLastPathComponent()
        try requireSafeDirectory(parent)
        let privateKey = directory.appending(path: generatedKeyName)
        var existing = stat()
        if lstat(directory.path, &existing) == 0 {
            try requireSafeDirectory(directory)
            return try selectedKeyPair(at: privateKey)
        }
        guard errno == ENOENT else { throw IdentityProblem.creationFailed }
        let staging = parent.appending(path: ".ssh-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard mkdir(staging.path, 0o700) == 0 else { throw IdentityProblem.creationFailed }
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        do {
            try generate(at: staging.appending(path: generatedKeyName))
            _ = try selectedKeyPair(at: staging.appending(path: generatedKeyName))
        } catch { throw IdentityProblem.creationFailed }
        if renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, directory.path, UInt32(RENAME_EXCL)) == 0 {
            published = true
        } else if errno != EEXIST {
            throw IdentityProblem.creationFailed
        }
        // A simultaneous creator can win the exclusive rename. Reuse only a complete safe pair.
        try requireSafeDirectory(directory)
        return try selectedKeyPair(at: privateKey)
    }

    private static func requireSafePath(_ url: URL) throws {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"),
              path.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil,
              !path.contains(where: { "\"'\\%$#".contains($0) }) else { throw IdentityProblem.unsafePath }
    }

    private static func requireSafeDirectory(_ url: URL) throws {
        var file = stat()
        guard lstat(url.path, &file) == 0 else { throw IdentityProblem.missingPair }
        guard file.st_mode & S_IFMT == S_IFDIR, file.st_uid == getuid(), file.st_mode & 0o022 == 0 else {
            throw IdentityProblem.unsafeFile
        }
    }

    private static func requireSafeFile(_ url: URL, isPrivate: Bool) throws {
        var file = stat()
        guard lstat(url.path, &file) == 0 else { throw IdentityProblem.missingPair }
        guard file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1,
              file.st_mode & (isPrivate ? 0o077 : 0o022) == 0 else { throw IdentityProblem.unsafeFile }
    }

    private static func canonicalPublicKey(_ text: String) -> String? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, isPublicKeyLine(text) else { return nil }
        return "\(parts[0]) \(parts[1])"
    }
}
