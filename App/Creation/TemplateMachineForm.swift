import SwiftUI
import VMCore

/// What the New Virtual Machine window shows for a machine that is made from a template: which
/// template, and then the form for that one. With no template saved yet, it says how one is made.
struct TemplateSourceForm: View {
    @Binding var source: NewMachineSource
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    /// The template that was picked. Until one is, it is the first of the list.
    @State private var templateID: UUID?

    var body: some View {
        Group {
            if let template {
                TemplateMachineForm(template: template, source: $source, selection: selection(from: template), onReady: onReady)
                    // Another template starts the form over with what that one has.
                    .id(template.id)
            } else {
                VStack(spacing: 0) {
                    Form {
                        Section {
                            NewMachineSourcePicker(selection: $source)
                        } footer: {
                            Text(model.templates.isDirectoryMissing
                                ? "The folder for templates, \(model.templates.directory.abbreviatedPath), isn't there. If it is on an external disk, connect the disk."
                                : "There are no templates yet. Set a virtual machine up the way new ones should start out, shut it down, and choose Save as Template in its menu. It is then here to create machines from.")
                        }
                    }
                    .formStyle(.grouped)
                    .scrollBounceBehavior(.basedOnSize)
                    .fixedSize(horizontal: false, vertical: true)

                    Divider()
                    FormButtons(problem: nil, canCreate: false, create: {})
                }
            }
        }
        // One may have been saved, or put in the folder by hand, since the folder was last read.
        .onAppear { model.templates.load() }
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
    /// What the machine is made from, where something else can be picked instead. `nil` in the Templates
    /// window, where the template was picked from the list.
    var source: Binding<NewMachineSource>?
    /// Which template it is, where another one can be picked. `nil` in the Templates window.
    var selection: Binding<UUID>?
    /// Called when the new machine is in the library; the flag says whether to start it right away.
    let onReady: (VirtualMachine, Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cpuCount: Int
    @State private var memoryGigabytes: Double
    @State private var diskGigabytes: Int
    @State private var startsWhenReady = true
    /// The folder to keep the machine in, if one was chosen.
    @State private var location: URL?

    init(
        template: VMTemplate, source: Binding<NewMachineSource>? = nil, selection: Binding<UUID>? = nil,
        onReady: @escaping (VirtualMachine, Bool) -> Void
    ) {
        self.template = template
        self.source = source
        self.selection = selection
        self.onReady = onReady
        _cpuCount = State(initialValue: template.configuration.cpuCount)
        _memoryGigabytes = State(initialValue: Double(Self.memoryGigabytes(of: template)))
        _diskGigabytes = State(initialValue: Self.diskGigabytes(of: template))
    }

    var body: some View {
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

                Section {
                    Stepper(value: $cpuCount, in: 1...maximumCPUCount) {
                        LabeledContent("Processors", value: "\(cpuCount)")
                    }
                    LabeledContent("Memory") {
                        HStack {
                            Slider(value: $memoryGigabytes, in: 1...maximumMemoryGigabytes, step: 1)
                                .accessibilityLabel("Memory")
                                .accessibilityValue("\(Int(memoryGigabytes)) GB")
                            Text("\(Int(memoryGigabytes)) GB")
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    if template.configuration.systemDisk != nil {
                        DiskSizeRow(gigabytes: $diskGigabytes, range: diskRange)
                    }
                    LocationRow(location: $location)
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
                    Toggle("Start when ready", isOn: $startsWhenReady)
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            // As tall as its rows: the form has the same ones for every template.
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            FormButtons(problem: nameProblem, canCreate: canCreate, takesDroppedFiles: source != nil, create: create)
        }
        .onAppear { name = model.nameForMachine(from: template) }
    }

    // MARK: Limits

    /// The template's memory in whole gigabytes, which is what the slider counts in.
    private static func memoryGigabytes(of template: VMTemplate) -> Int {
        max(Int(template.configuration.memorySize / HostResources.gibibyte), 1)
    }

    private static func diskGigabytes(of template: VMTemplate) -> Int {
        Int(((template.configuration.systemDisk?.capacity ?? 0) + HostResources.gibibyte - 1) / HostResources.gibibyte)
    }

    private var templateDiskGigabytes: Int {
        Self.diskGigabytes(of: template)
    }

    // A template may come from a Mac with more of either than this one has. What it has is on offer.

    private var maximumCPUCount: Int {
        max(HostResources.cpuCount, template.configuration.cpuCount)
    }

    private var maximumMemoryGigabytes: Double {
        max(Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), Double(Self.memoryGigabytes(of: template)), 2)
    }

    /// A disk can grow, but it can't shrink: the template's size is the least there is.
    private var diskRange: ClosedRange<Int> {
        templateDiskGigabytes...max(templateDiskGigabytes, HostResources.maximumDiskGigabytes)
    }

    private var growsDisk: Bool {
        diskGigabytes > templateDiskGigabytes
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
        if diskGigabytes < templateDiskGigabytes {
            return "The template's disk is \(templateDiskGigabytes) GB. A disk can grow, but it can't shrink."
        }
        return diskRange.contains(diskGigabytes) ? nil : "A disk can have \(diskRange.upperBound) GB at most."
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && nameProblem == nil && diskProblem == nil
    }

    // MARK: Create

    private func create() {
        let starts = startsWhenReady
        model.create(TemplateCreateRequest(
            name: trimmedName,
            template: template,
            cpuCount: cpuCount,
            // Memory that wasn't touched stays what the template has, to the byte.
            memorySize: Int(memoryGigabytes) == Self.memoryGigabytes(of: template)
                ? nil : UInt64(memoryGigabytes) * HostResources.gibibyte,
            diskCapacity: growsDisk ? UInt64(diskGigabytes) * HostResources.gibibyte : nil,
            location: location
        ), onReady: { machine in onReady(machine, starts) })
        dismiss()
    }
}
