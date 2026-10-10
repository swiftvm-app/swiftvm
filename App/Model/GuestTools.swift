import Foundation
import Installers
import VMCore

/// Getting the guest tools into a guest.
extension AppModel {
    /// Where the guest tools discs are kept.
    var guestToolsDirectory: URL {
        library.rootDirectory.appending(path: "Guest Tools", directoryHint: .isDirectory)
    }

    /// Whether there is something to install in `machine`: a running guest that can have the guest tools
    /// and has none, or not the ones this version of the app brings.
    func offersGuestTools(for machine: VirtualMachine) -> Bool {
        machine.configuration.canHaveGuestAgent && machine.state == .running
            && machine.agent.version != LinuxGuestAgent.version
    }

    /// Installs the guest tools in a running guest over SSH, and returns once its agent has connected.
    ///
    /// That takes key sign-in and `sudo` without a password, which guests set up by SwiftVM have. For the
    /// others there is the disc: ``attachGuestToolsDisc(to:)``.
    func installGuestTools(on machine: VirtualMachine) async throws {
        try requireRunningGuest(machine)
        guard canSignIn(to: machine) else {
            throw VMError.invalidConfiguration(
                "“\(machine.name)” has no SSH name or no address, so the guest tools can't be installed over SSH. To install from inside the guest, use `swiftvm install-tools <machine> --disc`."
            )
        }
        let alias = machine.configuration.ssh.alias
        let configURL = sshWriter.generatedConfigURL
        try await Task.detached(priority: .userInitiated) {
            try LinuxGuestAgent.install(on: alias, configURL: configURL)
        }.value

        // The installer has started the agent; the app finds it at its next attempt, a second away at most.
        let deadline = ContinuousClock.now + .seconds(15)
        while machine.agent.version != LinuxGuestAgent.version {
            guard machine.state == .running, ContinuousClock.now < deadline else {
                throw VMError.invalidConfiguration(
                    "The guest tools were installed in “\(machine.name)”, but the agent hasn't connected. In the guest, `systemctl status swiftvm-agent` says why."
                )
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Plugs the guest tools disc into a running guest, for someone to install from inside it with
    /// ``LinuxGuestAgent/toolsInstallCommand``. Returns the disc, which may have been plugged in already.
    @discardableResult
    func attachGuestToolsDisc(to machine: VirtualMachine) async throws -> RemovableImage {
        try requireRunningGuest(machine)
        let directory = guestToolsDirectory
        // A disc of an earlier version may still be plugged into a machine, or into one of its snapshots,
        // which would not come back without it.
        let attached = Set(library.machines.flatMap { machine in
            ([machine.configuration] + machine.snapshots.map(\.configuration)).flatMap { $0.removableImages.map(\.path) }
        })
        let disc = try await Task.detached(priority: .userInitiated) {
            try LinuxGuestAgent.toolsImage(in: directory, inUse: attached)
        }.value
        if let image = machine.configuration.removableImages.first(where: { $0.path == disc.path }) {
            return image
        }
        let image = RemovableImage(url: disc, readOnly: true)
        try await machine.attachImage(image)
        return image
    }

    /// Whether there is anything to try an SSH sign-in with.
    private func canSignIn(to machine: VirtualMachine) -> Bool {
        !machine.configuration.ssh.alias.isEmpty && address(for: machine) != nil
    }

    private func requireRunningGuest(_ machine: VirtualMachine) throws {
        guard machine.configuration.canHaveGuestAgent else {
            throw VMError.invalidConfiguration(
                "There are no guest tools for \(machine.configuration.os.family.displayName) guests yet. “\(machine.name)” goes without."
            )
        }
        guard machine.state == .running else { throw VMError.notRunning(name: machine.name) }
    }

    /// Installs the guest tools for a menu command: over SSH where that works, and otherwise by plugging
    /// in the disc and saying what to run in the guest. Either way the outcome is shown wherever the
    /// machine's messages are.
    func installGuestToolsReportingResult(on machine: VirtualMachine) {
        Task {
            let failureTitle = "Couldn't install the guest tools in “\(machine.name)”"
            do {
                if canSignIn(to: machine) {
                    do {
                        try await installGuestTools(on: machine)
                        machine.notice = VMErrorInfo(
                            title: "The guest tools are installed in “\(machine.name)”",
                            message: "SwiftVM now sees the system's version and addresses, keeps its clock right after a suspend, and can sign in over SSH without a network."
                        )
                        return
                    } catch let failure as ProcessRunner.Failure {
                        if let complaint = LinuxGuestAgent.installerComplaint(in: failure) {
                            // The installer ran and gave up. From the disc it would give up the same way.
                            machine.lastError = VMErrorInfo(title: failureTitle, message: Self.sentence(complaint))
                            return
                        }
                        // No way in over SSH. Whoever is at the guest's screen can install from the disc.
                    }
                }
                try await attachGuestToolsDisc(to: machine)
                machine.notice = VMErrorInfo(
                    title: "Install the guest tools in “\(machine.name)”",
                    message: "The guest tools disc is now plugged in. To install from it, run this in a terminal in the virtual machine, and eject the disc afterwards:\n\n\(LinuxGuestAgent.toolsInstallCommand)",
                    copyableText: LinuxGuestAgent.toolsInstallCommand
                )
            } catch {
                machine.lastError = VMErrorInfo(title: failureTitle, message: error.localizedDescription)
            }
        }
    }

    /// What the installer said, as a sentence of its own: with a capital letter and a full stop.
    static func sentence(_ complaint: String) -> String {
        let text = complaint.prefix(1).uppercased() + complaint.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }
}
