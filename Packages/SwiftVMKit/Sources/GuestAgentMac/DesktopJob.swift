import Foundation
import GuestChannel

/// Runs agent-desktop in the session half, never in the root daemon or on the host.
enum DesktopJob {
    static let program = "/usr/local/lib/swiftvm/agent-desktop/agent-desktop"

    static func run(
        _ request: GuestJob.Desktop, on descriptor: Int32,
        system: any AgentSystem = MacSystem(), program: String = program,
        helperFolder: URL = DesktopHelper.folder
    ) {
        guard !request.arguments.isEmpty, !request.arguments.contains(where: { $0.contains("\0") }) else {
            GuestJobLine.answer(.refusal("Missing agent-desktop arguments, or an argument contains a null byte."), on: descriptor)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: program) else {
            GuestJobLine.answer(.refusal("agent-desktop isn't installed in this guest. Connect the guest to the internet and reinstall Guest Tools with `swiftvm install-tools <machine>`."), on: descriptor)
            return
        }
        // The command host requires the user's private temporary directory, not the daemon's /tmp.
        // The session's bootstrap namespace is inherited by the command and its retained ref host.
        var environment = ["TMPDIR": NSTemporaryDirectory()]
        let installedHelper = URL(fileURLWithPath: program).deletingLastPathComponent().appending(path: DesktopHelper.name)
        if let helper = try? DesktopHelper.privateCopy(of: installedHelper, in: helperFolder) {
            environment[DesktopHelper.environmentVariable] = helper.path
        }
        let exec = GuestJob.Exec(arguments: [program] + request.arguments, user: NSUserName(), environment: environment)
        CommandJob.run(exec, on: descriptor, system: system)
    }
}

/// agent-desktop's clipboard helper, as the account at the screen may run it.
///
/// agent-desktop for macOS starts its clipboard helper only from a file that the account running it
/// owns, and that nobody else can change. The guest tools install it beside agent-desktop, owned by
/// root for every account, so each account gets a copy of its own and agent-desktop is told where.
/// Without one, agent-desktop still works, only its clipboard commands refuse.
enum DesktopHelper {
    static let name = "agent-desktop-macos-helper"
    static let environmentVariable = "AGENT_DESKTOP_MACOS_HELPER_PATH"
    /// Where the account's copy is kept. The folders above it belong to the account or to root and
    /// are no one else's to write to, which agent-desktop checks as well.
    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/SwiftVM/agent-desktop", directoryHint: .isDirectory)
    }

    /// The account's copy of `installed`, made or brought up to date: a copy that differs from the
    /// installed helper, such as one from before the guest tools were updated, is replaced.
    static func privateCopy(of installed: URL, in folder: URL) throws -> URL {
        let contents = try Data(contentsOf: installed)
        let copy = folder.appending(path: name)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A folder that was there already may have been made writable for others.
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        if isCurrent(copy, matching: contents) { return copy }
        // Written whole beside it, then moved over it: agent-desktop never finds half a helper.
        let staged = folder.appending(path: ".\(name).\(UUID().uuidString)")
        defer { try? files.removeItem(at: staged) }
        try contents.write(to: staged, options: .withoutOverwriting)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard rename(staged.path, copy.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: copy.path])
        }
        return copy
    }

    /// The copy is the account's own plain file, unchanged, which only the account may change.
    private static func isCurrent(_ copy: URL, matching contents: Data) -> Bool {
        var status = stat()
        guard lstat(copy.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == geteuid(),
              status.st_nlink == 1, status.st_mode & 0o022 == 0, status.st_mode & 0o111 != 0,
              Int(status.st_size) == contents.count
        else { return false }
        return (try? Data(contentsOf: copy)) == contents
    }
}
