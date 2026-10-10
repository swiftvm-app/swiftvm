import SwiftUI
import VMCore

/// One virtual machine in the library list.
struct MachineRow: View {
    let machine: VirtualMachine
    let isSelected: Bool
    /// Starts the machine and brings up its window.
    let onStart: () -> Void
    let menu: MachineMenu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            OSGlyph(os: machine.configuration.os, state: machine.state)

            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(machine.activity.map { $0.label + "…" } ?? Formatting.summary(of: machine))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            primaryButton
                .frame(width: 34, height: 34)

            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions for \(machine.name)")
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .background { RowHighlight(isSelected: isSelected, isHovering: isHovering) }
        .contentShape(.rect(cornerRadius: RowHighlight.cornerRadius))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(machine.name), \(machine.activity?.label ?? machine.state.label)")
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let activity = machine.activity {
            ProgressView()
                .controlSize(.small)
                .help(activity.label)
        } else {
            stateButton
        }
    }

    @ViewBuilder
    private var stateButton: some View {
        switch machine.state {
        case .stopped, .suspended:
            iconButton("play", label: machine.state == .suspended ? "Resume" : "Start", action: onStart)
        case .paused:
            iconButton("play", label: "Resume") { Task { await machine.resume() } }
        case .running:
            iconButton("pause.circle", label: "Suspend") { Task { await machine.suspend() } }
        case .starting, .restoring, .suspending, .stopping:
            ProgressView()
                .controlSize(.small)
                .help(machine.state.label)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "play" ? 19 : 23, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("\(label) \(machine.name)")
    }
}

/// A machine that is still being created, with its progress.
struct CreationRow: View {
    let creation: MachineCreation
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            OSGlyph(os: creation.os)
                .opacity(0.55)

            VStack(alignment: .leading, spacing: 4) {
                Text(creation.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let errorMessage = creation.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                    ProgressView(value: creation.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                }
            }

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 21, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(creation.errorMessage == nil ? "Cancel" : "Dismiss")
            .accessibilityLabel(creation.errorMessage == nil ? "Cancel creating \(creation.name)" : "Dismiss")
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
    }

    private var statusText: String {
        guard let fraction = creation.fraction else { return creation.status }
        return "\(creation.status) \(Int((fraction * 100).rounded()))%"
    }
}

/// The glass capsule behind the selected row, and the faint fill behind a hovered one.
private struct RowHighlight: View {
    static let cornerRadius: CGFloat = 26

    let isSelected: Bool
    let isHovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if isSelected {
            Color.clear.glassEffect(.regular, in: shape)
        } else if isHovering {
            shape.fill(.primary.opacity(0.05))
        }
    }
}
