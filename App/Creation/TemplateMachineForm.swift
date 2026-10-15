import SwiftUI
import VMCore

/// What the New Virtual Machine window shows for a machine that is made from a template: which
/// template, and then the form for that one. With no template saved yet, it says how one is made.
struct TemplateSourceForm: View {
    @Binding var source: NewMachineSource
    @Binding var mode: NewMachineMode
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    /// The template that was picked. Until one is, it is the first of the list.
    @State private var templateID: UUID?

    var body: some View {
        Group {
            if let template {
                TemplateMachineForm(template: template, source: $source, mode: $mode, selection: selection(from: template), onReady: onReady)
                    // Another template starts the form over with what that one has.
                    .id(template.id)
            } else {
                VStack(spacing: 0) {
                    Form {
                        Section { NewMachineSourcePicker(selection: $source) }
                    }
                    .formStyle(.grouped)
                    .fixedSize(horizontal: false, vertical: true)

                    ContentUnavailableView(
                        model.templates.isDirectoryMissing ? "Templates Folder Unavailable" : "No Templates Yet",
                        systemImage: "square.stack.3d.up",
                        description: Text(model.templates.isDirectoryMissing
                            ? "The folder for templates, \(model.templates.directory.abbreviatedPath), isn't there. If it is on an external disk, connect the disk."
                            : "Set up a virtual machine, shut it down, and choose Save as Template in its menu. Your saved templates will appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                    FormButtons(problem: nil, canCreate: false, create: {})
                }
            }
        }
        .frame(height: mode.formHeight)
        // One may have been saved, or put in the folder by hand, since the folder was last read.
        .onAppear { model.templates.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.templates.load()
        }
    }

    /// The template that was picked, for as long as it is there, and otherwise the first there is.
    private var template: VMTemplate? {
        let templates = model.templates.templates
        return templates.first { $0.id == templateID } ?? templates.first
    }

    private func selection(from template: VMTemplate) -> Binding<UUID> {
        Binding(get: { template.id }, set: { templateID = $0 })
    }
}

/// The form that makes a virtual machine from one template: in the New Virtual Machine window, and as
/// a sheet in the Templates window.
struct TemplateMachineForm: View {
    let template: VMTemplate
    /// Omitted in the Templates window, where the source has already been chosen.
    var source: Binding<NewMachineSource>?
    var mode: Binding<NewMachineMode>?
    /// Which template it is, where another one can be picked. `nil` in the Templates window.
    var selection: Binding<UUID>?
    /// Called when the new machine is in the library; the flag says whether to start it right away.
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var settings: TemplateMachineSettings
    @State private var sheetMode = NewMachineMode.simple

    init(
        template: VMTemplate, source: Binding<NewMachineSource>? = nil, mode: Binding<NewMachineMode>? = nil, selection: Binding<UUID>? = nil,
        onReady: @escaping (VirtualMachine, Bool) -> Void
    ) {
        self.template = template
        self.source = source
        self.mode = mode
        self.selection = selection
        self.onReady = onReady
        _settings = State(initialValue: TemplateMachineSettings(template: template))
    }

    private var modeBinding: Binding<NewMachineMode> { mode ?? $sheetMode }
    private var effectiveMode: NewMachineMode { modeBinding.wrappedValue }

    var body: some View {
        form
            .onAppear { name = model.nameForMachine(from: template) }
    }

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let source {
                        NewMachineSourcePicker(selection: source)
                    }
                    if let selection {
                        Picker("Template", selection: selection) {
                            ForEach(model.templates.templates) { template in
                                Text(template.name).tag(template.id)
                            }
                        }
                    } else {
                        LabeledContent("Template", value: template.name)
                    }
                    TextField("Name", text: $name)
                } footer: {
                    Text("Makes a virtual machine with everything that was in “\(template.name)” when it was saved, on \(template.createdAt.formatted(date: .abbreviated, time: .omitted)). It gets a name, an address and an SSH name of its own.")
                }

                NewMachineAdvancedToggle(selection: modeBinding, summary: hardwareSummary)
                if effectiveMode == .advanced {
                    Section {
                        Stepper(value: $settings.cpuCount, in: 1...maximumCPUCount) {
                            LabeledContent("Processors", value: "\(settings.cpuCount)")
                        }
                        LabeledContent("Memory") {
                            HStack {
                                Slider(value: $settings.memoryGigabytes, in: 1...maximumMemoryGigabytes, step: 1)
                                    .accessibilityLabel("Memory")
                                    .accessibilityValue("\(Int(settings.memoryGigabytes)) GB")
                                Text("\(Int(settings.memoryGigabytes)) GB")
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                        if template.configuration.systemDisk != nil {
                            DiskSizeRow(gigabytes: $settings.diskGigabytes, range: diskRange)
                        }
                        LocationRow(location: $settings.location)
                    } header: {
                        Text("Hardware")
                    } footer: {
                        if let diskProblem {
                            Text(diskProblem).foregroundStyle(.red)
                        } else if growsDisk {
                            Text("The template's disk is \(templateDiskGigabytes) GB. \(GuestIntegration.diskGrowthNote(for: template.configuration))")
                        }
                    }

                    Section {
                        Toggle("Start when ready", isOn: $settings.startsWhenReady)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            FormButtons(problem: nameProblem ?? diskProblem, canCreate: canCreate, takesDroppedFiles: source != nil, create: create)
        }
        .frame(height: effectiveMode.formHeight)
    }

    private var hardwareSummary: String {
        let memory = Int(settings.memoryGigabytes) == TemplateMachineSettings.memoryGigabytes(of: template)
            ? template.configuration.memorySize : UInt64(settings.memoryGigabytes) * HostResources.gibibyte
        // Avoid converting an invalid typed disk size; validation is shown beside Create.
        return "\(settings.cpuCount) processors · \(Formatting.bytes(memory)) memory · \(settings.diskGigabytes) GB system disk"
    }

    // MARK: Limits

    private var templateDiskGigabytes: Int {
        TemplateMachineSettings.diskGigabytes(of: template)
    }

    // A template may come from a Mac with more of either than this one has. What it has is on offer.

    private var maximumCPUCount: Int {
        max(HostResources.cpuCount, template.configuration.cpuCount)
    }

    private var maximumMemoryGigabytes: Double {
        max(Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), Double(TemplateMachineSettings.memoryGigabytes(of: template)), 2)
    }

    /// A disk can grow, but it can't shrink: the template's size is the least there is.
    private var diskRange: ClosedRange<Int> {
        templateDiskGigabytes...max(templateDiskGigabytes, HostResources.maximumDiskGigabytes)
    }

    private var growsDisk: Bool {
        settings.diskGigabytes > templateDiskGigabytes
    }

    // MARK: Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return nil }
        return model.isNameTaken(trimmedName) ? "That name is already in use." : nil
    }

    private var diskProblem: String? {
        guard template.configuration.systemDisk != nil else { return nil }
        if settings.diskGigabytes < templateDiskGigabytes {
            return "The template's disk is \(templateDiskGigabytes) GB. A disk can grow, but it can't shrink."
        }
        return diskRange.contains(settings.diskGigabytes) ? nil : "A disk can have \(diskRange.upperBound) GB at most."
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && nameProblem == nil && diskProblem == nil
    }

    // MARK: Create

    private func create() {
        guard canCreate else { return }
        let starts = settings.startsWhenReady
        model.create(settings.request(name: trimmedName, template: template),
            onReady: { machine in onReady(machine, starts) })
        dismiss()
    }
}
