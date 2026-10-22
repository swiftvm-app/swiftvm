import SwiftUI
import VMControl
import VMCore

/// The panes of a machine's settings.
nonisolated enum MachineSettingsPane: String, SettingsPane {
    case general, hardware, storage, sharing, network, ssh, usb, keyboard, automation, startup

    /// The panes for a machine with this configuration, when the app can take USB devices as `usb` says.
    static func panes(for configuration: VMConfiguration, usb: USBPassthrough.Availability) -> [Self] {
        var panes: [Self] = [.general, .hardware, .storage, .sharing, .network, .ssh]
        // A copy that isn't signed for USB devices has none to show, but a machine may have been
        // told elsewhere to take some by itself, and that can be taken back here.
        // QEMU isn't handed USB devices: only the Virtualization framework's machines take them.
        if configuration.engine == .virtualization, usb != .notSigned || !configuration.usb.autoConnect.isEmpty {
            panes.append(.usb)
        }
        panes += [.keyboard, .automation]
        // Secure Boot and Rosetta are Apple's virtualization's. A Linux machine with graphics
        // acceleration runs on QEMU, which has neither.
        if configuration.os.family == .linux, configuration.engine == .virtualization {
            panes.append(.startup)
        }
        return panes
    }

    var title: String {
        switch self {
        case .general: "General"
        case .hardware: "Hardware"
        case .storage: "Storage"
        case .sharing: "Sharing"
        case .network: "Network"
        case .ssh: "SSH"
        case .usb: "USB Devices"
        case .keyboard: "Keyboard"
        case .automation: "Automation"
        case .startup: "Startup"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .hardware: "cpu.fill"
        case .storage: "internaldrive.fill"
        case .sharing: "folder.fill"
        case .network: "network"
        case .ssh: "apple.terminal.fill"
        case .usb: "cable.connector"
        case .keyboard: "keyboard.fill"
        case .automation: "wand.and.sparkles"
        case .startup: "power"
        }
    }

    var tint: Color {
        switch self {
        case .general, .keyboard: .gray
        case .hardware: .blue
        case .storage: .indigo
        case .sharing: .teal
        case .network: .green
        case .ssh: Color(white: 0.22)
        case .usb: .orange
        case .automation: .purple
        case .startup: .red
        }
    }

    var summary: String {
        switch self {
        case .general: "The name of the virtual machine, its system, and where it is kept."
        case .hardware: "Processors, memory, display and sound."
        case .storage: "The disk, and disc and disk images plugged in as drives."
        case .sharing: "Folders and the clipboard shared with this Mac."
        case .network: "The network connection, and ports forwarded from this Mac."
        case .ssh: "How ssh and swiftvm reach the virtual machine."
        case .usb: "USB devices of this Mac that the virtual machine uses."
        case .keyboard: "Where system shortcuts go while the virtual machine has focus."
        case .automation: "What the swiftvm command may do in the virtual machine."
        case .startup: "How the virtual machine starts its system."
        }
    }
}

