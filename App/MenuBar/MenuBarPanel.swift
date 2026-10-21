import SwiftUI
import VMControl
import VMCore

/// What drops down from the app's menu bar item: every virtual machine with its state and its actions,
/// the machines that are still being created, and the way to everything else in the app.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @AppStorage("menuBar.sortOrder") private var sortOrder = MachineListing.SortOrder.created
    @State private var familyFilter: GuestFamily?
    /// The machine whose row asks whether to delete it.
    @State private var machinePendingDeletion: UUID?
    /// The row the arrow keys are on.
    @State private var highlight: UUID?
    @FocusState private var isFocused: Bool

    private static let width: CGFloat = 360
    /// Beyond this the list scrolls, so that the panel stays on the screen with any number of machines.
    private static let maximumListHeight: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = PendingMessage.next(in: model) {
                PanelMessageCard(message: message)
            }
            if let version = UpdateService.shared.waitingVersion {
                PanelUpdateCard(version: version) {
                    UpdateService.shared.checkForUpdates()
                    dismiss()
                }
                .disabled(!UpdateService.shared.canCheckForUpdates)
            }
            if model.library.machines.isEmpty, model.library.unavailableMachines.isEmpty, model.creations.isEmpty {
                emptyState
            } else {
                PanelScrollArea(maximumHeight: Self.maximumListHeight, scrollTarget: highlight) {
                    list
                }
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.return) { openHighlighted() }
        .onKeyPress(.escape) { cancelDeletion() }
        .onAppear { isFocused = true }
        .onDisappear {
            highlight = nil
            machinePendingDeletion = nil
        }
    }

    private var groups: MachineListing.Groups {
        MachineListing.groups(of: model.library.machines, sortedBy: sortOrder, showing: familyFilter)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppIdentity.current.name)
                    .font(.headline)
                Text(MachineListing.headline(running: model.activeMachines.count, total: model.library.machines.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button("New Virtual Machine", systemImage: "plus", action: showNewMachine)
                .panelSymbolButton()
                .keyboardShortcut("n")
                .help("Create a virtual machine")

            Menu {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(MachineListing.SortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)

                Picker("Show", selection: $familyFilter) {
                    Text("All Systems").tag(GuestFamily?.none)
                    ForEach(GuestFamily.allCases, id: \.self) { family in
                        Text(family.displayName).tag(GuestFamily?.some(family))
                    }
                }
                .pickerStyle(.inline)

                Divider()
                Button("Templates…") {
                    model.windows.showTemplates()
                    dismiss()
                }
                Divider()
                Button("Delete All Virtual Machines…", role: .destructive, action: confirmDeletingAll)
                    .disabled(model.library.removableMachines.isEmpty)
                Divider()
                if UpdateService.shared.isAvailable {
                    Button("Check for Updates…") {
                        UpdateService.shared.checkForUpdates()
                        dismiss()
                    }
                    .disabled(!UpdateService.shared.canCheckForUpdates)
                }
                Button("About \(AppIdentity.current.name)") {
                    model.windows.bringAppForward()
                    NSApp.orderFrontStandardAboutPanel(nil)
                    dismiss()
                }
            } label: {
                Label("Sort, Filter and More", systemImage: "ellipsis")
                    .labelStyle(PanelSymbolLabelStyle())
            }
            .panelSymbolMenu()
            .help("Sort, filter and more")
            .accessibilityLabel("Sort, filter and more")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                model.windows.showAppSettings()
                dismiss()
            }
            .keyboardShortcut(",")
            Spacer()
            Button("Quit \(AppIdentity.current.name)") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(PanelTextButtonStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: Machines

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !groups.running.isEmpty {
                sectionTitle("Running")
                ForEach(groups.running) { row(for: $0) }
            }
            if !groups.notRunning.isEmpty || !model.creations.isEmpty {
                sectionTitle("Not Running")
                ForEach(groups.notRunning) { row(for: $0) }
                ForEach(model.creations) { creation in
                    CreationPanelRow(creation: creation) { model.dismiss(creation) }
                }
            }
            if !model.library.unavailableMachines.isEmpty {
                // Whatever the filter: nothing is known of their system while they can't be read.
                sectionTitle("Not Available")
                ForEach(model.library.unavailableMachines) { machine in
                    UnavailablePanelRow(machine: machine)
                }
            }
            if groups.isEmpty, model.creations.isEmpty, !model.library.machines.isEmpty {
                noMatch
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Virtual Machines")
    }

    private func row(for machine: VirtualMachine) -> some View {
        MachinePanelRow(
            machine: machine,
            isHighlighted: highlight == machine.id,
            isAskingToDelete: Binding(
                get: { machinePendingDeletion == machine.id },
                set: { machinePendingDeletion = $0 ? machine.id : nil }
            )
        )
        .id(machine.id)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("No Virtual Machines")
                    .font(.headline)
                Text("Create a virtual machine to run macOS, Linux or Windows on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("New Virtual Machine…", action: showNewMachine)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }

    /// Every machine is of a kind the filter leaves out.
    private var noMatch: some View {
        VStack(spacing: 8) {
            Text("No virtual machine matches the filter.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show All Systems") { familyFilter = nil }
                .controlSize(.small)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func showNewMachine() {
        model.windows.showNewMachine()
        dismiss()
    }

    /// Asks in a dialog of its own, not in the panel: the question is about every machine, not one row.
    /// Machines that are running or being worked on can't be deleted, so they aren't offered.
    private func confirmDeletingAll() {
        dismiss()
        // Once the panel is gone, which a dialog that waits for an answer would otherwise hold up.
        Task { @MainActor in
            let machines = model.library.removableMachines
            guard !machines.isEmpty else { return }
            let permanently = model.deletesMachinesPermanently
            let alert = NSAlert()
            alert.alertStyle = .warning
            let others = model.library.machines.count - machines.count
            alert.messageText = machines.count == 1
                ? "Delete “\(machines[0].name)”?"
                : others > 0 ? "Delete \(machines.count) virtual machines?" : "Delete all \(machines.count) virtual machines?"
            alert.informativeText = permanently
                ? "Their disks and snapshots are deleted immediately. This can't be undone."
                : "They are moved to the Trash with their disks and snapshots."
            if others > 0 {
                alert.informativeText += others == 1
                    ? " One virtual machine that is running or busy stays as it is."
                    : " \(others) virtual machines that are running or busy stay as they are."
            }
            let delete = alert.addButton(withTitle: permanently ? "Delete" : "Move to Trash")
            delete.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            // Return doesn't delete everything by accident. Escape still cancels.
            delete.keyEquivalent = ""
            model.windows.bringAppForward()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model.delete(machines)
        }
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        let list = groups.all
        guard !list.isEmpty else { return .ignored }
        guard let highlight, let index = list.firstIndex(where: { $0.id == highlight }) else {
            self.highlight = (offset > 0 ? list.first : list.last)?.id
            return .handled
        }
        self.highlight = list[min(max(index + offset, 0), list.count - 1)].id
        return .handled
    }

    /// Escape takes the question back that a row is asking. With none asked it is the panel's to handle.
    private func cancelDeletion() -> KeyPress.Result {
        guard machinePendingDeletion != nil else { return .ignored }
        machinePendingDeletion = nil
        return .handled
    }

    private func openHighlighted() -> KeyPress.Result {
        // Return answers nothing while a row asks whether to delete: neither is the safe choice by default.
        guard machinePendingDeletion == nil else { return .handled }
        guard let machine = groups.all.first(where: { $0.id == highlight }) else { return .ignored }
        model.windows.showMachine(machine.id)
        dismiss()
        return .handled
    }
}

/// Something the app has to say, at the top of the panel: see ``PendingMessage``.
struct PanelMessageCard: View {
    let message: PendingMessage

    @Environment(AppModel.self) private var model

    var body: some View {
        let info = message.info
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: message.isNotice ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(message.isNotice ? AnyShapeStyle(.tint) : AnyShapeStyle(.yellow))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(info.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                if let command = info.copyableText {
                    // The message asks for a command to be run somewhere else. Taking it along is all
                    // there is left to do with the message.
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        message.dismiss(in: model)
                    }
                }
                Button("OK") { message.dismiss(in: model) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.06), in: PanelMetrics.rowShape)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}

/// An update of the app that was found while nobody was looking, at the top of the panel: see
/// ``UpdateService/waitingVersion``.
struct PanelUpdateCard: View {
    let version: String
    let show: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("\(AppIdentity.current.name) \(version) is available.")
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Update…", action: show)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.06), in: PanelMetrics.rowShape)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}

/// Holds the panel's list: as tall as the list is, up to a height beyond which it scrolls.
///
/// The height doesn't give way, on purpose. The menu bar makes a panel as small as its content allows,
/// and whatever can shrink, as a scroll view by itself can, is then left with no room at all.
struct PanelScrollArea<Target: Hashable, Content: View>: View {
    let maximumHeight: CGFloat
    /// The row to bring into view when it changes: the one the arrow keys are on.
    var scrollTarget: Target?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: scrollTarget) { _, newValue in
                if let newValue {
                    proxy.scrollTo(newValue)
                }
            }
        }
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A text button at the foot of the panel: bare, and lit up under the pointer like a menu item.
private struct PanelTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration)
    }

    /// A view of its own, because only a view can keep track of the pointer.
    private struct Appearance: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    if isHovering || configuration.isPressed {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
                    }
                }
                .contentShape(.rect(cornerRadius: 7))
                .onHover { isHovering = $0 }
        }
    }
}
