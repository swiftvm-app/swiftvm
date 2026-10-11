import Foundation
import VMCore

/// Something the app has to tell the user with no window open to tell it in: a problem that isn't about
/// one machine, or the error or notice of a machine whose own window isn't open.
///
/// It is shown at the top of the menu bar panel, and the item in the menu bar says that there is
/// something to look at. Not in an alert: one of the app's own would take the keyboard from a guest that
/// someone is typing in, stop every window of the app until it is answered, and stay up after the
/// command-line tool had already reported and cleared what it says.
enum PendingMessage {
    case general(VMErrorInfo)
    case machine(VirtualMachine, VMErrorInfo)

    var info: VMErrorInfo {
        switch self {
        case .general(let info), .machine(_, let info): info
        }
    }

    /// Whether this is something to know rather than something that went wrong.
    var isNotice: Bool {
        switch self {
        case .general: false
        case .machine(let machine, let info): machine.lastError?.id != info.id
        }
    }

    /// What to show: app-wide problems first, then what machines have to say whose own window isn't
    /// open. A machine with its window open says it there.
    static func next(general: VMErrorInfo?, machines: [VirtualMachine], openWindows: Set<UUID>) -> PendingMessage? {
        if let general {
            return .general(general)
        }
        for machine in machines where !openWindows.contains(machine.id) {
            if let message = machine.message {
                return .machine(machine, message)
            }
        }
        return nil
    }

    static func next(in model: AppModel) -> PendingMessage? {
        next(general: model.generalError, machines: model.library.machines, openWindows: model.openMachineWindows)
    }

    /// The user has seen the message. Something newer that has taken its place stays to be seen.
    func dismiss(in model: AppModel) {
        switch self {
        case .general(let info):
            if model.generalError?.id == info.id {
                model.generalError = nil
            }
        case .machine(let machine, let info):
            if machine.message?.id == info.id {
                machine.dismissMessage()
            }
        }
    }
}

extension AppModel {
    /// Whether the item in the menu bar should say that the panel has something to show: a message, or
    /// a machine that couldn't be created. Nothing else of the app is on the screen to say so.
    var needsAttention: Bool {
        PendingMessage.next(in: self) != nil || creations.contains { $0.errorMessage != nil }
    }
}
