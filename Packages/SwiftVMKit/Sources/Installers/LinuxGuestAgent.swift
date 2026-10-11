import Foundation
import VMCore

/// The guest agent for Linux and the ways it gets into a guest.
///
/// The agent is a Python script that runs as a systemd service (`Resources/GuestAgent`). It needs no
/// toolchain on the Mac to build and nothing in the guest beyond what the cloud images of the supported
/// distributions already have. Whichever way it travels, it arrives as one shell script that carries the
/// agent and its units inside: written by cloud-init on a new machine's first start, read from the guest
/// tools disc, or sent over SSH.
public enum LinuxGuestAgent {
    public enum AgentError: Error, LocalizedError {
        case missingResource(String)

        public var errorDescription: String? {
            switch self {
            case .missingResource(let name): "This copy of SwiftVM is missing “\(name)”."
            }
        }
    }

    /// Where the agent and a copy of its installer live in a guest.
    public static let directory = "/usr/local/lib/swiftvm"
    public static let installerPath = "\(directory)/install.sh"

    /// The volume label of the guest tools disc, which is how a guest finds it.
    public static let toolsVolumeName = "SWIFTVM"

    /// What a person runs in the guest to install from the guest tools disc. It mounts the disc itself, so
    /// it works whether or not the guest's desktop has done so, and in a guest without a desktop.
    public static let toolsInstallCommand =
        "sudo sh -c 'mkdir -p /run/swiftvm-tools && mount -o ro /dev/disk/by-label/\(toolsVolumeName) /run/swiftvm-tools"
        + " && sh /run/swiftvm-tools/install.sh; umount /run/swiftvm-tools'"

    static let fileNames = ["swiftvm-agent.py", "swiftvm-agent.service", "swiftvm-sshd-vsock.socket", "swiftvm-sshd-vsock@.service"]

    static func resourceURL(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: name)
        return Bundle.module.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension)
    }

    static func resource(_ name: String) throws -> String {
        guard let url = resourceURL(name), let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentError.missingResource(name)
        }
        return text
    }

    /// The version of the agent this build carries, as the agent reports it when it connects.
    public static let version: String? = (try? resource("swiftvm-agent.py")).flatMap(version(ofScript:))

    static func version(ofScript script: String) -> String? {
        for line in script.split(separator: "\n") where line.hasPrefix("AGENT_VERSION") {
            let parts = line.split(separator: "\"")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    /// A shell script that installs the agent, or replaces an older one, with everything it needs inside.
    public static func installer() throws -> String {
        var script = try resource("install.sh")
        for name in fileNames {
            // The files end with a line break, and so does the line their place is marked on.
            let contents = try resource(name)
            script = script.replacingOccurrences(of: "@@\(name)@@\n", with: contents.hasSuffix("\n") ? contents : contents + "\n")
        }
        return script
    }

    // MARK: The guest tools disc

    /// The files on the guest tools disc.
    static func toolsFiles() throws -> [String: Data] {
        let readMe = try resource("README.txt").replacingOccurrences(of: "@@command@@", with: toolsInstallCommand)
        return [
            "install.sh": Data(try installer().utf8),
            "README.txt": Data(readMe.utf8),
        ]
    }

    /// Makes sure the guest tools disc for this build's agent is in `directory` and returns it.
    ///
    /// The disc is named after what is on it, so a build with a different agent makes a disc of its own
    /// instead of rewriting one that a running guest may have plugged in. Discs of other builds are
    /// cleared away when nothing can be using them: pass the images that are attached to machines in
    /// `inUse`.
    public static func toolsImage(in directory: URL, inUse: Set<String> = []) throws -> URL {
        try GuestToolsDisc.image(prefix: toolsImagePrefix, volumeName: toolsVolumeName, files: toolsFiles(), in: directory, inUse: inUse)
    }

    static let toolsImagePrefix = "SwiftVM Guest Tools "

    /// Whether `path` is a guest tools disc made by ``toolsImage(in:inUse:)``.
    public static func isToolsImage(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix(toolsImagePrefix) && name.hasSuffix(".iso")
    }

    // MARK: Over SSH

    /// The `ssh` arguments that take the installer from standard input, put it where a guest keeps it,
    /// and run it there as root.
    static func installArguments(alias: String, configURL: URL) -> [String] {
        [
            "-F", configURL.path,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            // Without these `ssh` waits for good for a guest that has gone.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            alias,
            "sudo -n sh -c 'mkdir -p \(directory) && cat > \(installerPath) && sh \(installerPath)'",
        ]
    }

    /// Installs the agent over SSH. Needs key sign-in and `sudo` without a password, as guests set up by
    /// SwiftVM have. Blocks until `ssh` exits; call it off the main thread.
    public static func install(on alias: String, configURL: URL) throws {
        try ProcessRunner.run("/usr/bin/ssh", installArguments(alias: alias, configURL: configURL), input: Data(try installer().utf8))
    }

    /// What the installer itself said when it gave up, if that is why `failure` happened: the guest has
    /// no systemd, say, or no Python. `nil` when the installer never ran, because signing in or `sudo`
    /// didn't work. Then the guest tools disc is another way in; after the installer's own no it isn't.
    public static func installerComplaint(in failure: ProcessRunner.Failure) -> String? {
        for line in failure.output.standardError.split(whereSeparator: \.isNewline) where line.hasPrefix(installerPrefix) {
            let complaint = line.dropFirst(installerPrefix.count).trimmingCharacters(in: .whitespaces)
            return complaint.isEmpty ? nil : complaint
        }
        return nil
    }

    /// How every line starts that `install.sh` prints when it fails.
    static let installerPrefix = "swiftvm:"
}
