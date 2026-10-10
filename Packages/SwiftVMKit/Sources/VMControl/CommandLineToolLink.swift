import Foundation

/// The link that puts the `swiftvm` tool on the `PATH`: a symbolic link in `/usr/local/bin` that leads to
/// the tool inside the app.
public struct CommandLineToolLink: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Nothing is in the link's place.
        case notInstalled
        /// The link is there and leads to this tool.
        case installed
        /// Something else is in its place: a link to another copy of the tool (its path is given, whether
        /// or not that copy still exists), or a file that isn't a link at all.
        case occupied(linkedTo: String?)
    }

    public enum LinkError: Error, LocalizedError {
        case folderInTheWay(String)

        public var errorDescription: String? {
            switch self {
            case .folderInTheWay(let path): "“\(path)” is a folder. Move it away first."
            }
        }
    }

    /// `/usr/local/bin` is on the `PATH` of every shell on macOS, and is where tools that don't come with
    /// the system belong.
    public static let defaultLinkURL = URL(fileURLWithPath: "/usr/local/bin/swiftvm")

    /// The tool inside the app.
    public var toolURL: URL
    public var linkURL: URL

    public init(toolURL: URL, linkURL: URL = CommandLineToolLink.defaultLinkURL) {
        self.toolURL = toolURL
        self.linkURL = linkURL
    }

    public var status: Status {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) else {
            // Not a link. A file or a folder of that name is still in the way.
            return (try? fileManager.attributesOfItem(atPath: linkURL.path)) == nil ? .notInstalled : .occupied(linkedTo: nil)
        }
        // A relative destination counts from the folder the link is in.
        let target = URL(fileURLWithPath: destination, relativeTo: linkURL.deletingLastPathComponent()).standardizedFileURL
        let leadsHere = target.resolvingSymlinksInPath().path == toolURL.resolvingSymlinksInPath().path
        return leadsHere ? .installed : .occupied(linkedTo: target.path)
    }

    /// Puts the link in place, replacing a link or file that is there. Throws when that takes more rights
    /// than this process has, which for `/usr/local/bin` is the rule: then ``installCommand`` is to be run
    /// as an administrator.
    public func install() throws {
        let fileManager = FileManager.default
        if let type = try? fileManager.attributesOfItem(atPath: linkURL.path)[.type] as? FileAttributeType {
            // Removing a folder would take everything in it along.
            guard type != .typeDirectory else { throw LinkError.folderInTheWay(linkURL.path) }
            try fileManager.removeItem(at: linkURL)
        } else {
            try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: toolURL)
    }

    /// Takes the link away again, if it is there. Throws when that takes more rights than this process has.
    public func remove() throws {
        guard status != .notInstalled else { return }
        try FileManager.default.removeItem(at: linkURL)
    }

    /// Whether `error`, thrown by ``install()`` or ``remove()``, says that this process isn't allowed to,
    /// so that the same as an administrator would work. Anything else wouldn't be helped by a password.
    public static func isLackOfRights(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain: return error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError
        case NSPOSIXErrorDomain: return error.code == Int(EACCES) || error.code == Int(EPERM)
        default: return false
        }
    }

    /// What ``install()`` does, as a shell command.
    public var installCommand: String {
        let folder = Self.shellQuoted(linkURL.deletingLastPathComponent().path)
        // -h: if a link to a folder is in the way, replace it rather than put the new link inside that folder.
        return "/bin/mkdir -p \(folder) && /bin/ln -sfh \(Self.shellQuoted(toolURL.path)) \(Self.shellQuoted(linkURL.path))"
    }

    /// What ``remove()`` does, as a shell command.
    public var removeCommand: String {
        "/bin/rm -f \(Self.shellQuoted(linkURL.path))"
    }

    /// An AppleScript that runs `command` as an administrator, after the system has asked for a password
    /// with `prompt` as the explanation. To be handed to `/usr/bin/osascript -e`.
    public static func administratorScript(running command: String, prompt: String) -> String {
        "do shell script \(appleScriptQuoted(command)) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"
    }

    /// Whether `message`, the complaint of an `osascript` that failed, says that the user cancelled when
    /// asked for the password.
    public static func isCancellation(_ message: String) -> Bool {
        message.contains("(-128)")
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
