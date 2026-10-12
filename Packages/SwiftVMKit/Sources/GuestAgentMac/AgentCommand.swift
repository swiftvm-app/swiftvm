import Foundation
import GuestChannel

/// The `swiftvm-agent` program: what it does for each way of calling it.
public enum AgentCommand {
    static let usage = """
        Usage: swiftvm-agent daemon      serve the SwiftVM app (as root, in a virtual machine; started by launchd)
               swiftvm-agent session     share the clipboard of the user who is logged in, and their screen,
                                         mouse and keyboard with the SwiftVM app (started by launchd)
               swiftvm-agent run-as <account> [--in-session] -- <command> [arguments]
                                         run a command as an account of this system (started by the daemon)
               swiftvm-agent --version
        """

    /// Runs the program and returns its exit status. The two modes that serve never return.
    public static func run(_ arguments: [String]) -> Int32 {
        switch arguments {
        case ["--version"]:
            print(GuestProtocol.macAgentVersion)
            return 0
        case ["daemon"]:
            // A line that the other side has dropped must not end this process.
            signal(SIGPIPE, SIG_IGN)
            let daemon = AgentDaemon(system: MacSystem(), queue: .main)
            daemon.listen()
            withExtendedLifetime(daemon) { dispatchMain() }
        case ["session"]:
            signal(SIGPIPE, SIG_IGN)
            let session = SessionAgent(pasteboard: SystemPasteboard(), queue: .main, desktop: MacDesktop())
            session.start()
            withExtendedLifetime(session) { dispatchMain() }
        case _ where arguments.first == RunAs.mode:
            return RunAs.run(Array(arguments.dropFirst()))
        default:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
    }
}
