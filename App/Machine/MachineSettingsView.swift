import SwiftUI
import VMCore

/// Per-machine settings. Hardware changes apply the next time the machine starts; sharing and the network
/// cable apply immediately.
struct MachineSettingsView: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sshUser = ""
    @State private var isResizingDisk = false

    private var configuration: VMConfiguration { machine.configuration }
    private var isActive: Bool { machine.state != .stopped }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                generalSection
                resourcesSection
                storageSection
                sharingSection
                networkSection
                if !configuration.networkInterfaces.isEmpty {
                    portForwardingSection
                }
                devicesSection
                keyboardSection
                if configuration.os.family == .linux {
                    bootSection
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isActive {
                    Label("Changes to hardware apply after the virtual machine is shut down and started again.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    commitTextFields()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            name = configuration.name
            sshUser = configuration.ssh.user
        }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $name)
                .onSubmit(commitTextFields)
            LabeledContent("System", value: configuration.os.summary)
            LabeledContent("Location") {
                Button((machine.bundle.url.path as NSString).abbreviatingWithTildeInPath) {
                    model.revealInFinder(machine)
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Show in Finder")
            }
        }
    }

    private var resourcesSection: some View {
        Section("Processor and Memory") {
            Stepper(value: binding(\.cpuCount), in: 1...HostResources.cpuCount) {
                LabeledContent("Processors", value: "\(configuration.cpuCount)")
            }
            LabeledContent("Memory") {
                HStack {
                    Slider(value: memoryBinding, in: 1...Double(HostResources.maximumGuestMemorySize / HostResources.gibibyte), step: 1)
                        .accessibilityLabel("Memory")
                        .accessibilityValue(Formatting.bytes(configuration.memorySize))
                    Text(Formatting.bytes(configuration.memorySize))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .disabled(isActive)
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Disk") {
                HStack {
                    Text("\(Formatting.bytes(machine.allocatedDiskSize)) used of \(Formatting.bytes(configuration.totalDiskCapacity))")
                    Button("Resize…") { isResizingDisk = true }
                        .disabled(machine.state != .stopped || machine.activity != nil || configuration.systemDisk == nil)
                        .help(machine.state == .stopped ? "Make the disk larger" : "Shut down the virtual machine to resize its disk")
                        .popover(isPresented: $isResizingDisk, arrowEdge: .bottom) {
                            ResizeDiskView(machine: machine)
                        }
                }
            }
            RemovableDrivesEditor(machine: machine)
        } header: {
            Text("Storage")
        } footer: {
            Text("The disk only takes up what the guest has written to it. Disc and disk images are plugged in as USB drives and can be changed while the virtual machine runs.")
        }
    }

    private var sharingSection: some View {
        Section {
            SharedFoldersEditor(machine: machine)
        } header: {
            Text("Shared Folders")
        } footer: {
            SharedFoldersGuestHint(configuration: configuration, isMountedByAgent: machine.hasAgentMountedSharedFolders)
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section {
            if let interface = configuration.networkInterfaces.first {
                Toggle("Connected", isOn: binding(\.networkInterfaces[0].isConnected))
                LabeledContent("IP Address", value: model.address(for: machine) ?? "Assigned when the machine starts")
                LabeledContent("MAC Address", value: interface.macAddress)
            } else {
                Text("This virtual machine has no network interface.")
                    .foregroundStyle(.secondary)
            }
            TextField("SSH User", text: $sshUser, prompt: Text(NSUserName()))
                .onSubmit(commitTextFields)
            if let command = model.sshCommand(for: machine) {
                LabeledContent("Connect") {
                    Text(command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Network and SSH")
        } footer: {
            if !model.isSSHIncludeInstalled {
                Text("Turn on “Add machines to ~/.ssh/config” in SwiftVM Settings to connect with just “ssh \(configuration.ssh.alias)”.")
            }
        }
    }

    private var portForwardingSection: some View {
        Section {
            PortForwardsEditor(machine: machine)
        } header: {
            Text("Port Forwarding")
        } footer: {
            Text("A forwarded port makes a service in the guest reachable as localhost on this Mac, for example localhost:8080 for a web server on port 80. The guest can always be reached at its own address without forwarding.")
        }
    }

    private var devicesSection: some View {
        Section("Devices") {
            Toggle("Sound Output", isOn: binding(\.audio.outputEnabled))
            Toggle("Microphone", isOn: binding(\.audio.inputEnabled))
            Toggle("Resize Display with Window", isOn: binding(\.display.automaticallyResizes))
        }
        .disabled(isActive)
    }

    private var keyboardSection: some View {
        Section {
            Toggle("Send System Shortcuts to the Guest", isOn: binding(\.keyboard.capturesSystemKeys))
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Shortcuts such as Command-Tab and Command-Space go to the guest while its window has focus. Turn this off to keep them for your Mac.")
        }
    }

    private var bootSection: some View {
        Section {
            Toggle("Secure Boot", isOn: binding(\.boot.secureBoot))
            Toggle("Rosetta for x86-64 Programs", isOn: binding(\.boot.rosetta))
        } header: {
            Text("Startup")
        } footer: {
            Text("Secure Boot only starts systems signed with Microsoft's UEFI keys, which most major distributions are.")
        }
        .disabled(isActive)
    }

    // MARK: Editing

    private var memoryBinding: Binding<Double> {
        Binding(
            get: { Double(configuration.memorySize / HostResources.gibibyte) },
            set: { newValue in update { $0.memorySize = UInt64(newValue) * HostResources.gibibyte } }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VMConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { machine.configuration[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func commitTextFields() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        update { configuration in
            if !trimmedName.isEmpty {
                configuration.name = trimmedName
            }
            configuration.ssh.user = trimmedUser
        }
        name = machine.configuration.name
    }

    private func update(_ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't save the settings", message: error.localizedDescription)
        }
    }
}
