import AppKit
import VMCore

extension AppModel {
    func isSeamless(_ machine: VirtualMachine) -> Bool {
        seamlessMachineIDs.contains(machine.id)
    }

    /// Whether Seamless Mode is something to offer for a machine at all: a Windows guest on QEMU.
    func offersSeamlessMode(for machine: VirtualMachine) -> Bool {
        machine.configuration.engine == .qemu && machine.configuration.os.family == .windows
    }

    /// The machine whose Start menu the app's Dock icon opens: the one in Seamless Mode used last.
    var seamlessMachineForDock: VirtualMachine? {
        seamlessMachineIDs.last.flatMap { library.machine(id: $0) }
    }

    /// Shows the guest's windows one by one on the Mac, instead of its whole screen in the machine's
    /// window, which closes.
    func enterSeamlessMode(_ machine: VirtualMachine) {
        guard !isSeamless(machine) else { return }
        guard machine.canShowGuestWindows else {
            machine.lastError = VMErrorInfo(
                title: "“\(machine.name)” can't enter Seamless Mode",
                message: "Seamless Mode needs a running Windows guest with the latest guest tools. Choose Install Guest Tools… to update them."
            )
            return
        }
        // A display library from before Seamless Mode draws the whole screen only.
        guard let probe = machine.makeRegionView() else {
            machine.lastError = VMErrorInfo(
                title: "“\(machine.name)” can't enter Seamless Mode",
                message: "This copy of SwiftVM's display can't show the guest's windows one by one."
            )
            return
        }
        probe.close()
        let session = SeamlessSession(machine: machine)
        session.onEnd = { [weak self, weak machine] problem in
            guard let self, let machine else { return }
            exitSeamlessMode(machine, reopeningWindow: problem != nil)
            if let problem {
                machine.lastError = VMErrorInfo(title: "“\(machine.name)” left Seamless Mode", message: problem)
            }
        }
        session.onUse = { [weak self] in self?.markSeamlessUse(of: machine.id) }
        // The machine's window shows the whole screen, and would ask for its own size of it.
        machine.displayView?.window?.close()
        seamlessSessions[machine.id] = session
        markSeamlessUse(of: machine.id)
        // The Dock icon is the way to the Start menu.
        DockPresence.shared.windowWillOpen()
        windows.bringAppForward()
        session.start()
    }

    /// Shows the guest's whole screen in the machine's window again.
    func exitSeamlessMode(_ machine: VirtualMachine, reopeningWindow: Bool = true) {
        guard let session = seamlessSessions.removeValue(forKey: machine.id) else { return }
        seamlessMachineIDs.removeAll { $0 == machine.id }
        session.stop()
        if reopeningWindow, machine.state.isActive {
            windows.showMachine(machine.id)
        }
        DockPresence.shared.refresh()
    }

    /// Opens the Start menu of a machine in Seamless Mode.
    func showStartMenu(of machine: VirtualMachine) {
        guard let session = seamlessSessions[machine.id] else { return }
        markSeamlessUse(of: machine.id)
        windows.bringAppForward()
        session.showStartMenu()
    }

    private func markSeamlessUse(of id: UUID) {
        guard seamlessMachineIDs.last != id else { return }
        seamlessMachineIDs.removeAll { $0 == id }
        seamlessMachineIDs.append(id)
    }
}
