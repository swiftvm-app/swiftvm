import SwiftUI
import VMCore

@main
struct SwiftVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    /// The menu bar item is only there while a machine runs; it can't be removed by hand.
    private var hasActiveMachines: Binding<Bool> {
        Binding(get: { !model.activeMachines.isEmpty }, set: { _ in })
    }

    var body: some Scene {
        Window("SwiftVM", id: WindowID.library) {
            LibraryView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 680, height: 600)
        .commands {
            MachineCommands()
        }

        WindowGroup(id: WindowID.machine, for: UUID.self) { $machineID in
            MachineWindow(machineID: machineID)
                .environment(model)
        }
        .defaultSize(width: 1280, height: 832)
        .restorationBehavior(.disabled)

        Settings {
            AppSettingsView()
                .environment(model)
        }

        MenuBarExtra("SwiftVM", systemImage: "macwindow.on.rectangle", isInserted: hasActiveMachines) {
            RunningMachinesMenu()
                .environment(model)
        }
    }
}
