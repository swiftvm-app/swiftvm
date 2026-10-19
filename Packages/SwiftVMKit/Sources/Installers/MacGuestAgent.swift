import Foundation
import GuestChannel
import VMCore

/// The guest agent for macOS and the ways it gets into a guest.
///
/// The agent is a program built from this project's sources (`Sources/GuestAgentMac`) that the app carries
/// inside itself. Whichever way it travels, it arrives as one shell script with the program and its two
/// launchd jobs inside: sent over SSH when a new machine has set itself up, through the existing agent
/// for a reinstall, or read from the guest tools disc. Installing takes root in the guest.
public enum MacGuestAgent {
    public enum AgentError: Error, LocalizedError {
        case missingProgram

        public var errorDescription: String? {
            switch self {
            case .missingProgram: "This copy of SwiftVM is missing the guest agent for macOS."
            }
        }
    }

    /// Where the agent and a copy of its installer live in a guest, as in Linux guests.
    public static let directory = LinuxGuestAgent.directory
    public static let installerPath = "\(directory)/install.sh"

    /// The version of the agent this build carries, as the agent reports it when it connects.
    public static let version = GuestProtocol.macAgentVersion

    /// What a person runs in the guest to install from the guest tools disc, which macOS mounts by itself.
    public static let toolsInstallCommand = "sudo sh /Volumes/\(LinuxGuestAgent.toolsVolumeName)/install.sh"

    /// A shell script that installs the agent, or replaces an older one, with everything it needs inside.
    ///
    /// - Parameter program: The agent, as it was built with this copy of the app.
    public static func installer(program: URL) throws -> String {
        guard let binary = try? Data(contentsOf: program), !binary.isEmpty else { throw AgentError.missingProgram }
        // Not `install-macos.sh`: a bundle takes a name that ends in `-macos` for the Mac's own version
        // of the file without it, and hands it out to whoever asks for `install.sh`.
        let script = try LinuxGuestAgent.resource("macos-install.sh")
        let encoded = binary.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return script.replacingOccurrences(of: "@@swiftvm-agent@@", with: encoded)
    }

    // MARK: The guest tools disc

    static func toolsFiles(program: URL) throws -> [String: Data] {
        let readMe = try LinuxGuestAgent.resource("macos-readme.txt").replacingOccurrences(of: "@@command@@", with: toolsInstallCommand)
        return [
            "install.sh": Data(try installer(program: program).utf8),
            "README.txt": Data(readMe.utf8),
        ]
    }

    /// Makes sure the guest tools disc for this build's agent is in `directory` and returns it. See
    /// ``LinuxGuestAgent/toolsImage(in:inUse:)``, whose discs these live next to.
    public static func toolsImage(in directory: URL, inUse: Set<String> = [], program: URL) throws -> URL {
        try GuestToolsDisc.image(
            prefix: toolsImagePrefix, volumeName: LinuxGuestAgent.toolsVolumeName, files: toolsFiles(program: program),
            in: directory, inUse: inUse
        )
    }

    /// Not a name that begins like the discs for Linux do: each kind clears away its own older discs.
    static let toolsImagePrefix = "SwiftVM macOS Guest Tools "

    /// Whether `path` is a guest tools disc made by ``toolsImage(in:inUse:program:)``.
    public static func isToolsImage(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix(toolsImagePrefix) && name.hasSuffix(".iso")
    }

    // MARK: Over SSH

    /// The `ssh` arguments that have root take the installer from standard input and run it.
    ///
    /// Root reads it straight into a folder of its own. Put down first where the account can write, it
    /// could be swapped for something else by any program the account runs, before root gets to it.
    ///
    /// What comes on standard input is the password's line if `sudo` is to read one, then a line that
    /// says `marker`, then the installer. Root's shell skips everything up to the marker, so that a
    /// `sudo` that didn't ask for the password after all doesn't leave it at the top of the installer.
    /// The shell is `sh`, whatever the account's own is.
    ///
    /// - Parameter readsPassword: Have `sudo` read the account's password from standard input. Without
    ///   it, `sudo` has to work without a password, which macOS doesn't allow unless someone set it up.
    static func installArguments(alias: String, configURL: URL, marker: String, readsPassword: Bool) -> [String] {
        let sudo = readsPassword ? "sudo -S -p \"\"" : "sudo -n"
        let asRoot = "found=; while IFS= read -r line; do if [ \"$line\" = \"\(marker)\" ]; then found=1; break; fi; done; "
            + "[ -n \"$found\" ] || exit 1; umask 077; d=$(mktemp -d /tmp/swiftvm-tools.XXXXXXXX) || exit 1; "
            + "cat > \"$d/install.sh\" && sh \"$d/install.sh\"; code=$?; rm -rf \"$d\"; exit $code"
        return [
            "-F", configURL.path,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            // Without these `ssh` waits for good for a guest that has gone.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            alias,
            "\(sudo) /bin/sh -c '\(asRoot)'",
        ]
    }

    /// What goes to `ssh`'s standard input for ``installArguments(alias:configURL:marker:readsPassword:)``.
    static func installInput(installer: String, marker: String, password: String?) -> Data {
        Data(((password.map { $0 + "\n" } ?? "") + marker + "\n" + installer).utf8)
    }

    /// Installs the agent over SSH. Needs key sign-in, and the account's `password` for `sudo` unless
    /// the account may use `sudo` without one. Blocks until `ssh` exits; call it off the main thread.
    ///
    /// The password only ever travels on `ssh`'s standard input, to `sudo`'s.
    public static func install(on alias: String, configURL: URL, password: String?, program: URL) throws {
        // A line that nothing in the installer or in a password can be.
        let marker = "swiftvm-installer-\(UUID().uuidString)"
        try ProcessRunner.run(
            "/usr/bin/ssh",
            installArguments(alias: alias, configURL: configURL, marker: marker, readsPassword: password != nil),
            input: installInput(installer: try installer(program: program), marker: marker, password: password)
        )
    }

    /// What the installer itself said when it gave up, if that is why `failure` happened. `nil` when it
    /// never ran, because signing in or `sudo` didn't work: then the guest tools disc is another way in.
    public static func installerComplaint(in failure: ProcessRunner.Failure) -> String? {
        LinuxGuestAgent.installerComplaint(in: failure)
    }
}
