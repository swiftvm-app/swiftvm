import CryptoKit
import DiskTools
import Foundation

/// The discs that carry the guest tools into a guest that can't be reached over SSH.
enum GuestToolsDisc {
    /// Makes sure the disc with `files` on it is in `directory` and returns it.
    ///
    /// The disc is named `prefix` and then after what is on it, so a build with different tools makes a
    /// disc of its own instead of rewriting one that a running guest may have plugged in. Discs with
    /// the same prefix from other builds are cleared away, unless they are among `inUse`: a machine
    /// that has one attached wouldn't come back without it.
    static func image(prefix: String, volumeName: String, files: [String: Data], in directory: URL, inUse: Set<String>) throws -> URL {
        var hash = SHA256()
        for name in files.keys.sorted() {
            hash.update(data: Data(name.utf8))
            hash.update(data: files[name]!)
        }
        let digest = hash.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let url = directory.appending(path: "\(prefix)\(digest).iso")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for other in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let isOlderDisc = other.lastPathComponent.hasPrefix(prefix) && other.lastPathComponent != url.lastPathComponent
            if isOlderDisc, !inUse.contains(other.standardizedFileURL.path) {
                try? fileManager.removeItem(at: other)
            }
        }
        if !fileManager.fileExists(atPath: url.path) {
            // Built under another name and moved into place, so that a disc is either whole or not there.
            let unfinished = directory.appending(path: ".\(UUID().uuidString).iso")
            defer { try? fileManager.removeItem(at: unfinished) }
            try ISOImageBuilder.makeISO(volumeName: volumeName, files: files, at: unfinished)
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.moveItem(at: unfinished, to: url)
            }
        }
        return url
    }
}
