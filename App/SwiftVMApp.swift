import SwiftUI
import VMControl
import VMCore

/// The app lives in the menu bar: its item there is always on the screen, and every window is opened
/// from it or for it. None opens when the app starts, unless there is no machine yet.
struct SwiftVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // With a binding, because without one SwiftUI quits the app when the item is dragged out of the
        // menu bar. The model puts the item back instead.
        MenuBarExtra(isInserted: Binding(get: { model.isMenuBarItemInserted }, set: { model.isMenuBarItemInserted = $0 })) {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarItem()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: WindowID.machine, for: UUID.self) { $machineID in
            MachineWindow(machineID: machineID)
                .environment(model)
        }
        .defaultSize(width: 1280, height: 832)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            MachineCommands()
        }

        Window("New Virtual Machine", id: WindowID.newMachine) {
            NewMachineWindow()
                .environment(model)
        }
        .auxiliaryWindow()

        WindowGroup(id: WindowID.machineSettings, for: UUID.self) { $machineID in
            MachineSettingsWindow(machineID: machineID)
                .environment(model)
        }
        .auxiliaryWindow()

        WindowGroup(id: WindowID.snapshots, for: UUID.self) { $machineID in
            SnapshotsWindow(machineID: machineID)
                .environment(model)
        }
        .auxiliaryWindow()

        Window("Templates", id: WindowID.templates) {
            TemplatesView()
                .environment(model)
        }
        .auxiliaryWindow()

        // A window like the others rather than a Settings scene: it is opened from the menu bar panel,
        // by the same means as every other window.
        Window("\(AppIdentity.current.name) Settings", id: WindowID.settings) {
            AppSettingsView()
                .environment(model)
        }
        .auxiliaryWindow()
    }
}

private extension Scene {
    /// A window that is as large as what it shows, is opened when asked for and at no other time, and
    /// adds no menu command of its own: the app's menus and the menu bar panel have theirs.
    func auxiliaryWindow() -> some Scene {
        windowResizability(.contentSize)
            .restorationBehavior(.disabled)
            .defaultLaunchBehavior(.suppressed)
            .commandsRemoved()
    }
}
