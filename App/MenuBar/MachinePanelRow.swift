import SwiftUI
import VMCore

/// One virtual machine in the menu bar panel.
struct MachinePanelRow: View {
    let machine: VirtualMachine
    /// The arrow keys are on this row.
    let isHighlighted: Bool
    /// The row asks whether to delete its machine instead of showing it.
    @Binding var isAskingToDelete: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isHovering = false

    var body: some View {
        if isAskingToDelete {
            deletionQuestion
        } else {
            summary
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            MachineBadge(os: machine.configuration.os, state: machine.state)

            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                primaryControl
                if machine.state.isActive {
                    Button("Open Window", systemImage: "macwindow", action: open)
                        .panelSymbolButton()
                        .help("Open window")
                        .accessibilityLabel("Open the window of \(machine.name)")
                }
                Menu {
                    menu
                } label: {
                    Label("More Actions", systemImage: "ellipsis")
                        .labelStyle(PanelSymbolLabelStyle())
                }
                .panelSymbolMenu()
                .help("More actions")
                .accessibilityLabel("More actions for \(machine.name)")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background {
            if isHovering || isHighlighted {
                PanelMetrics.rowShape.fill(.primary.opacity(0.08))
            }
        }
        .contentShape(PanelMetrics.rowShape)
        .onHover { isHovering = $0 }
        // The pointer isn't said to have left a row that goes away under it: when the panel closes, or
        // when the row turns into the question whether to delete.
        .onDisappear { isHovering = false }
        .onTapGesture(perform: open)
        .contextMenu { menu }
        .help(Formatting.summary(of: machine))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(machine.name), \(machine.activity?.label ?? machine.state.label)")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        // What a click on the row does, for someone who doesn't use the pointer.
        .accessibilityAction(named: "Open Window", open)
    }

    private var statusLine: String {
        MachineListing.statusLine(
            for: machine,
            address: model.address(for: machine),
            // Without the Include line the command names a file, which is too long to read here.
            sshCommand: model.isSSHIncludeInstalled ? model.sshCommand(for: machine) : nil
        )
    }

    private var menu: MachineMenu {
        MachineMenu(
            machine: machine,
            onStart: start,
            onOpen: open,
            onSettings: {
                model.windows.showSettings(of: machine)
                dismiss()
            },
            onSnapshots: {
                model.windows.showSnapshots(of: machine)
                dismiss()
            },
            onDelete: { isAskingToDelete = true }
        )
    }

    @ViewBuilder
    private var primaryControl: some View {
        if let activity = machine.activity {
            progress(activity.label)
        } else {
            switch machine.state {
            case .stopped, .suspended:
                symbolButton("play", label: machine.state == .suspended ? "Resume" : "Start", action: start)
            case .paused:
                symbolButton("play", label: "Resume") { Task { await machine.resume() } }
            case .running:
                symbolButton("pause.circle", label: "Suspend") { Task { await machine.suspend() } }
            case .starting, .restoring, .suspending, .stopping:
                progress(machine.state.label)
            }
        }
    }

    private func symbolButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .panelSymbolButton()
            .help(label)
            .accessibilityLabel("\(label) \(machine.name)")
    }

    private func progress(_ label: String) -> some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize)
            .help(label)
            .accessibilityLabel(label)
    }

    // MARK: Deleting

    /// Asked in the row itself: the panel goes away as soon as something else is in front, so a dialog
    /// would have nothing to hang on to.
    private var deletionQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete “\(machine.name)”?")
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text("The virtual machine and its disks are moved to the Trash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isAskingToDelete = false }
                Button("Move to Trash", role: .destructive) {
                    isAskingToDelete = false
                    model.delete(machine)
                }
                // It may have been started from somewhere else while the question was on the screen.
                .disabled(machine.state.isActive || machine.activity != nil)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.06), in: PanelMetrics.rowShape)
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

    private func open() {
        model.windows.showMachine(machine.id)
        dismiss()
    }

    private func start() {
        model.startShowingWindow(machine)
        dismiss()
    }
}

/// A machine that is still being created, with its progress.
struct CreationPanelRow: View {
    let creation: MachineCreation
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MachineBadge(os: creation.os)

            VStack(alignment: .leading, spacing: 3) {
                Text(creation.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let errorMessage = creation.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                    ProgressView(value: creation.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel(creation.status)
                }
            }

            Spacer(minLength: 8)

            Button(creation.errorMessage == nil ? "Cancel" : "Dismiss", systemImage: "xmark", action: onDismiss)
                .panelSymbolButton()
                .help(creation.errorMessage == nil ? "Cancel" : "Dismiss")
                .accessibilityLabel(creation.errorMessage == nil ? "Cancel creating \(creation.name)" : "Dismiss")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(creation.name), \(creation.errorMessage == nil ? "being created" : "couldn't be created")")
    }

    private var statusText: String {
        guard let fraction = creation.fraction else { return creation.status }
        return "\(creation.status) \(Int((fraction * 100).rounded()))%"
    }
}

/// A machine's tile in the panel, which says at a glance whether the machine is on: in the system's
/// colour while it holds a guest, without colour while it is suspended or shut down.
struct MachineBadge: View {
    let os: GuestOS
    /// `nil` for a machine that is still being created.
    var state: VMState?

    @State private var isDimmed = false

    var body: some View {
        OSGlyph(os: os, size: 30, isLit: state?.isActive ?? false)
            .opacity(isPulsing && isDimmed ? 0.45 : 1)
            .onAppear { animateIfNeeded() }
            .onChange(of: isPulsing) { animateIfNeeded() }
    }

    /// On its way from one state to the next.
    private var isPulsing: Bool {
        state?.isTransitioning ?? false
    }

    private func animateIfNeeded() {
        if isPulsing {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { isDimmed = true }
        } else {
            withAnimation(.default) { isDimmed = false }
        }
    }
}

// MARK: - Controls

enum PanelMetrics {
    /// The side of a symbol button's square.
    static let controlSize: CGFloat = 26
    static let rowShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
}

/// The label of a symbol button in the panel: the symbol alone, in an area large enough to hit.
struct PanelSymbolLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.system(size: 13, weight: .medium))
            .frame(width: PanelMetrics.controlSize, height: PanelMetrics.controlSize)
            .contentShape(.circle)
    }
}

/// The faint disc behind a symbol button while the pointer is over it.
private struct PanelControlHighlight: ViewModifier {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            // Quiet next to the machine's name until the pointer is over it.
            .foregroundStyle(isHovering && isEnabled ? .primary : .secondary)
            .background {
                if isHovering, isEnabled {
                    Circle().fill(.primary.opacity(0.1))
                }
            }
            .onHover { isHovering = $0 }
            .onDisappear { isHovering = false }
    }
}

extension View {
    /// Styles a button with a title and a symbol as one of the panel's symbol buttons.
    func panelSymbolButton() -> some View {
        labelStyle(PanelSymbolLabelStyle())
            .buttonStyle(.plain)
            .modifier(PanelControlHighlight())
    }

    /// The same for a menu, whose label has to bring ``PanelSymbolLabelStyle`` itself.
    func panelSymbolMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(PanelControlHighlight())
    }
}
