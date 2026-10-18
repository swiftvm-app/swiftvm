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
    /// Counts the times the window is to take the size that shows the guest's display pixel for pixel.
    @State private var sharpFits = 0
    /// The last of those the window took. Kept here, as the display's view is made anew whenever the
    /// machine pauses or resumes, and a window the user has resized since stays as it is.
    @State private var appliedSharpFit = AppliedFit()

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
            MachineToolbar(
                machine: machine, isShowingSettings: $isShowingSettings, isShowingSnapshots: $isShowingSnapshots,
                onReturnToSharpSize: { sharpFits += 1 }
            )
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
        // A guest that keeps the size it started at is shown sharp: the window takes that size as it
        // opens, and again once the guest has started at another.
        .onChange(of: machine.displaySize, initial: true) {
            if machine.startsAtDisplaySize, machine.hasStartingDisplaySize {
                sharpFits += 1
            }
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
        case .running where model.isSeamless(machine):
            // Its windows are on the Mac one by one. The whole screen here would ask for a size of
            // its own, and take the guest's windows away from where they are.
            placeholder(
                title: "\(machine.name) is in Seamless Mode",
                detail: "Its windows are on your desktop. Click SwiftVM in the Dock for the Start menu.",
                actionTitle: "Exit Seamless Mode",
                actionImage: "macwindow",
                action: { model.exitSeamlessMode(machine, reopeningWindow: false) }
            )
        case .running, .stopping:
            display
                .overlay(alignment: .bottom) {
                    if let title = machine.setupTitle {
                        setupBanner(title: title, activity: machine.setupActivity)
                    }
                }
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
            MachineDisplayView(
                displayView: displayView,
                // Not the firmware's sizes the display shows on its way to its own.
                sharpFit: machine.startsAtDisplaySize && machine.hasStartingDisplaySize
                    ? machine.displaySize.map { DisplayFit(size: $0, request: sharpFits) } : nil,
                appliedFit: appliedSharpFit
            )
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

    /// What the guest's setup script is doing, at the foot of the display. It runs for minutes, and
    /// what is on the screen meanwhile stays there to be read and used.
    private func setupBanner(title: String, activity: String?) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(title + "…")
                    .font(.headline)
                if let activity, activity != title {
                    Text(activity)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 20)
        .transition(.opacity)
        // What is under it belongs to the guest.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func placeholder(
        title: String, detail: String, actionTitle: String, actionImage: String = "play.fill", action: @escaping () -> Void
    ) -> some View {
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
                Label(actionTitle, systemImage: actionImage)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}

/// A size of the guest's display for the window to show pixel for pixel, asked for anew whenever
/// `request` changes.
struct DisplayFit: Equatable {
    var size: DisplayPixels
    var request: Int
}

/// The last ``DisplayFit`` a machine's window took.
final class AppliedFit {
    var request: Int?
}

/// Hosts the engine's display view (an AppKit view that the engine creates once and keeps).
struct MachineDisplayView: NSViewRepresentable {
    let displayView: NSView
    var sharpFit: DisplayFit?
    var appliedFit = AppliedFit()

    func makeNSView(context: Context) -> DisplayContainerView {
        let container = DisplayContainerView()
        container.appliedFit = appliedFit
        container.embed(displayView)
        container.fit(sharpFit)
        return container
    }

    func updateNSView(_ container: DisplayContainerView, context: Context) {
        container.embed(displayView)
        container.fit(sharpFit)
    }
}

final class DisplayContainerView: NSView {
    private weak var embedded: NSView?
    /// The last fit the window was given, and one still to give it once the view is in a window.
    var appliedFit = AppliedFit()
    private var pendingFit: DisplayFit?

    /// Gives the window the size that shows the display at `fit` pixel for pixel, once per request.
    func fit(_ fit: DisplayFit?) {
        guard let fit, fit.request != appliedFit.request else { return }
        pendingFit = fit
        applyPendingFit()
    }

    private func applyPendingFit() {
        guard let fit = pendingFit, let window, let visible = window.screen?.visibleFrame,
              !window.styleMask.contains(.fullScreen)
        else { return }
        pendingFit = nil
        appliedFit.request = fit.request
        let scale = window.backingScaleFactor
        // What the window has besides the display, which takes the room below its title bar and toolbar.
        // The display's own view may not have been laid out to that yet.
        let extraWidth = window.frame.width - window.contentLayoutRect.width
        let extraHeight = window.frame.height - window.contentLayoutRect.height
        let size = CGSize(width: CGFloat(fit.size.width) / scale + extraWidth, height: CGFloat(fit.size.height) / scale + extraHeight)
        // A display larger than the screen stays scaled; the title bar says how to make it sharp.
        guard size.width <= visible.width, size.height <= visible.height else { return }
        var frame = window.frame
        // Grown or shrunk from its top left corner, and kept on the screen.
        frame.origin.y += frame.height - size.height
        frame.size = size
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        window.setFrame(frame, display: true, animate: true)
    }

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
        // Laid out first, so that what the window has besides the display is known.
        DispatchQueue.main.async { [weak self] in self?.applyPendingFit() }
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
