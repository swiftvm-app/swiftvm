import SwiftUI
import VMCore

/// The app's menus, which are in the menu bar while one of its windows is open: commands for the machine
/// in the focused window, and the ways to a new machine and to the app's settings.
struct MachineCommands: Commands {
    @FocusedValue(\.machine) private var machine
    @FocusedValue(\.machineActions) private var actions

    /// Nothing can be asked of a machine while its files are being worked on.
    private var state: VMState? {
        machine?.activity == nil ? machine?.state : nil
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if UpdateService.shared.isAvailable {
                Button("Check for Updates…") { UpdateService.shared.checkForUpdates() }
                    .disabled(!UpdateService.shared.canCheckForUpdates)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppModel.shared.windows.showAppSettings() }
                .keyboardShortcut(",")
        }

        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") { AppModel.shared.windows.showNewMachine() }
                .keyboardShortcut("n")
        }

        CommandMenu("Virtual Machine") {
            Button(state == .suspended || state == .paused ? "Resume" : "Start") {
                guard let machine else { return }
                Task {
                    if machine.state == .paused {
                        await machine.resume()
                    } else {
                        await machine.start()
                    }
                }
            }
            .keyboardShortcut("r")
            .disabled(!(state == .stopped || state == .suspended || state == .paused))

            Button("Suspend") {
                guard let machine else { return }
                Task { await machine.suspend() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!(state == .running || state == .paused))

            Button("Pause") {
                guard let machine else { return }
                Task { await machine.pause() }
            }
            .disabled(state != .running)

            Divider()

            Button("Restart") {
                guard let machine else { return }
                Task { await AppModel.shared.shutDown(machine, thenRestart: true) }
            }
            .disabled(state != .running)

            Button("Shut Down") {
                guard let machine else { return }
                Task { await AppModel.shared.shutDown(machine) }
            }
            .disabled(state != .running)

            Button("Force Stop") {
                guard let machine else { return }
                Task { await machine.forceStop() }
            }
            .disabled(state?.isActive != true)

            Divider()

            Button("Take Snapshot") {
                guard let machine else { return }
                AppModel.shared.takeSnapshotReportingErrors(of: machine)
                // Taking one is over in a moment; the list is where it shows up and can be given a name.
                actions?.showSnapshots()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(state == nil || state?.isTransitioning == true)

            Button("Snapshots…") { actions?.showSnapshots() }
                .disabled(machine == nil || actions == nil)

            Button("Duplicate") {
                guard let machine else { return }
                AppModel.shared.duplicateReportingErrors(machine)
            }
            .keyboardShortcut("d")
            .disabled(state != .stopped)

            Button("Settings…") { actions?.showSettings() }
                .disabled(machine == nil || actions == nil)

            Divider()

            Button("Copy SSH Command") {
                guard let machine else { return }
                AppModel.shared.copySSHCommand(for: machine)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(machine.flatMap { AppModel.shared.sshCommand(for: $0) } == nil)

            Button("Open in Terminal") {
                guard let machine else { return }
                AppModel.shared.openTerminal(for: machine)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(machine?.state != .running)

            Button("Open Serial Console") {
                guard let machine else { return }
                AppModel.shared.openSerialConsole(for: machine)
            }
            .disabled(machine?.configuration.hasSerialConsole != true || AppModel.shared.commandLineToolURL == nil)

            Button("Install Guest Tools…") {
                guard let machine else { return }
                AppModel.shared.installGuestToolsReportingResult(on: machine)
            }
            .disabled(machine.map { AppModel.shared.offersGuestTools(for: $0) } != true)
        }
    }
}
