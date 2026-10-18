import SwiftUI
import VMCore

/// The title bar's way back to a sharp picture, for a guest whose display takes a new size only as it
/// starts (``VirtualMachine/startsAtDisplaySize``) and whose window has since changed size: the window
/// shows that display scaled until either fits the other again.
struct SharpDisplayButton: View {
    let machine: VirtualMachine
    /// Gives the window the size that shows the guest's display pixel for pixel.
    let onReturnToSharpSize: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isShowingChoices = false

    var body: some View {
        Button("Sharpen Display", systemImage: "sparkles") {
            isShowingChoices.toggle()
        }
        .help("The display isn't sharp at this window size")
        .popover(isPresented: $isShowingChoices, arrowEdge: .bottom) {
            choices
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The display isn't sharp at this size")
                .font(.headline)
            Text("\(machine.configuration.os.productName ?? "The guest") takes a new screen size only when it starts, so this window shows its screen scaled. To make it sharp again, restart it at this window's size, or return the window to the size it was sharp at.")
                .fixedSize(horizontal: false, vertical: true)
            if let shown = machine.displaySize, let wanted = machine.wantedDisplaySize {
                // Pixels, as Windows' own settings show them, without a thousands separator.
                Text(verbatim: "\(shown.width) × \(shown.height) now, \(wanted.width) × \(wanted.height) at this window's size")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Return to Sharp Size") {
                    isShowingChoices = false
                    onReturnToSharpSize()
                }
                Spacer()
                Button("Restart at This Size") {
                    isShowingChoices = false
                    restartAtWindowSize()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text("Restarting closes the apps that are open, as any restart does.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func restartAtWindowSize() {
        do {
            try machine.startAtWantedDisplaySize()
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't save the new screen size", message: error.localizedDescription)
            return
        }
        Task { await model.shutDown(machine, thenRestart: true) }
    }
}
