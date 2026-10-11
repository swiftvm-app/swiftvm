import SwiftUI
import VMControl
import VMCore

/// The app's item in the menu bar, from which the panel with the machines drops down.
///
/// It is the one view that is on the screen for as long as the app runs. So it is also where the rest of
/// the app gets the action that opens windows, and it is the only thing that can say, with no window
/// open, that the app has something to tell: then it turns into a warning sign.
struct MenuBarItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(AppIdentity.current.name, systemImage: model.needsAttention ? "exclamationmark.triangle.fill" : "macwindow.on.rectangle")
            .help("\(AppIdentity.current.name): \(MachineListing.headline(running: model.activeMachines.count, total: model.library.machines.count))")
            .onAppear {
                model.windows.open = openWindow
                model.offerFirstMachine()
            }
    }
}

extension AppModel {
    /// Opens New Virtual Machine when the app starts with no machine to show, once: someone who has
    /// just opened the app for the first time would otherwise see nothing of it but an icon.
    func offerFirstMachine() {
        guard !hasOfferedFirstMachine else { return }
        hasOfferedFirstMachine = true
        if library.machines.isEmpty, creations.isEmpty {
            // macOS doesn't bring an app without a Dock icon forward when it is opened, so the window
            // does. Unless the app was opened to stay behind the others, which macOS doesn't tell it
            // either: `scripts/run-dev.sh --background` does.
            windows.showNewMachine(activatingApp: !CommandLine.arguments.contains("--background"))
        }
    }
}
