import Foundation
import VMCore

/// Sets a macOS guest's time zone over SSH.
///
/// A guest that sets itself up never gets asked where it is, which leaves it on Pacific time wherever the
/// host is. Needs key sign-in to work already (see ``SSHKeyInstaller``) and the account's password for `sudo`.
public enum GuestTimeZone {
    /// Whether `identifier` looks like a time zone name such as `Europe/Berlin` and is safe to put in a
    /// shell command.
    static func isValidIdentifier(_ identifier: String) -> Bool {
        guard let first = identifier.first, first.isLetter else { return false }
        return !identifier.contains("..")
            && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/_+-".contains($0)) }
    }

    /// The `ssh` arguments that set the time zone of `alias`. `sudo` reads the password from standard input.
    static func arguments(identifier: String, alias: String, configURL: URL) -> [String] {
        [
            "-F", configURL.path,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            // Without these `ssh` waits for good for a guest that has gone.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            alias,
            // systemsetup grumbles on standard error even when it succeeds.
            "sudo -S -p '' /usr/sbin/systemsetup -settimezone '\(identifier)' >/dev/null 2>&1",
        ]
    }

    /// Gives the guest behind `alias` the time zone `identifier` (by default the host's).
    ///
    /// Blocks until `ssh` exits; call it off the main thread.
    public static func set(
        _ identifier: String = TimeZone.current.identifier,
        on alias: String,
        configURL: URL,
        password: String
    ) throws {
        guard isValidIdentifier(identifier) else {
            throw VMError.invalidConfiguration("“\(identifier)” isn't a time zone name.")
        }
        try ProcessRunner.run(
            "/usr/bin/ssh",
            arguments(identifier: identifier, alias: alias, configURL: configURL),
            input: Data((password + "\n").utf8)
        )
    }
}
