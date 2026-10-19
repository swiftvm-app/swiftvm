import Foundation
import GuestChannel
import Installers
import VMCore

/// Getting the guest tools into a guest.
extension AppModel {
    /// Where the guest tools discs are kept.
    var guestToolsDirectory: URL {
        library.rootDirectory.appending(path: "Guest Tools", directoryHint: .isDirectory)
    }

    /// The guest agent for macOS guests that ships inside the app, if this build has one.
    var macGuestAgentURL: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/swiftvm-agent")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The version of the guest tools this copy of the app brings for `machine`'s kind of guest, as
    /// their agent reports it once it runs. `nil` if it brings none.
    func guestToolsVersion(for machine: VirtualMachine) -> String? {
        switch machine.configuration.os.family {
        case .linux: LinuxGuestAgent.version
        case .macOS: macGuestAgentURL == nil ? nil : MacGuestAgent.version
        case .windows: WindowsGuestAgent.version
        }
    }

    /// What a person runs in `machine`'s guest to install from the guest tools disc.
    func guestToolsInstallCommand(for machine: VirtualMachine) -> String {
        switch machine.configuration.os.family {
        case .macOS: MacGuestAgent.toolsInstallCommand
        case .linux: LinuxGuestAgent.toolsInstallCommand
        case .windows: WindowsGuestAgent.toolsInstallCommand
        }
    }

    /// Current tools can be installed again too: their version alone doesn't say they need no repair.
    func offersGuestTools(for machine: VirtualMachine) -> Bool {
        machine.state == .running && machine.activity == nil && guestToolsVersion(for: machine) != nil
    }

    func isInstallingGuestTools(on machine: VirtualMachine) -> Bool {
        guestToolsInstallation.machineIDs.contains(machine.id)
    }

    func guestToolsActionTitle(for machine: VirtualMachine) -> String {
        if isInstallingGuestTools(on: machine) { return "Installing Guest Tools…" }
        return machine.agent.version == nil ? "Install Guest Tools…" : "Reinstall Guest Tools"
    }

    private func canInstallThroughAgent(on machine: VirtualMachine) -> Bool {
        machine.configuration.automation.isAllowed && machine.agent.isConnected && machine.agent.offers(GuestFeature.exec)
    }

    /// Uses connected tools to replace themselves, or SSH for a guest that has none. The latter takes
    /// key sign-in and root: passwordless sudo on Linux, or the account's password on macOS.
    func installGuestTools(on machine: VirtualMachine, password: String? = nil) async throws {
        try await guestToolsInstallation.perform(for: machine.id, named: machine.name) {
            try await installGuestToolsUnchecked(on: machine, password: password)
        }
    }

