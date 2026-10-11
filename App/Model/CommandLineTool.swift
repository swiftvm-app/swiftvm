import Foundation
import VMControl
import VMCore

/// Putting the `swiftvm` tool on the `PATH`, for the button in Settings.
extension AppModel {
    /// The link in `/usr/local/bin` that leads to this app's tool, if this build has the tool inside.
    var commandLineToolLink: CommandLineToolLink? {
        commandLineToolURL.map { CommandLineToolLink(toolURL: $0) }
    }

    /// Installs or removes the link. `/usr/local/bin` usually belongs to the system; then macOS asks for
    /// an administrator's password first.
    ///
    /// - Returns: What went wrong, or `nil` if nothing did. Cancelling the password dialog isn't a problem.
    func setCommandLineToolInstalled(_ installed: Bool) async -> String? {
        guard let link = commandLineToolLink else { return nil }
        do {
            try installed ? link.install() : link.remove()
            return nil
        } catch where !CommandLineToolLink.isLackOfRights(error) {
            // A folder in the way, a volume that can't be written to: no password would help.
            return error.localizedDescription
        } catch {
            // Not allowed to. The same again, as an administrator.
        }
        let folder = link.linkURL.deletingLastPathComponent().path
        let script = CommandLineToolLink.administratorScript(
            running: installed ? link.installCommand : link.removeCommand,
            prompt: installed
                ? "\(AppIdentity.current.name) wants to add the swiftvm command to \(folder)."
                : "\(AppIdentity.current.name) wants to remove the swiftvm command from \(folder)."
        )
        do {
            // The dialog stays up for as long as the user takes; keep the app responsive meanwhile.
            _ = try await Task.detached { try ProcessRunner.run("/usr/bin/osascript", ["-e", script]) }.value
            return nil
        } catch let failure as ProcessRunner.Failure where CommandLineToolLink.isCancellation(failure.output.standardError) {
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
