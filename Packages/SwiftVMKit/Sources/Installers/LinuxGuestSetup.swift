import Foundation
import VMCore

/// What carries a machine's ``SetupScript``s into a new Linux guest and runs them there.
///
/// The scripts travel in the machine's first-boot data together with a runner and a systemd unit
/// (`Resources/GuestSetup`). The first-boot setup writes them down and asks the runner to schedule the
/// unit, which runs the scripts one after the other once that setup is over. From then on the guest
/// sees to it alone: the runner keeps a note of how they are doing, which the guest agent passes on to
/// the app.
public enum LinuxGuestSetup {
    /// Where the scripts and what runs them live in a guest.
    public static let directory = "\(LinuxGuestAgent.directory)/setup"
    /// The scripts, each by its number in the order they run: `1`, `2`, and so on.
    public static let scriptsDirectory = "\(directory)/scripts"
    static let runnerPath = "\(directory)/run.sh"
    static let settingsPath = "\(directory)/settings"
    static let unitPath = "/etc/systemd/system/\(unitName)"
    static let unitName = "swiftvm-setup.service"

    /// What the first-boot setup runs once the files are written. The runner does nothing on a disk where
    /// a setup has been scheduled before, which is what a copy of a machine starts from.
    static let scheduleCommand = "sh \(runnerPath) --schedule || true"

    struct File: Equatable {
        var path: String
        var contents: String
        var permissions: String
    }

    /// Where the script that runs as number `number` lives in a guest, counting from 1.
    static func scriptPath(number: Int) -> String {
        "\(scriptsDirectory)/\(number)"
    }

    /// The files that go into a guest for `scripts`, which run in this order, with the scripts
    /// themselves first.
    ///
    /// - Parameter userName: The account the machine is created with, which the scripts are told.
    static func files(for scripts: [SetupScript], userName: String) throws -> [File] {
        var files: [File] = []
        for (index, script) in scripts.enumerated() {
            let path = scriptPath(number: index + 1)
            // For the administrator alone: a script may hold what isn't everyone's to read.
            files.append(File(path: path, contents: script.source, permissions: "0700"))
            // What it sets up, for the runner to say while it runs. Read as a line, never run.
            files.append(File(path: "\(path).name", contents: line(script.name, limit: SetupScript.maximumNameLength) + "\n", permissions: "0644"))
        }
        return files + [
            File(path: runnerPath, contents: try LinuxGuestAgent.resource("setup-run.sh"), permissions: "0755"),
            File(path: settingsPath, contents: settings(for: scripts, userName: userName), permissions: "0644"),
            File(path: unitPath, contents: try LinuxGuestAgent.resource(unitName), permissions: "0644"),
        ]
    }

    /// What the runner is told about the scripts and the machine, one `key=value` to a line. The runner
    /// reads the lines and never runs them, so a value can be anything that fits on one.
    static func settings(for scripts: [SetupScript], userName: String) -> String {
        """
        name=\(line(scripts.setupName, limit: 200))
        restart=\(scripts.restartsWhenDone ? "yes" : "no")
        user=\(line(userName, limit: 64))

        """
    }

    private static func line(_ text: String, limit: Int) -> String {
        SetupScript.cleaned(text, limit: limit)
    }
}
