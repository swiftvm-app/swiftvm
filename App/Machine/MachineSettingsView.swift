import SwiftUI
import VMCore

/// Per-machine settings. Hardware changes apply the next time the machine starts; sharing and the network
/// cable apply immediately.
struct MachineSettingsView: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sshAlias = ""
    @State private var sshUser = ""
    @State private var sshPort = ""
    /// What is wrong with the SSH name or port that was typed, while something is.
    @State private var sshProblem: String?
    @State private var isResizingDisk = false
    @State private var isChangingCompression = false

    private var configuration: VMConfiguration { machine.configuration }
    private var isActive: Bool { machine.state != .stopped }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                generalSection
                resourcesSection
                storageSection
                sharingSection
                // A Linux machine with graphics acceleration has no clipboard to share yet.
                if !(configuration.os.family == .linux && configuration.engine == .qemu) {
                    clipboardSection
                }
                automationSection
                networkSection
                if !configuration.networkInterfaces.isEmpty {
                    portForwardingSection
                }
                // A copy that isn't signed for USB devices has none to show, but a machine may have been
                // told elsewhere to take some by itself, and that can be taken back here.
                // QEMU isn't handed USB devices: only the Virtualization framework's machines take them.
                if configuration.engine == .virtualization, model.usb.availability != .notSigned || !configuration.usb.autoConnect.isEmpty {
                    usbSection
                }
                devicesSection
                keyboardSection
                // Secure Boot and Rosetta are Apple's virtualization's. A Linux machine with graphics
                // acceleration runs on QEMU, which has neither.
                if configuration.os.family == .linux, configuration.engine == .virtualization {
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
                    // What can't be saved as it is typed stays on the screen to be put right.
                    if commitTextFields() {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            name = configuration.name
            sshAlias = configuration.ssh.alias
            sshUser = configuration.ssh.user
            sshPort = String(configuration.ssh.port)
        }
        // In a window of their own the settings can be closed without Done. What was typed is kept all
        // the same, as far as it can be.
        .onDisappear { commitTextFields() }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $name)
                .onSubmit { commitTextFields() }
            LabeledContent("System", value: configuration.os.summary)
            LabeledContent("Location") {
                HStack {
                    Button(machine.bundle.url.abbreviatedPath) {
                        model.revealInFinder(machine)
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Show in Finder")
                    if machine.activity == .moving {
                        // To another disk the machine is copied, which takes as long as its disks are full.
                        ProgressView(value: machine.activityProgress)
                            .controlSize(.small)
                            .frame(width: 64)
                            .accessibilityLabel("Moving the virtual machine")
                        Button("Cancel") { model.cancelMove(of: machine) }
                    } else {
                        Button("Move…", action: chooseLocation)
                            .disabled(machine.state != .stopped || machine.activity != nil)
                            .help(machine.state == .stopped
                                ? "Move the virtual machine to another folder or disk"
                                : "Shut down the virtual machine to move it")
                    }
                }
            }
        }
    }

    /// Asks for the folder to move the machine into, and moves it there.
    private func chooseLocation() {
        let current = machine.bundle.url.deletingLastPathComponent()
        guard let folder = FolderPanel.choose(
            message: "Choose the folder to move “\(machine.name)” into. On another disk this copies the virtual machine, which can take a while.",
            prompt: "Move", startingAt: current
        ) else { return }
        model.moveReportingErrors(machine, to: folder)
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
            if configuration.supportsDiskCompression {
                LabeledContent("Compression") {
                    HStack {
                        Text(isDiskCompressed ? "On" : "Off")
                        if machine.activity == .convertingDisk {
                            // All of the disk is written out anew, which takes as long as there is on it.
                            ProgressView(value: machine.activityProgress)
                                .controlSize(.small)
                                .frame(width: 64)
                                .accessibilityLabel("Converting the disk")
                            Button("Cancel") { model.cancelConversion(of: machine) }
                                .accessibilityLabel("Cancel converting the disk")
                        } else {
                            Button(isDiskCompressed ? "Turn Off…" : "Turn On…") { isChangingCompression = true }
                                .accessibilityLabel(isDiskCompressed ? "Turn off compression" : "Turn on compression")
                                .disabled(machine.state != .stopped || machine.activity != nil)
                                .help(machine.state == .stopped
                                    ? (isDiskCompressed ? "Keep the disk as an ordinary disk image again, without compressing it" : "Keep the disk compressed, usually in less than half the space")
                                    : "Shut down the virtual machine to change how its disk is kept")
                                .popover(isPresented: $isChangingCompression, arrowEdge: .bottom) {
                                    CompressDiskView(machine: machine)
                                }
                        }
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

    private var isDiskCompressed: Bool {
        configuration.systemDisk?.format == .compressed
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

    private var clipboardSection: some View {
        Section {
            Toggle("Share Clipboard", isOn: binding(\.clipboard.isShared))
                // Linux guests share it through a device, which like all hardware is there from the start
                // or not at all. macOS and Windows guests share it through their agent.
                .disabled(configuration.os.family == .linux && isActive)
        } header: {
            Text("Clipboard")
        } footer: {
            Text(configuration.os.family == .linux
                ? "Text you copy on this Mac can be pasted in the virtual machine, and the other way round. This needs spice-vdagent in the guest, which most desktop systems bring along."
                : "Text you copy on this Mac can be pasted in the virtual machine, and the other way round. This needs the guest tools in the virtual machine.")
        }
    }

    private var automationSection: some View {
        Section {
            Toggle("Allow Automation", isOn: binding(\.automation.isAllowed))
        } header: {
            Text("Automation")
        } footer: {
            Text(configuration.os.family == .macOS || configuration.engine == .qemu
                ? "The swiftvm command can see the virtual machine's screen and use its mouse and keyboard. With the guest tools in the virtual machine it can also run commands there and copy files."
                : "The swiftvm command can run commands in the virtual machine, copy files, see its screen, and use its mouse and keyboard. This needs the guest tools in the virtual machine.")
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
            TextField("SSH Name", text: $sshAlias)
                .onSubmit { commitTextFields() }
                .help("The name that ssh and swiftvm reach this virtual machine by")
            TextField("SSH User", text: $sshUser, prompt: Text(NSUserName()))
                .onSubmit { commitTextFields() }
            TextField("SSH Port", text: $sshPort, prompt: Text("22"))
                .onSubmit { commitTextFields() }
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
            if let sshProblem {
                Text(sshProblem).foregroundStyle(.red)
            } else if !model.isSSHIncludeInstalled {
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

    private var usbSection: some View {
        Section {
            USBDevicesEditor(machine: machine)
        } header: {
            Text("USB Devices")
        } footer: {
            USBDevicesFootnote()
        }
    }

    private var devicesSection: some View {
        Section("Devices") {
            Toggle("Sound Output", isOn: binding(\.audio.outputEnabled))
            // QEMU's sound card only plays.
            if configuration.engine != .qemu {
                Toggle("Microphone", isOn: binding(\.audio.inputEnabled))
            }
            Toggle("Resize Display with Window", isOn: binding(\.display.automaticallyResizes))
            if !configuration.display.automaticallyResizes {
                // A display that doesn't follow the window has a size of its own.
                Picker("Resolution", selection: resolutionBinding) {
                    ForEach(DisplayResolution.choices(for: configuration)) { resolution in
                        Text(resolution.label(for: configuration)).tag(resolution)
                    }
                }
            }
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

    private var resolutionBinding: Binding<DisplayResolution> {
        Binding(
            get: { DisplayResolution(configuration.display) },
            set: { newValue in
                update {
                    $0.display.widthInPixels = newValue.width
                    $0.display.heightInPixels = newValue.height
                }
            }
        )
    }

    /// Saves what was typed into the text fields.
    ///
    /// - Returns: `false` if something that was typed can't be saved, which the form then says.
    @discardableResult
    private func commitTextFields() -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = sshPort.trimmingCharacters(in: .whitespaces)
        // An empty field is the usual port.
        let port = trimmedPort.isEmpty ? 22 : UInt16(trimmedPort).flatMap { $0 > 0 ? $0 : nil }
        update { configuration in
            if !trimmedName.isEmpty {
                configuration.name = trimmedName
            }
            configuration.ssh.user = trimmedUser
            if let port {
                configuration.ssh.port = port
            }
        }
        name = machine.configuration.name
        sshProblem = nil
        if port == nil {
            sshProblem = "The SSH port is a number from 1 to 65535."
        } else {
            sshPort = String(machine.configuration.ssh.port)
        }
        let typedAlias = sshAlias.trimmingCharacters(in: .whitespaces)
        if typedAlias.isEmpty {
            sshAlias = machine.configuration.ssh.alias
        } else if typedAlias != machine.configuration.ssh.alias {
            // Only a name that was changed here is made to fit: one that came with a machine from
            // elsewhere stays as it is for as long as nobody touches it.
            do {
                sshAlias = try model.setSSHAlias(typedAlias, for: machine)
            } catch {
                sshProblem = error.localizedDescription
            }
        }
        return sshProblem == nil
    }

    private func update(_ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't save the settings", message: error.localizedDescription)
        }
    }
}

/// A size for a guest's display that doesn't follow its window.
struct DisplayResolution: Hashable, Identifiable {
    var width: Int
    var height: Int

    var id: Self { self }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(_ display: DisplayConfiguration) {
        self.init(width: display.widthInPixels, height: display.heightInPixels)
    }

    private static let standard = [
        (1280, 800), (1440, 900), (1680, 1050), (1920, 1080), (1920, 1200), (2560, 1440), (2560, 1600), (3840, 2160),
    ].map { DisplayResolution(width: $0.0, height: $0.1) }

    /// A macOS guest draws at twice the size on a display as dense as its own, so its sizes are larger.
    private static let retina = [
        (2560, 1600), (2880, 1800), (3360, 2100), (3840, 2160), (3840, 2400), (5120, 2880),
    ].map { DisplayResolution(width: $0.0, height: $0.1) }

    /// The sizes on offer for a machine, with the one it has, whatever that is.
    static func choices(for configuration: VMConfiguration) -> [DisplayResolution] {
        let current = DisplayResolution(configuration.display)
        let offered = configuration.os.family == .macOS ? retina : standard
        return offered.contains(current) ? offered : [current] + offered
    }

    /// `1920 × 1200`, and for a macOS guest on a dense display what it looks like: `2560 × 1600 (looks like 1280 × 800)`.
    func label(for configuration: VMConfiguration) -> String {
        let pixels = "\(width) × \(height)"
        guard configuration.os.family == .macOS, configuration.display.pixelsPerInch >= 200 else { return pixels }
        return "\(pixels) (looks like \(width / 2) × \(height / 2))"
    }
}
