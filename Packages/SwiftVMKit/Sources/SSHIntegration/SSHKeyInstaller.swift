import Foundation
import VMCore

/// Adds a public key to a guest account's `authorized_keys` by signing in once with the account's password.
///
/// Used for guests that can't be given a key before their first boot (macOS).
public enum SSHKeyInstaller {
    /// Environment variable that carries the password to the helper `ssh` asks for it. The password never
    /// touches the disk or a command line.
    static let passwordVariable = "SWIFTVM_SSH_PASSWORD"

    /// Appends the key it reads from standard input unless the file already lists it. Runs in the guest
    /// account's login shell.
    static let remoteCommand = """
        umask 077; mkdir -p ~/.ssh && key=$(cat) && \
        { grep -qxF -- "$key" ~/.ssh/authorized_keys 2>/dev/null || printf '%s\\n' "$key" >> ~/.ssh/authorized_keys; }
        """

    /// The `ssh` arguments that sign in to `alias` with a password only and run ``remoteCommand``.
    static func arguments(alias: String, configURL: URL) -> [String] {
        [
            "-F", configURL.path,
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=10",
            // A guest that is stopped in the middle of this says nothing more. Without these, `ssh`
            // would wait for it for good.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            alias,
            remoteCommand,
        ]
    }

    /// Signs in to the host `alias` from the SSH configuration at `configURL` and installs `publicKey`.
    ///
    /// Blocks until `ssh` exits; call it off the main thread. Throws when the guest refuses the connection
    /// or the password, which is expected while the guest is still setting itself up.
    public static func install(publicKey: String, on alias: String, configURL: URL, password: String) throws {
        let fileManager = FileManager.default
        let helper = fileManager.temporaryDirectory.appending(path: "swiftvm-askpass-\(UUID().uuidString).sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$\(passwordVariable)\"\n".write(to: helper, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: helper) }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        try ProcessRunner.run(
            "/usr/bin/ssh",
            arguments(alias: alias, configURL: configURL),
            environment: [
                "SSH_ASKPASS": helper.path,
                // Use the helper even though there is no display and no terminal.
                "SSH_ASKPASS_REQUIRE": "force",
                passwordVariable: password,
            ],
            input: Data((publicKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
        )
    }
}
