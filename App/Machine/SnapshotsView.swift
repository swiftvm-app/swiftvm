import SwiftUI
import VMCore

/// Lists a machine's snapshots and takes, restores and deletes them: a sheet in the machine's window, a
/// window of its own when it is opened from the menu bar.
struct SnapshotsView: View {
    let machine: VirtualMachine

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var snapshotPendingRevert: VMSnapshot?
    @State private var snapshotPendingDeletion: VMSnapshot?
    @State private var snapshotBeingRenamed: VMSnapshot?
    @State private var editedName = ""
    @State private var problem: VMErrorInfo?
    /// A snapshot is being taken or gone back to from this sheet. It stays open until that is over, so
    /// that a failure has somewhere to be shown.
    @State private var isWorking = false

    /// Newest first: the one you are most likely to go back to is the one you just took.
    private var snapshots: [VMSnapshot] { machine.snapshots.reversed() }
    private var isBusy: Bool { machine.activity != nil || machine.state.isTransitioning }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Snapshots of “\(machine.name)”")
                    .font(.headline)
                Text("A snapshot keeps this virtual machine exactly as it is, so you can come back to it later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()
            list
            Divider()

            HStack(spacing: 10) {
                TextField("Name", text: $newName, prompt: Text(VMSnapshot.defaultName(avoiding: machine.snapshots)))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(takeSnapshot)
                    .accessibilityLabel("Name of the new snapshot")
                Button("Take Snapshot", action: takeSnapshot)
                    .disabled(isBusy)
                Spacer(minLength: 12)
                if let activity = machine.activity {
                    ProgressView()
                        .controlSize(.small)
                        .help(activity.label)
                        .accessibilityLabel(activity.label)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
            .padding(16)
        }
        .frame(width: 540, height: 460)
        .interactiveDismissDisabled(isWorking)
        // The same for the window this is in when it was opened from the menu bar.
        .windowDismissBehavior(isWorking ? .disabled : .automatic)
        .confirmationDialog(
            "Go back to “\(snapshotPendingRevert?.name ?? "")”?",
            isPresented: Binding(get: { snapshotPendingRevert != nil }, set: { if !$0 { snapshotPendingRevert = nil } }),
            presenting: snapshotPendingRevert
        ) { snapshot in
            Button("Revert", role: .destructive) { revert(to: snapshot) }
        } message: { snapshot in
            Text("Everything that has happened in “\(machine.name)” since \(Self.dateText(snapshot.createdAt)) is lost. Take a snapshot first if you want to keep it.")
        }
        .confirmationDialog(
            "Delete the snapshot “\(snapshotPendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { snapshotPendingDeletion != nil }, set: { if !$0 { snapshotPendingDeletion = nil } }),
            presenting: snapshotPendingDeletion
        ) { snapshot in
            Button("Delete", role: .destructive) { delete(snapshot) }
        } message: { _ in
            Text("The virtual machine itself isn't changed. You can't undo this.")
        }
        .alert(
            "Rename Snapshot",
            isPresented: Binding(get: { snapshotBeingRenamed != nil }, set: { if !$0 { snapshotBeingRenamed = nil } }),
            presenting: snapshotBeingRenamed
        ) { snapshot in
            TextField("Name", text: $editedName)
            Button("Rename") { rename(snapshot) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            problem?.title ?? "",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }),
            presenting: problem
        ) { _ in
            Button("OK") { problem = nil }
        } message: { problem in
            Text(problem.message)
        }
    }

    @ViewBuilder
    private var list: some View {
        if snapshots.isEmpty {
            ContentUnavailableView {
                Label("No Snapshots", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(machine.state.isActive
                    ? "Take one before you try something risky. The virtual machine pauses for a moment while it is taken."
                    : "Take one before you try something risky.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List(snapshots) { snapshot in
                HStack(spacing: 12) {
                    Image(systemName: snapshot.includesMemory ? "play.circle" : "power.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text("\(Self.dateText(snapshot.createdAt)) · \(snapshot.includesMemory ? "Resumes where it was" : "Starts up from shut down")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Revert…") { snapshotPendingRevert = snapshot }
                        .accessibilityLabel("Revert to \(snapshot.name)")
                    Button("Delete \(snapshot.name)", systemImage: "trash") { snapshotPendingDeletion = snapshot }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
                .padding(.vertical, 4)
                .disabled(isBusy)
                .contextMenu {
                    Group {
                        Button("Rename…") {
                            editedName = snapshot.name
                            snapshotBeingRenamed = snapshot
                        }
                        Button("Revert…") { snapshotPendingRevert = snapshot }
                        Divider()
                        Button("Delete…", role: .destructive) { snapshotPendingDeletion = snapshot }
                    }
                    .disabled(isBusy)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Actions

    private func takeSnapshot() {
        guard !isBusy else { return }
        let name = newName
        newName = ""
        isWorking = true
        Task {
            do {
                try await machine.takeSnapshot(named: name)
            } catch {
                problem = VMErrorInfo(title: "Couldn't take the snapshot", message: error.localizedDescription)
            }
            isWorking = false
        }
    }

    private func revert(to snapshot: VMSnapshot) {
        // Someone who goes back while the guest is running wants to carry on from there, not find it off.
        let wasActive = machine.state.isActive
        isWorking = true
        Task {
            do {
                try await machine.revert(to: snapshot)
                if wasActive {
                    await machine.start()
                }
            } catch {
                problem = VMErrorInfo(title: "Couldn't go back to “\(snapshot.name)”", message: error.localizedDescription)
            }
            isWorking = false
        }
    }

    private func rename(_ snapshot: VMSnapshot) {
        do {
            try machine.renameSnapshot(snapshot, to: editedName)
        } catch {
            problem = VMErrorInfo(title: "Couldn't rename “\(snapshot.name)”", message: error.localizedDescription)
        }
    }

    private func delete(_ snapshot: VMSnapshot) {
        do {
            try machine.deleteSnapshot(snapshot)
        } catch {
            problem = VMErrorInfo(title: "Couldn't delete “\(snapshot.name)”", message: error.localizedDescription)
        }
    }
}
