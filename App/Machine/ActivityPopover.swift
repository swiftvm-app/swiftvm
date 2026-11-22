import SwiftUI
import VMControl
import VMCore

/// The button that shows what a running machine takes of this Mac, in the window's toolbar and on the
/// machine's row in the menu bar panel. A view of its own, so that a new reading every couple of seconds
/// redraws it alone, not what it is in.
struct ActivityButton: View {
    enum Placement {
        /// In the window's toolbar, with the numbers beside the symbol.
        case toolbar
        /// On the machine's row in the menu bar panel, a symbol like the row's others.
        case panel
    }

    let machine: VirtualMachine
    let placement: Placement

    @State private var isShowingActivity = false

    var body: some View {
        button
            .help("CPU and memory use")
            .accessibilityValue(machine.usage.map(Formatting.usage) ?? "Measuring")
            .popover(isPresented: $isShowingActivity, arrowEdge: .bottom) {
                ActivityPopover(machine: machine)
            }
    }

    @ViewBuilder
    private var button: some View {
        switch placement {
        case .toolbar:
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol)
                    Text(machine.usage.map(Formatting.compactUsage) ?? "–")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(machine.usage == nil ? .secondary : .primary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 4)
            }
            .accessibilityLabel("Activity")
        case .panel:
            Button("Activity", systemImage: Self.symbol, action: toggle)
                .panelSymbolButton()
                .accessibilityLabel("Activity of \(machine.name)")
        }
    }

    private func toggle() {
        isShowingActivity.toggle()
    }

    static let symbol = "waveform.path.ecg"
}

/// What the machine takes of this Mac's processor and memory, as it changes.
private struct ActivityPopover: View {
    let machine: VirtualMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .font(.headline)
                Text("What this virtual machine takes of this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let usage = machine.usage {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    meterRow(
                        "CPU", value: MachineUsage.percent(usage.cpuPercent),
                        detail: "\(configuration.cpuCount) virtual CPU\(configuration.cpuCount == 1 ? "" : "s")",
                        // A guest can keep each of its processors busy, and no more.
                        fraction: usage.cpuPercent / Double(max(configuration.cpuCount, 1) * 100)
                    )
                    meterRow(
                        "Memory", value: Formatting.bytes(usage.memoryBytes),
                        detail: "of \(Formatting.bytes(configuration.memorySize))",
                        fraction: Double(usage.memoryBytes) / Double(max(configuration.memorySize, 1))
                    )
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Measuring…")
                        .foregroundStyle(.secondary)
                }
            }

            Text("100% CPU is one of this Mac's \(HostResources.cpuCount) cores. Memory counts what the guest has used so far, and what the virtual machine needs to run it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var configuration: VMConfiguration { machine.configuration }

    private func meterRow(_ title: String, value: String, detail: String, fraction: Double) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.body.monospacedDigit())
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: fraction.isFinite ? min(max(fraction, 0), 1) : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
