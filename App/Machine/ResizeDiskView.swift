import SwiftUI
import VMCore

/// The popover that grows a machine's disk.
struct ResizeDiskView: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gigabytes = 0
    @State private var isWorking = false
    @State private var problem: String?

    private var currentGigabytes: Int {
        Int(((machine.configuration.systemDisk?.capacity ?? 0) + HostResources.gibibyte - 1) / HostResources.gibibyte)
    }

    /// A disk larger than this is more likely a typing mistake than a plan.
    private static let maximumGigabytes = 8192

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize Disk")
                .font(.headline)

            HStack {
                Text("New Size")
                Spacer()
                TextField("New Size", value: $gigabytes, format: .number)
                    .labelsHidden()
                    .accessibilityLabel("New size in gigabytes")
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .onSubmit(resize)
                Text("GB")
                    .foregroundStyle(.secondary)
                Stepper("New Size", value: $gigabytes, in: min(currentGigabytes + 1, Self.maximumGigabytes)...Self.maximumGigabytes, step: 8)
                    .labelsHidden()
            }

            Text(problem ?? note)
                .font(.callout)
                .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Resizing the disk")
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resize", action: resize)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isWorking)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { gigabytes = Self.suggestedSize(after: currentGigabytes) }
    }

    private var isValid: Bool {
        gigabytes > currentGigabytes && gigabytes <= Self.maximumGigabytes
    }

    /// The next of the usual sizes, or double for disks beyond them.
    static func suggestedSize(after current: Int) -> Int {
        [32, 64, 128, 256, 512, 1024, 2048].first { $0 > current } ?? min(current * 2, maximumGigabytes)
    }

    private var note: String {
        let base = "The disk is \(currentGigabytes) GB now. It can grow, but it can't shrink again, and it only takes up space on your Mac as the guest fills it."
        return "\(base) \(GuestIntegration.diskGrowthNote(for: machine.configuration))"
    }

    private func resize() {
        guard isValid, !isWorking else { return }
        isWorking = true
        problem = nil
        let capacity = UInt64(gigabytes) * HostResources.gibibyte
        Task {
            do {
                try await model.resizeDisk(of: machine, to: capacity)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            isWorking = false
        }
    }
}
