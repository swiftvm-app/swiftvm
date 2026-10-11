import SwiftUI
import VMControl
import VMCore

/// The menu bar item shown while machines run. They keep running when every window is closed, and this is
/// where they stay within reach.
struct RunningMachinesMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.activeMachines) { machine in
            Menu("\(machine.name) (\(machine.state.label))") {
                Button("Show Window", systemImage: "macwindow") {
                    NSApp.activate()
                    openWindow(id: WindowID.machine, value: machine.id)
                }
                Divider()
                switch machine.state {
                case .running:
                    Button("Suspend", systemImage: "pause.circle") { Task { await machine.suspend() } }
                    Button("Shut Down", systemImage: "power") {
                        // A guest that asks for confirmation on its screen has the app brought forward.
                        Task { await model.shutDown(machine, activatingApp: true) }
                    }
                case .paused:
                    Button("Resume", systemImage: "play") { Task { await machine.resume() } }
                    Button("Suspend", systemImage: "pause.circle") { Task { await machine.suspend() } }
                default:
                    EmptyView()
                }
                Button("Force Stop", systemImage: "xmark.octagon", role: .destructive) { Task { await machine.forceStop() } }
            }
        }

        Divider()
        Button("Show All Virtual Machines") {
            NSApp.activate()
            openWindow(id: WindowID.library)
        }
        Button("Quit \(AppIdentity.current.name)") { NSApp.terminate(nil) }
    }
}
