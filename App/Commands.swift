import SwiftUI
import VMCore

/// Menu bar commands for the machine in the focused window.
struct MachineCommands: Commands {
    @FocusedValue(\.machine) private var machine

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") {
                NSApp.activate()
                NotificationCenter.default.post(name: .newMachineRequested, object: nil)
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Virtual Machine") {
            Button(machine?.state == .suspended || machine?.state == .paused ? "Resume" : "Start") {
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
            .disabled(!(machine?.state == .stopped || machine?.state == .suspended || machine?.state == .paused))

            Button("Suspend") {
                guard let machine else { return }
                Task { await machine.suspend() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!(machine?.state == .running || machine?.state == .paused))

            Button("Pause") {
                guard let machine else { return }
                Task { await machine.pause() }
            }
            .disabled(machine?.state != .running)

            Divider()

            Button("Restart") {
                guard let machine else { return }
                Task { await machine.restart() }
            }
            .disabled(machine?.state != .running)

            Button("Shut Down") {
                guard let machine else { return }
                Task { await machine.shutDown() }
            }
            .disabled(machine?.state != .running)

            Button("Force Stop") {
                guard let machine else { return }
                Task { await machine.forceStop() }
            }
            .disabled(machine?.state.isActive != true)

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
        }
    }
}
