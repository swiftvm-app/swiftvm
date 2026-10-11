import SwiftUI
import VMCore

/// A machine's own window: the guest display with a toolbar of live controls.
struct MachineWindow: View {
    let machineID: UUID?

    var body: some View {
        MachineLookup(machineID: machineID) { machine in
            MachineView(machine: machine)
        }
    }
}

struct MachineView: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @State private var isShowingSettings = false
    @State private var isShowingSnapshots = false

    var body: some View {
        ZStack {
            Color.black
            if let activity = machine.activity {
                // A snapshot of a running guest suspends and resumes it; show one steady message instead
                // of every step in between.
                display
                progressOverlay(activity.label + "…")
            } else {
                content
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(machine.name)
        .toolbar {
            MachineToolbar(machine: machine, isShowingSettings: $isShowingSettings, isShowingSnapshots: $isShowingSnapshots)
        }
        .windowToolbarFullScreenVisibility(.onHover)
        .focusedSceneValue(\.machine, machine)
        .focusedSceneValue(\.machineActions, MachineActions(
            showSettings: { isShowingSettings = true },
            showSnapshots: { isShowingSnapshots = true }
        ))
        .sheet(isPresented: $isShowingSettings) {
            MachineSettingsView(machine: machine)
        }
        .sheet(isPresented: $isShowingSnapshots) {
            SnapshotsView(machine: machine)
        }
        .alert(
            machine.message?.title ?? "",
            isPresented: Binding(get: { machine.message != nil }, set: { if !$0 { machine.dismissMessage() } }),
            presenting: machine.message
        ) { error in
            MessageButtons(message: error) { machine.dismissMessage() }
        } message: { error in
            Text(error.message)
        }
        .onAppear { model.openMachineWindows.insert(machine.id) }
        .onDisappear { model.openMachineWindows.remove(machine.id) }
    }

    @ViewBuilder
    private var content: some View {
        switch machine.state {
        case .stopped:
            placeholder(
                title: machine.name,
                detail: Formatting.summary(of: machine),
                actionTitle: "Start",
                action: { Task { await machine.start() } }
            )
        case .suspended:
            placeholder(
                title: "\(machine.name) is suspended",
                detail: "Its state is saved on disk and uses no memory.",
                actionTitle: "Resume",
                action: { Task { await machine.start() } }
            )
        case .starting, .restoring:
            display
                .overlay { progressOverlay(machine.state == .restoring ? "Resuming…" : "Starting…") }
        case .running, .stopping:
            display
        case .suspending:
            display
                .overlay { progressOverlay("Suspending…") }
        case .paused:
            display
                .overlay {
                    ZStack {
                        Color.black.opacity(0.45)
                        VStack(spacing: 14) {
                            Text("Paused")
                                .font(.title2.weight(.semibold))
                            Button("Resume") { Task { await machine.resume() } }
                                .buttonStyle(.glassProminent)
                                .controlSize(.large)
                        }
                        .foregroundStyle(.white)
                    }
                }
        }
    }

    @ViewBuilder
    private var display: some View {
        if let displayView = machine.displayView {
            MachineDisplayView(displayView: displayView)
                .accessibilityLabel("Display of \(machine.name)")
        }
    }

    private func progressOverlay(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .transition(.opacity)
        // One announcement, "Starting…", rather than a nameless progress indicator and a text.
        .accessibilityElement(children: .combine)
    }

    private func placeholder(title: String, detail: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 18) {
            OSGlyph(os: machine.configuration.os, size: 74)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            Button(action: action) {
                Label(actionTitle, systemImage: "play.fill")
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}

/// Hosts the engine's display view (an AppKit view that the engine creates once and keeps).
struct MachineDisplayView: NSViewRepresentable {
    let displayView: NSView

    func makeNSView(context: Context) -> DisplayContainerView {
        let container = DisplayContainerView()
        container.embed(displayView)
        return container
    }

    func updateNSView(_ container: DisplayContainerView, context: Context) {
        container.embed(displayView)
    }
}

final class DisplayContainerView: NSView {
    private weak var embedded: NSView?

    func embed(_ view: NSView) {
        guard embedded !== view || view.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        embedded = view
        focusGuest()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusGuest()
    }

    /// Keyboard input should go to the guest as soon as its display is on screen.
    private func focusGuest() {
        guard let embedded, let window else { return }
        window.makeFirstResponder(embedded)
    }
}

/// What the focused window can show for its machine, for menu commands.
struct MachineActions {
    var showSettings: () -> Void
    var showSnapshots: () -> Void
}

extension FocusedValues {
    /// The machine shown in the focused window, for menu commands.
    @Entry var machine: VirtualMachine?
    @Entry var machineActions: MachineActions?
}
