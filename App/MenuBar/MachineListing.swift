import Foundation
import VMCore

/// What the menu bar panel lists, in which order, and what it says about each machine. The views only
/// draw what this works out.
enum MachineListing {
    enum SortOrder: String, CaseIterable, Identifiable {
        case created = "Date Created"
        case name = "Name"

        var id: Self { self }
    }

    /// The machines of the panel's two groups.
    struct Groups {
        /// Machines that hold a guest: running, paused, or on their way to or from that.
        var running: [VirtualMachine] = []
        /// Machines that are shut down or suspended.
        var notRunning: [VirtualMachine] = []

        var isEmpty: Bool { running.isEmpty && notRunning.isEmpty }
        /// From top to bottom, as the panel shows them.
        var all: [VirtualMachine] { running + notRunning }
    }

    /// - Parameters:
    ///   - machines: The library's machines, oldest first.
    ///   - family: Leaves out machines with another kind of guest. `nil` shows them all.
    static func groups(of machines: [VirtualMachine], sortedBy order: SortOrder, showing family: GuestFamily? = nil) -> Groups {
        var shown = machines.filter { family == nil || $0.configuration.os.family == family }
        if order == .name {
            shown.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return Groups(running: shown.filter(\.state.isActive), notRunning: shown.filter { !$0.state.isActive })
    }

    /// The line under a machine's name: what it is busy with, failing that where a running guest is
    /// reached, and for one that isn't running what it is made of.
    ///
    /// - Parameters:
    ///   - address: The address the guest holds, if known.
    ///   - sshCommand: What to type in a terminal to get into the guest, if that is short enough to show.
    static func statusLine(for machine: VirtualMachine, address: String? = nil, sshCommand: String? = nil) -> String {
        if let activity = machine.activity {
            return activity.label + "…"
        }
        let state = machine.state
        let hardware = Formatting.hardware(of: machine.configuration)
        switch state {
        case .starting, .restoring, .suspending, .stopping:
            return state.label + "…"
        case .running:
            let whereabouts = [address, sshCommand].compactMap { $0 }
            return whereabouts.isEmpty ? state.label : whereabouts.joined(separator: " · ")
        case .paused:
            return ([state.label] + [address].compactMap { $0 }).joined(separator: " · ")
        case .suspended:
            return "\(state.label) · \(hardware)"
        case .stopped:
            return "\(hardware) · \(machine.configuration.os.summary)"
        }
    }

    /// The panel's second line and what the menu bar item says of itself: `2 of 5 running`.
    static func headline(running: Int, total: Int) -> String {
        if total == 0 {
            return "No virtual machines"
        }
        if running == 0 {
            return total == 1 ? "1 virtual machine" : "\(total) virtual machines"
        }
        return "\(running) of \(total) running"
    }
}