/// Per-machine settings. Hardware changes apply the next time the machine starts; sharing and the network
/// cable apply immediately.
struct MachineSettingsView: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = MachineSettingsPane.general
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

    private var panes: [MachineSettingsPane] {
        MachineSettingsPane.panes(for: configuration, usb: model.usb.availability)
    }

    var body: some View {
        SettingsSplitView(panes: panes, selection: $selection) {
            sidebarHeader
        } detail: { pane in
            VStack(spacing: 0) {
                SettingsPage(pane: pane) {
                    content(for: pane)
                }
                Divider()
                bottomBar
            }
        }
        .frame(width: 780, height: 580)
        .onAppear {
            name = configuration.name
            sshAlias = configuration.ssh.alias
            sshUser = configuration.ssh.user
            sshPort = String(configuration.ssh.port)
        }
        // What was typed in a pane is saved when another one is chosen, as its fields are gone then.
        .onChange(of: selection) { commitTextFields() }
        // A pane that is no longer on offer, as USB devices may stop being, gives way to the first one.
        .onChange(of: panes) {
            if !panes.contains(selection) {
                selection = .general
            }
        }
        // In a window of their own the settings can be closed without Done. What was typed is kept all
        // the same, as far as it can be.
        .onDisappear { commitTextFields() }
    }

    /// The machine the settings are for, above the panes.
    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            OSGlyph(os: configuration.os, size: 36, isLit: machine.state.isActive)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(configuration.os.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                    Text(machine.state.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var stateColor: Color {
        switch machine.state {
        case .running: .green
        case .stopped: .secondary.opacity(0.5)
        case .paused, .suspended: .yellow
        case .starting, .restoring, .suspending, .stopping: .orange
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if isActive {
                Label("Changes to hardware apply after the virtual machine is shut down and started again.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Done") {
                // What can't be saved as it is typed stays on the screen to be put right.
                if commitTextFields() {
                    dismiss()
                } else {
                    selection = .ssh
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func content(for pane: MachineSettingsPane) -> some View {
        switch pane {
        case .general:
            generalSection
        case .hardware:
            resourcesSection
            displaySection
            soundSection
        case .storage:
            diskSection
            drivesSection
        case .sharing:
            sharingSection
            clipboardSection
        case .network:
            networkSection
            if !configuration.networkInterfaces.isEmpty {
                portForwardingSection
            }
        case .ssh:
            sshSection
        case .usb:
            usbSection
        case .keyboard:
            keyboardSection
        case .automation:
            automationSection
        case .startup:
            bootSection
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
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

    // MARK: Hardware

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

    private var displaySection: some View {
        Section("Display") {
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

    private var soundSection: some View {
        Section("Sound") {
            Toggle("Sound Output", isOn: binding(\.audio.outputEnabled))
            // QEMU's sound card only plays.
            if configuration.engine != .qemu {
                Toggle("Microphone", isOn: binding(\.audio.inputEnabled))
            }
        }
        .disabled(isActive)
    }

    // MARK: Storage

    private var diskSection: some View {
        Section {
            LabeledContent("Size") {
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
        } header: {
            Text("Disk")
        } footer: {
            Text("The disk only takes up what the guest has written to it.")
        }
    }

    private var drivesSection: some View {
        Section {
            RemovableDrivesEditor(machine: machine)
        } header: {
            Text("Disc and Disk Images")
        } footer: {
            Text("Disc and disk images are plugged in as USB drives and can be changed while the virtual machine runs.")
        }
    }

    private var isDiskCompressed: Bool {
        configuration.systemDisk?.format == .compressed
    }

    // MARK: Sharing

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
                // Linux on Apple's backend shares through a device; the other guests use their agent.
                .disabled(configuration.os.family == .linux && configuration.engine == .virtualization && isActive)
        } header: {
            Text("Clipboard")
        } footer: {
            Text(configuration.os.family == .linux && configuration.engine == .virtualization
                ? "Text you copy on this Mac can be pasted in the virtual machine, and the other way round. This needs spice-vdagent in the guest, which most desktop systems bring along."
                : configuration.os.family == .linux
                    ? "Text you copy on this Mac can be pasted in the virtual machine, and the other way round. This needs the guest tools and wl-clipboard in a Wayland desktop with data-control support, such as Omarchy."
                    : "Text you copy on this Mac can be pasted in the virtual machine, and the other way round. This needs the guest tools in the virtual machine.")
        }
    }

    // MARK: Network

    private var networkSection: some View {
        Section("Connection") {
            if let interface = configuration.networkInterfaces.first {
                Toggle("Connected", isOn: binding(\.networkInterfaces[0].isConnected))
                LabeledContent("IP Address", value: model.address(for: machine) ?? "Assigned when the machine starts")
                LabeledContent("MAC Address", value: interface.macAddress)
                    .textSelection(.enabled)
            } else {
                Text("This virtual machine has no network interface.")
                    .foregroundStyle(.secondary)
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

    // MARK: SSH

    private var sshSection: some View {
        Section {
            TextField("Name", text: $sshAlias)
                .onSubmit { commitTextFields() }
                .help("The name that ssh and swiftvm reach this virtual machine by")
            TextField("User", text: $sshUser, prompt: Text(NSUserName()))
                .onSubmit { commitTextFields() }
            TextField("Port", text: $sshPort, prompt: Text("22"))
                .onSubmit { commitTextFields() }
            if let command = model.sshCommand(for: machine) {
                LabeledContent("Connect") {
                    Text(command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
        } footer: {
            if let sshProblem {
                Text(sshProblem).foregroundStyle(.red)
            } else if !model.isSSHIncludeInstalled {
                Text("Turn on “Add machines to ~/.ssh/config” in the Network pane of \(AppIdentity.current.name) Settings to connect with just “ssh \(configuration.ssh.alias)”.")
            }
        }
    }

    // MARK: USB, keyboard, automation and startup

    private var usbSection: some View {
        Section {
            USBDevicesEditor(machine: machine)
        } footer: {
            USBDevicesFootnote()
        }
    }

    private var keyboardSection: some View {
        Section {
            Toggle("Send System Shortcuts to the Guest", isOn: binding(\.keyboard.capturesSystemKeys))
        } footer: {
            Text("Shortcuts such as Command-Tab and Command-Space go to the guest while its window has focus. Turn this off to keep them for your Mac.")
        }
    }

    private var automationSection: some View {
        Section {
            Toggle("Allow Automation", isOn: binding(\.automation.isAllowed))
        } footer: {
            Text(configuration.os.family == .macOS || configuration.engine == .qemu
                ? "The swiftvm command can see the virtual machine's screen and use its mouse and keyboard. With the guest tools in the virtual machine it can also run commands there and copy files."
                : "The swiftvm command can run commands in the virtual machine, copy files, see its screen, and use its mouse and keyboard. This needs the guest tools in the virtual machine.")
        }
    }

    private var bootSection: some View {
        Section {
            Toggle("Secure Boot", isOn: binding(\.boot.secureBoot))
            Toggle("Rosetta for x86-64 Programs", isOn: binding(\.boot.rosetta))
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
