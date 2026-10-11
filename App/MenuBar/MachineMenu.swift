import SwiftUI
import VMCore

/// The actions available for a machine, used by its row in the menu bar panel (the “…” menu and the
/// context menu) and by the window toolbar.
struct MachineMenu: View {
    let machine: VirtualMachine
    /// Starts the machine and shows its window.
    let onStart: () -> Void
    /// Shows the machine's window; `nil` hides the item (already in that window).
    var onOpen: (() -> Void)?
    let onSettings: () -> Void
    let onSnapshots: () -> Void
    /// `nil` hides the item.
    var onDelete: (() -> Void)?

    @Environment(AppModel.self) private var model

    var body: some View {
        lifecycleItems

        Divider()
        if let onOpen {
            Button("Open Window", systemImage: "macwindow", action: onOpen)
        }
        Button("Settings…", systemImage: "slider.horizontal.3", action: onSettings)
        Button("Snapshots…", systemImage: "clock.arrow.circlepath", action: onSnapshots)
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateReportingErrors(machine) }
            .disabled(machine.state != .stopped || machine.activity != nil)

        Divider()
        Button("Copy SSH Command", systemImage: "terminal") { model.copySSHCommand(for: machine) }
            .disabled(model.sshCommand(for: machine) == nil)
        Button("Open in Terminal", systemImage: "apple.terminal") { model.openTerminal(for: machine) }
            .disabled(model.sshCommand(for: machine) == nil || machine.state != .running)
        if machine.configuration.hasSerialConsole, model.commandLineToolURL != nil {
            Button("Open Serial Console", systemImage: "cable.connector") { model.openSerialConsole(for: machine) }
        }
        if model.offersGuestTools(for: machine) {
            Button("Install Guest Tools…", systemImage: "shippingbox") { model.installGuestToolsReportingResult(on: machine) }
        }
        Button("Copy IP Address", systemImage: "network") {
            guard let address = model.address(for: machine) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
        .disabled(model.address(for: machine) == nil)

        Divider()
        Button("Show in Finder", systemImage: "folder") { model.revealInFinder(machine) }
        if let onDelete {
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(machine.state.isActive || machine.activity != nil)
        }
    }

    @ViewBuilder
    private var lifecycleItems: some View {
        if let activity = machine.activity {
            Button(activity.label + "…") {}
                .disabled(true)
        } else {
            stateItems
        }
    }

    @ViewBuilder
    private var stateItems: some View {
        switch machine.state {
        case .stopped:
            Button("Start", systemImage: "play", action: onStart)
            if machine.configuration.os.family == .macOS {
                Button("Start in Recovery", systemImage: "wrench.and.screwdriver") {
                    onOpen?()
                    Task { await machine.start(inRecovery: true) }
                }
            }
        case .suspended:
            Button("Resume", systemImage: "play", action: onStart)
            Button("Discard Saved State", systemImage: "arrow.counterclockwise") { machine.discardSavedState() }
        case .running:
            Button("Suspend", systemImage: "pause.circle") { Task { await machine.suspend() } }
            Button("Pause", systemImage: "pause") { Task { await machine.pause() } }
            // A guest that asks for confirmation on its screen has its window brought forward, also
            // when the request came from the menu bar.
            Button("Restart", systemImage: "arrow.clockwise") {
                Task { await model.shutDown(machine, thenRestart: true, activatingApp: true) }
            }
            Button("Shut Down", systemImage: "power") {
                Task { await model.shutDown(machine, activatingApp: true) }
            }
            Button("Force Stop", systemImage: "xmark.octagon", role: .destructive) { Task { await machine.forceStop() } }
        case .paused:
            Button("Resume", systemImage: "play") { Task { await machine.resume() } }
            Button("Suspend", systemImage: "pause.circle") { Task { await machine.suspend() } }
            Button("Force Stop", systemImage: "xmark.octagon", role: .destructive) { Task { await machine.forceStop() } }
        case .stopping:
            // A guest that ignores the shutdown request can still be stopped.
            Button("Force Stop", systemImage: "xmark.octagon", role: .destructive) { Task { await machine.forceStop() } }
        case .starting, .restoring, .suspending:
            Button(machine.state.label + "…") {}
                .disabled(true)
        }
    }
}

/// The buttons under a message about a machine: OK, and for a message that asks the user to run a command
/// somewhere else, a way to take the command along.
struct MessageButtons: View {
    let message: VMErrorInfo
    let dismiss: () -> Void

    var body: some View {
        if let command = message.copyableText {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                dismiss()
            }
        }
        Button("OK", action: dismiss)
    }
}
