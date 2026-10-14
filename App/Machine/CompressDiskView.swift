import SwiftUI
import VMCore

/// The popover that says what keeping a machine's disk compressed means, before the disk is converted.
struct CompressDiskView: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Set by the first click, so that a second one before the popover is gone starts nothing.
    @State private var hasBegun = false

    private var isCompressed: Bool {
        machine.configuration.systemDisk?.format == .compressed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCompressed ? "Turn Off Compression" : "Compress Disk")
                .font(.headline)

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCompressed ? "Turn Off" : "Compress", action: convert)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var note: String {
        let used = Formatting.bytes(machine.allocatedDiskSize)
        if isCompressed {
            return """
                The disk is written out anew as it was before it was compressed. That takes a while, and \
                needs room for all of it next to the \(used) it takes up now, until it is done.
                """
        }
        return """
            The disk takes up \(used) now, and compressed usually less than half of that: files that \
            are compressed already, such as video and archives, stay as large as they are. It is written \
            out anew, which takes a while and needs room for the new disk next to the old one until it is done.

            Reading stays as fast or gets faster. Writing gets slower, which a machine that writes a lot \
            will notice.

            If your Mac crashes or loses power while the machine runs, what the guest wrote in its last \
            second can be lost. The disk itself comes back whole.

            \(earlierCopiesNote)
            """
    }

    /// A snapshot, a template or a copy shares its space with the disk as it is now. Once the disk is
    /// written out anew they hold that space alone, so compressing wins nothing until they are gone.
    private var earlierCopiesNote: String {
        machine.snapshots.isEmpty
            ? "If templates or copies were made from this machine, they keep the disk as it is now, and space is only won once they are deleted."
            : "Its snapshots stay as they are, and so do templates and copies made from it. They keep the disk as it is now, so space is only won once they are deleted."
    }

    private func convert() {
        guard !hasBegun else { return }
        hasBegun = true
        // The settings show how far it has come and can call it off, so nothing waits here.
        model.setDiskCompressionReportingErrors(of: machine, enabled: !isCompressed)
        dismiss()
    }
}
