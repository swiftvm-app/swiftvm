import SwiftUI
import VMCore

/// Shows `content` for the machine a window was opened for, or says that the machine is gone.
struct MachineLookup<Content: View>: View {
    let machineID: UUID?
    @ViewBuilder let content: (VirtualMachine) -> Content

    @Environment(AppModel.self) private var model

    var body: some View {
        if let machineID, let machine = model.library.machine(id: machineID) {
            content(machine)
        } else {
            ContentUnavailableView(
                "Virtual Machine Not Found",
                systemImage: "questionmark.square.dashed",
                description: Text("It may have been deleted or moved.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// A machine's settings in a window of their own, for when they are asked for from the menu bar. In the
/// machine's own window they are a sheet.
struct MachineSettingsWindow: View {
    let machineID: UUID?

    var body: some View {
        MachineLookup(machineID: machineID) { machine in
            MachineSettingsView(machine: machine)
                .navigationTitle("\(machine.name) — Settings")
                // The Virtual Machine menu acts on this machine while its settings are in front.
                .focusedSceneValue(\.machine, machine)
        }
    }
}

/// A machine's snapshots in a window of their own, as its settings are.
struct SnapshotsWindow: View {
    let machineID: UUID?

    var body: some View {
        MachineLookup(machineID: machineID) { machine in
            SnapshotsView(machine: machine)
                .navigationTitle("\(machine.name) — Snapshots")
                .focusedSceneValue(\.machine, machine)
        }
    }
}

/// The window that creates a virtual machine. It also takes files that are dropped on it: an installer
/// disc (ISO) or a macOS restore image (IPSW) to make a machine from, and machines to add to the library.
struct NewMachineWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var request = NewMachineRequest()
    @State private var isDropTargeted = false

    var body: some View {
        // A container that stays while the form inside it is replaced: what is attached to it below
        // happens when the window closes, not when a dropped file starts the form over.
        VStack(spacing: 0) {
            // The machine is ready long after this window has closed, so what happens then is the model's to do.
            NewMachineView(request: request) { [model] machine, startsImmediately in
                if startsImmediately {
                    // Not brought forward: nobody asked for it just now, and an installation takes minutes.
                    model.startShowingWindow(machine, activatingApp: false)
                }
            }
            // A file that is dropped starts the form over with that file chosen.
            .id(request.id)
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(of: urls)
        } isTargeted: { isTargeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = isTargeted }
        }
        // The next time the window opens it starts with the choice of system again.
        .onDisappear { request = NewMachineRequest() }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: 14))
            .padding(8)
            .allowsHitTesting(false)
    }

    private func handleDrop(of urls: [URL]) -> Bool {
        var didAccept = false
        var didAddMachine = false
        for url in urls where url.pathExtension == VMBundle.pathExtension {
            do {
                try model.library.add(VMBundle(url: url))
                didAccept = true
                didAddMachine = true
            } catch {
                model.generalError = VMErrorInfo(title: "Couldn't open “\(url.lastPathComponent)”", message: error.localizedDescription)
            }
        }
        // One form at a time: the first file a machine can be made from.
        if let request = urls.lazy.compactMap(NewMachineRequest.init(droppedFile:)).first {
            self.request = request
            didAccept = true
        } else if didAddMachine {
            // Nothing is left to create: the machines that were dropped are in the menu bar now.
            dismiss()
        }
        return didAccept
    }
}
