import Foundation

/// `swiftvm-agent run-as`: becomes an account of this system, and then the command it was given.
///
/// The half of the agent that runs as root starts every command this way. The process makes itself the
/// head of a process group, so that calling the command off reaches everything it started by one
/// number. A command for whoever is logged in at the screen takes a detour through `launchctl asuser`,
/// which puts it inside that user's session: started from a daemon as it is, it could run there but
/// not open a window.
///
/// This is no way to become someone else. It only drops what the caller already has: root can become
/// an account, and nobody else can become anything.
enum RunAs {
    static let mode = "run-as"
    /// Start the command inside the session of the account, which is logged in at the screen.
    static let inSession = "--in-session"
    /// What the detour through launchd comes back with: all that is left to do is to become the
    /// account and the command.
    private static let arrived = "--arrived"

    static let usage = "Usage: swiftvm-agent run-as <account> [--in-session] -- <command> [arguments]"

    /// Runs the command, which takes this process over. Returns only when that didn't work, with the
    /// status to exit with: 127 for a command that isn't there, 126 for anything else, as a shell has it.
    static func run(_ arguments: [String]) -> Int32 {
        guard let separator = arguments.firstIndex(of: "--"), separator >= 1, separator + 1 < arguments.count else {
            complain(usage)
            return 64
        }
        let name = arguments[0]
        let options = Set(arguments[1..<separator])
        let command = Array(arguments[(separator + 1)...])
        guard let account = MacSystem.account(named: name) else {
            complain("This Mac has no account named “\(name)”.")
            return 126
        }
        if !options.contains(arrived) {
            // Where this process is already the head of a group, that is all it takes.
            if setsid() < 0 {
                setpgid(0, 0)
            }
            if options.contains(inSession), getuid() == 0 {
                replaceProcess(["/bin/launchctl", "asuser", String(account.user), MacSystem.programPath, mode, name, arrived, "--"] + command, searchingPath: false)
                // launchd wouldn't have it. The command runs all the same, outside the session.
            }
        }
        if getuid() == 0, account.user != 0 {
            guard initgroups(account.name, Int32(bitPattern: account.group)) == 0, setgid(account.group) == 0, setuid(account.user) == 0 else {
                complain("Couldn't become “\(name)”: \(String(cString: strerror(errno)))")
                return 126
            }
        }
        replaceProcess(command, searchingPath: true)
        let code = errno
        complain("\(command[0]): \(String(cString: strerror(code)))")
        return code == ENOENT ? 127 : 126
    }

    /// Turns this process into `command`. Returns only if that failed, with `errno` saying why.
    private static func replaceProcess(_ command: [String], searchingPath: Bool) {
        var arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
        arguments.append(nil)
        if searchingPath {
            execvp(command[0], arguments)
        } else {
            execv(command[0], arguments)
        }
        let code = errno
        for argument in arguments {
            free(argument)
        }
        errno = code
    }

    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data("swiftvm-agent: \(message)\n".utf8))
    }
}
