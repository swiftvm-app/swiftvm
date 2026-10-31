import Foundation
import GuestChannel

/// Runs agent-desktop in the session half, never in the root daemon or on the host.
enum DesktopJob {
    static let program = "/usr/local/lib/swiftvm/agent-desktop/agent-desktop"

    static func run(
        _ request: GuestJob.Desktop, on descriptor: Int32,
        system: any AgentSystem = MacSystem(), program: String = program
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
        let exec = GuestJob.Exec(
            arguments: [program] + request.arguments, user: NSUserName(),
            environment: ["TMPDIR": NSTemporaryDirectory()]
        )
        CommandJob.run(exec, on: descriptor, system: system)
    }
}
