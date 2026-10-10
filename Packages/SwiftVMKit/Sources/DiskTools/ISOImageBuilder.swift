import Foundation
import VMCore

/// Builds small ISO 9660 images, e.g. the cloud-init seed a Linux guest reads on first boot.
public enum ISOImageBuilder {
    /// Writes an ISO (with Joliet names) containing `files` at the root.
    ///
    /// - Parameters:
    ///   - volumeName: The volume label, e.g. `cidata` for cloud-init.
    ///   - files: File name → contents.
    ///   - url: Destination; replaced if it exists.
    /// Reads a text file from the root of the ISO at `url`.
    public static func text(of fileName: String, in url: URL) throws -> String {
        // bsdtar reads ISO 9660 and picks the Joliet names, which are the ones the files were written under.
        try ProcessRunner.run("/usr/bin/tar", ["-xOf", url.path, fileName]).standardOutput
    }

    public static func makeISO(volumeName: String, files: [String: Data], at url: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "swiftvm-iso-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for (name, contents) in files {
            try contents.write(to: staging.appending(path: name))
        }
        try? fileManager.removeItem(at: url)
        try ProcessRunner.run("/usr/bin/hdiutil", [
            "makehybrid", "-quiet",
            "-iso", "-joliet",
            "-default-volume-name", volumeName,
            "-o", url.path,
            staging.path,
        ])
    }
}