    /// The caller holds the installation slot through disc preparation and recovery too.
    private func installGuestToolsUnchecked(on machine: VirtualMachine, password: String? = nil) async throws {
        try requireRunningGuest(machine)
        if canInstallThroughAgent(on: machine), let version = guestToolsVersion(for: machine) {
            let startCount = machine.startCount
            let attached = Set(machine.configuration.removableImages.map(\.id))
            let family = machine.configuration.os.family
            let program = macGuestAgentURL
            let installation = try await Task.detached(priority: .userInitiated) {
                try GuestToolsReinstallation(family: family, macProgram: program)
            }.value
            let disc = family == .macOS ? nil : try await attachGuestToolsDisc(to: machine)
            try await installation.run(
                expectedVersion: version,
                execute: { try await machine.collect($0, input: $1, patience: 20) },
                isRunning: { machine.state == .running && machine.startCount == startCount },
                connectedVersion: { machine.agent.version }
            )
            // Leave discs that were already there alone, and never eject unrelated media attached
            // while the installer ran. Windows keeps its drivers disc for a possible restart.
            if let disc, !attached.contains(disc.id) {
                try? await machine.ejectImage(disc.id)
            }
            return
        }
        guard machine.configuration.os.family != .windows else {
            // Windows has no SSH until the guest tools have set it up. Its own setup installs them.
            throw VMError.invalidConfiguration(
                "The guest tools are installed in Windows from inside it. Use `swiftvm install-tools \(machine.configuration.ssh.alias) --disc`, then \(WindowsGuestAgent.toolsInstallCommand.prefix(1).lowercased() + WindowsGuestAgent.toolsInstallCommand.dropFirst())"
            )
        }
        guard canSignIn(to: machine) else {
            throw VMError.invalidConfiguration(
                "“\(machine.name)” has no SSH name or no address, so the guest tools can't be installed over SSH. To install from inside the guest, use `swiftvm install-tools <machine> --disc`."
            )
        }
        let alias = machine.configuration.ssh.alias
        let configURL = sshWriter.generatedConfigURL
        let isMac = machine.configuration.os.family == .macOS
        let program = macGuestAgentURL
        try await Task.detached(priority: .userInitiated) {
            if isMac {
                guard let program else { throw MacGuestAgent.AgentError.missingProgram }
                try MacGuestAgent.install(on: alias, configURL: configURL, password: password, program: program)
            } else {
                try LinuxGuestAgent.install(on: alias, configURL: configURL)
            }
        }.value

        // The installer has started the agent; the app finds it at its next attempt, a second away at most.
        let version = guestToolsVersion(for: machine)
        let deadline = ContinuousClock.now + .seconds(15)
        while machine.agent.version != version {
            guard machine.state == .running, ContinuousClock.now < deadline else {
                let whereToLook = isMac ? "`sudo launchctl print system/com.swiftvm.agent`" : "`systemctl status swiftvm-agent`"
                throw VMError.invalidConfiguration(
                    "The guest tools were installed in “\(machine.name)”, but the agent hasn't connected. In the guest, \(whereToLook) says why."
                )
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Plugs the guest tools disc into a running guest, for someone to install from inside it with
    /// ``guestToolsInstallCommand(for:)``. Returns the disc, which may have been plugged in already.
    @discardableResult
    func attachGuestToolsDisc(to machine: VirtualMachine) async throws -> RemovableImage {
        try requireRunningGuest(machine)
        let directory = guestToolsDirectory
        // A disc of an earlier version may still be plugged into a machine, or into one of its snapshots,
        // which would not come back without it.
        let attached = Set(library.machines.flatMap { machine in
            ([machine.configuration] + machine.snapshots.map(\.configuration)).flatMap { $0.removableImages.map(\.path) }
        })
        let family = machine.configuration.os.family
        let program = macGuestAgentURL
        let disc = try await Task.detached(priority: .userInitiated) {
            switch family {
            case .macOS:
                guard let program else { throw MacGuestAgent.AgentError.missingProgram }
                return try MacGuestAgent.toolsImage(in: directory, inUse: attached, program: program)
            case .linux:
                return try LinuxGuestAgent.toolsImage(in: directory, inUse: attached)
            case .windows:
                return try WindowsGuestAgent.toolsImage(in: directory, inUse: attached)
            }
        }.value
        // An older disc that is still plugged in has the same label. The guest would find that one
        // under the name the command uses, and install what is on it.
        for image in machine.configuration.removableImages where image.path != disc.path {
            if LinuxGuestAgent.isToolsImage(image.path) || MacGuestAgent.isToolsImage(image.path) || WindowsGuestAgent.isToolsImage(image.path) {
                try await machine.ejectImage(image.id)
            }
        }
        // Windows has no drivers of its own for the machine's devices: they come from a disc of their own.
        if family == .windows {
            let drivers = try await downloader.fetch(WindowsDownloads.drivers) { _ in }
            if !machine.configuration.removableImages.contains(where: { $0.path == drivers.standardizedFileURL.path }) {
                try await machine.attachImage(RemovableImage(url: drivers, readOnly: true))
            }
        }
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
        guard guestToolsVersion(for: machine) != nil else {
            throw VMError.invalidConfiguration(
                "This copy of SwiftVM has no guest tools for \(machine.configuration.os.family.displayName) guests. “\(machine.name)” goes without."
            )
        }
        guard machine.state == .running else { throw VMError.notRunning(name: machine.name) }
    }

    /// Uses the agent, then SSH where that works, and otherwise offers the disc. A running installer
    /// that fails is reported, never followed by a second attempt over another transport.
    func installGuestToolsReportingResult(on machine: VirtualMachine) {
        Task {
            guard !isInstallingGuestTools(on: machine) else { return }
            let failureTitle = "Couldn't install the guest tools in “\(machine.name)”"
            let isMac = machine.configuration.os.family == .macOS
            let isWindows = machine.configuration.os.family == .windows
            let isReinstall = machine.agent.version != nil
            do {
                try await guestToolsInstallation.perform(for: machine.id, named: machine.name) {
                    try requireRunningGuest(machine)
                    machine.lastError = nil
                    machine.notice = nil
                    let throughAgent = canInstallThroughAgent(on: machine)
                    if throughAgent || (canSignIn(to: machine) && !isWindows) {
                        do {
                            try await installGuestToolsUnchecked(on: machine)
                            machine.notice = VMErrorInfo(
                                title: "The guest tools are \(isReinstall ? "reinstalled" : "installed") in “\(machine.name)”",
                                message: isWindows
                                    ? "The guest tools have connected again. Restart Windows to finish applying any driver changes."
                                    : "SwiftVM now sees the system's version and addresses, keeps its clock right after a suspend, and shuts it down through the guest tools."
                            )
                            return
                        } catch let failure as ProcessRunner.Failure {
                            guard !throughAgent else { throw failure }
                            if let complaint = LinuxGuestAgent.installerComplaint(in: failure) {
                                machine.lastError = VMErrorInfo(title: failureTitle, message: Self.sentence(complaint))
                                return
                            }
                            // No way in over SSH, or none to become root there. Whoever is at the guest's
                            // screen can install from the disc.
                        }
                    }
                    try await attachGuestToolsDisc(to: machine)
                    let command = guestToolsInstallCommand(for: machine)
                    if isWindows {
                        machine.notice = VMErrorInfo(
                            title: "Install the guest tools in “\(machine.name)”",
                            message: "The guest tools disc and the drivers for virtual machines are now plugged in. \(command) Restart Windows afterwards, so that its display follows the window."
                        )
                        return
                    }
                    let terminal = isMac ? "in Terminal in the virtual machine" : "in a terminal in the virtual machine"
                    machine.notice = VMErrorInfo(
                        title: "Install the guest tools in “\(machine.name)”",
                        message: "The guest tools disc is now plugged in. To install from it, run this \(terminal), and eject the disc afterwards:\n\n\(command)",
                        copyableText: command
                    )
                }
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
