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
            // Nothing else happens when the app opens: no window comes up that nobody asked for.
            .onAppear { model.windows.open = openWindow }
    }
}
