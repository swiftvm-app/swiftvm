import SwiftUI
import VMCore

enum WindowID {
    static let machine = "machine"
    static let newMachine = "new-machine"
    static let machineSettings = "machine-settings"
    static let snapshots = "snapshots"
    static let settings = "settings"
}

/// Opens the app's windows, for whatever asks: a row in the menu bar panel, a menu command, the
/// command-line tool, a machine that has just been created.
///
/// SwiftUI only hands the action that opens a window to views. The menu bar item is the one view that is
/// there for as long as the app runs, so it leaves the action here.
final class AppWindows {
    /// Set by the menu bar item once it is on the screen.
    var open: OpenWindowAction? {
        didSet {
            guard open != nil else { return }
            let waiting = self.waiting
            self.waiting = []
            waiting.forEach { $0() }
        }
    }

    /// What ``whenReady(_:)`` was asked to do before windows could be opened.
    private var waiting: [() -> Void] = []

    /// Runs `action` as soon as windows can be opened: now, or in the first moment of a launch, once
    /// the menu bar item is there. For what the app is opened with, a machine from the Finder for one.
    func whenReady(_ action: @escaping () -> Void) {
        if open == nil {
            waiting.append(action)
        } else {
            action()
        }
    }

    /// - Returns: `false` if windows can't be opened yet, which is only so in the first moment of a launch.
    @discardableResult
    func showMachine(_ id: UUID, activatingApp: Bool = true) -> Bool {
        show(activatingApp: activatingApp) { $0(id: WindowID.machine, value: id) }
    }

    func showNewMachine(activatingApp: Bool = true) {
        show(activatingApp: activatingApp) { $0(id: WindowID.newMachine) }
    }

    func showSettings(of machine: VirtualMachine) {
        show(activatingApp: true) { $0(id: WindowID.machineSettings, value: machine.id) }
    }

    func showSnapshots(of machine: VirtualMachine) {
        show(activatingApp: true) { $0(id: WindowID.snapshots, value: machine.id) }
    }

    func showAppSettings() {
        show(activatingApp: true) { $0(id: WindowID.settings) }
    }

    /// Brings the app in front of the others, for something that someone at this Mac has just asked of it.
    ///
    /// Regardless of the app that is in front: an app that isn't in the Dock is not given the front for
    /// asking with `activate()`, not even when it has only just been opened (docs/tech/constraints.md,
    /// "The app").
    func bringAppForward() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// - Parameter activatingApp: Bring the app forward with the window. Not for a window that nobody
    ///   at this Mac asked for just now, which shouldn't land on top of what they are doing.
    @discardableResult
    private func show(activatingApp: Bool, _ window: (OpenWindowAction) -> Void) -> Bool {
        guard let open else { return false }
        DockPresence.shared.windowWillOpen()
        window(open)
        if activatingApp {
            bringAppForward()
        }
        return true
    }
}

extension AppModel {
    /// Starts or resumes a machine with its window open: that is where its display comes up, and where
    /// it says so if it can't start.
    func startShowingWindow(_ machine: VirtualMachine, activatingApp: Bool = true) {
        windows.showMachine(machine.id, activatingApp: activatingApp)
        Task { await machine.start() }
    }
}
