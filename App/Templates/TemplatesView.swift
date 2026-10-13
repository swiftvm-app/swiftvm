import SwiftUI
import VMCore

/// Lists the templates, makes machines from them, and renames and deletes them. A window of its own,
/// opened from the menu bar panel and the app's menus, and whenever a machine is saved as a template.
struct TemplatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var templateForNewMachine: VMTemplate?
    @State private var templatePendingDeletion: VMTemplate?
    @State private var templateBeingRenamed: VMTemplate?
    @State private var editedName = ""

    private var templates: [VMTemplate] { model.templates.templates }
    /// The machines that are being saved as templates right now. Each is listed until it is one.
    private var machinesBeingSaved: [VirtualMachine] {
        model.library.machines.filter { $0.activity == .savingTemplate }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Templates")
                    .font(.headline)
                Text("A template keeps a virtual machine as it was when you saved it, to make new virtual machines from.")
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
                Menu("Save as Template") {
                    ForEach(model.library.machines) { machine in
                        Button(machine.name) { model.saveTemplateReportingErrors(of: machine) }
                            .disabled(machine.state != .stopped || machine.activity != nil)
                    }
                }
                .fixedSize()
                .disabled(model.library.machines.isEmpty)
                .help("Save a virtual machine that is shut down as a template")
                Spacer(minLength: 12)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 460)
        .sheet(item: $templateForNewMachine) { template in
            TemplateMachineForm(template: template) { [model] machine, startsImmediately in
                if startsImmediately {
                    // As for a machine made in the New Virtual Machine window.
                    model.startShowingWindow(machine, activatingApp: false)
                }
            }
            .frame(width: 520)
        }
        .confirmationDialog(
            "Delete the template “\(templatePendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { templatePendingDeletion != nil }, set: { if !$0 { templatePendingDeletion = nil } }),
            presenting: templatePendingDeletion
        ) { template in
            Button("Move to Trash", role: .destructive) { delete(template) }
        } message: { _ in
            Text("The virtual machines that were made from it aren't changed.")
        }
        .alert(
            "Rename Template",
            isPresented: Binding(get: { templateBeingRenamed != nil }, set: { if !$0 { templateBeingRenamed = nil } }),
            presenting: templateBeingRenamed
        ) { template in
            TextField("Name", text: $editedName)
            Button("Rename") { rename(template) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            model.templateProblem?.title ?? "",
            isPresented: Binding(get: { model.templateProblem != nil }, set: { if !$0 { model.templateProblem = nil } }),
            presenting: model.templateProblem
        ) { _ in
            Button("OK") { model.templateProblem = nil }
        } message: { problem in
            Text(problem.message)
        }
        // One may have been put in the folder by hand, or saved from the command line.
        .onAppear {
            model.isShowingTemplates = true
            model.templates.load()
        }
        .onDisappear {
            model.isShowingTemplates = false
            // What it had to say went with the window.
            model.templateProblem = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.templates.load()
        }
    }

    @ViewBuilder
    private var list: some View {
        if templates.isEmpty, machinesBeingSaved.isEmpty {
            ContentUnavailableView {
                Label("No Templates", systemImage: "square.on.square.dashed")
            } description: {
                Text(model.templates.isDirectoryMissing
                    ? "The folder for templates, \(model.templates.directory.abbreviatedPath), isn't there. If it is on an external disk, connect the disk."
                    : "Set a virtual machine up the way new ones should start out, shut it down, and choose Save as Template in its menu.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(machinesBeingSaved) { machine in
                    savingRow(for: machine)
                }
                ForEach(templates) { template in
                    row(for: template)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(for template: VMTemplate) -> some View {
        HStack(spacing: 12) {
            OSGlyph(os: template.configuration.os, size: 28, isLit: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(Self.details(of: template))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("New Machine…") { templateForNewMachine = template }
                .accessibilityLabel("New machine from \(template.name)")
            Button("Delete \(template.name)", systemImage: "trash") { templatePendingDeletion = template }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .padding(.vertical, 4)
        .help("Saved \(template.createdAt.formatted(date: .abbreviated, time: .shortened))")
        .contextMenu {
            Button("New Machine…") { templateForNewMachine = template }
            Button("Rename…") {
                editedName = template.name
                templateBeingRenamed = template
            }
            Button("Show in Finder") { model.revealInFinder(template) }
            Divider()
            Button("Delete…", role: .destructive) { templatePendingDeletion = template }
        }
    }

    /// A machine whose template isn't there yet. To another disk its disks are copied, which takes a
    /// while and says how far it has come.
    private func savingRow(for machine: VirtualMachine) -> some View {
        HStack(spacing: 12) {
            OSGlyph(os: machine.configuration.os, size: 28, isLit: false)
            VStack(alignment: .leading, spacing: 4) {
                Text("Saving “\(machine.name)”…")
                    .fontWeight(.medium)
                    .lineLimit(1)
                ProgressView(value: machine.activityProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityLabel("Saving \(machine.name) as a template")
            }
            Spacer(minLength: 8)
            Button("Cancel") { model.cancelTemplateSave(of: machine) }
                .accessibilityLabel("Cancel saving \(machine.name) as a template")
        }
        .padding(.vertical, 4)
    }

    /// `4 CPU · 8 GB RAM · 64 GB disk · Ubuntu 26.04 LTS`
    private static func details(of template: VMTemplate) -> String {
        let configuration = template.configuration
        var parts = [Formatting.hardware(of: configuration)]
        if configuration.totalDiskCapacity > 0 {
            parts.append("\(Formatting.bytes(configuration.totalDiskCapacity)) disk")
        }
        parts.append(configuration.os.summary)
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func rename(_ template: VMTemplate) {
        do {
            try model.templates.rename(template, to: editedName)
        } catch {
            model.templateProblem = VMErrorInfo(title: "Couldn't rename “\(template.name)”", message: error.localizedDescription)
        }
    }

    private func delete(_ template: VMTemplate) {
        do {
            try model.templates.remove(template, movingToTrash: true)
        } catch {
            model.templateProblem = VMErrorInfo(title: "Couldn't delete “\(template.name)”", message: error.localizedDescription)
        }
    }
}
