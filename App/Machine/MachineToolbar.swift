import SwiftUI
import VMCore

/// The glass capsule of controls in a machine window's toolbar.
struct MachineToolbar: ToolbarContent {
    let machine: VirtualMachine
    @Binding var isShowingSettings: Bool
    @Binding var isShowingSnapshots: Bool

    @Environment(AppModel.self) private var model
    @State private var isShowingNetwork = false
    @State private var isShowingFolders = false
    @State private var isShowingDrives = false
    @State private var isShowingUSB = false
    @State private var restartNotice: RestartNotice?

    private enum RestartNotice: Identifiable {
        case audio
        case microphone

        var id: Self { self }
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Power", systemImage: "power") {
                MachineMenu(
                    machine: machine,
                    onStart: { Task { await machine.start() } },
                    onSettings: { isShowingSettings = true },
                    onSnapshots: { isShowingSnapshots = true },
                    onSaveTemplate: { model.saveTemplateReportingErrors(of: machine) }
                )
            }
            .menuIndicator(.hidden)
            .help("Power and actions")

            audioButton
            microphoneButton

            Button("Network", systemImage: isConnected ? "globe" : "network.slash") {
                isShowingNetwork.toggle()
            }
            .help("Network")
            .accessibilityValue(networkStateLabel)
            .popover(isPresented: $isShowingNetwork, arrowEdge: .bottom) {
                NetworkPopover(machine: machine)
            }

            Button("Shared Folders", systemImage: machine.configuration.sharedFolders.isEmpty ? "folder" : "folder.fill") {
                isShowingFolders.toggle()
            }
            .help("Shared folders")
            .accessibilityValue("\(machine.configuration.sharedFolders.count) shared")
            .popover(isPresented: $isShowingFolders, arrowEdge: .bottom) {
                SharedFoldersPopover(machine: machine)
            }

            Button("Disc and Disk Images", systemImage: machine.configuration.removableImages.isEmpty ? "opticaldisc" : "opticaldisc.fill") {
                isShowingDrives.toggle()
            }
            .help("Disc and disk images")
            .accessibilityValue("\(machine.configuration.removableImages.count) attached")
            .popover(isPresented: $isShowingDrives, arrowEdge: .bottom) {
                RemovableDrivesPopover(machine: machine)
            }

            // A copy that isn't signed for USB devices has none to show, ever.
            if model.usb.availability != .notSigned {
                Button("USB Devices", systemImage: "cable.connector.horizontal") {
                    isShowingUSB.toggle()
                }
                .help("USB devices")
                .accessibilityValue("\(machine.usbDevices.count) attached")
                .popover(isPresented: $isShowingUSB, arrowEdge: .bottom) {
                    USBDevicesPopover(machine: machine)
                }
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button("Settings", systemImage: "slider.horizontal.3") {
                isShowingSettings = true
            }
            .help("Virtual machine settings")
        }
    }

    private var isConnected: Bool {
        machine.configuration.networkInterfaces.first?.isConnected ?? false
    }

    private var networkStateLabel: String {
        if machine.configuration.networkInterfaces.isEmpty {
            return "No network interface"
        }
        return isConnected ? "Connected" : "Cable unplugged"
    }

    private var audioButton: some View {
        let isOn = machine.configuration.audio.outputEnabled
        return Button("Sound", systemImage: isOn ? "speaker.wave.2" : "speaker.slash") {
            update { $0.audio.outputEnabled.toggle() }
            if machine.state.isActive {
                restartNotice = .audio
            }
        }
        .help(isOn ? "Sound is on" : "Sound is off")
        .accessibilityValue(isOn ? "On" : "Off")
        .popover(isPresented: noticeBinding(.audio), arrowEdge: .bottom) {
            restartNoticeView("Sound will be \(isOn ? "on" : "off") the next time this virtual machine starts.")
        }
    }

    private var microphoneButton: some View {
        let isOn = machine.configuration.audio.inputEnabled
        return Button("Microphone", systemImage: isOn ? "microphone" : "microphone.slash") {
            update { $0.audio.inputEnabled.toggle() }
            if machine.state.isActive {
                restartNotice = .microphone
            }
        }
        .help(isOn ? "Microphone is on" : "Microphone is off")
        .accessibilityValue(isOn ? "On" : "Off")
        .popover(isPresented: noticeBinding(.microphone), arrowEdge: .bottom) {
            restartNoticeView("The microphone will be \(isOn ? "on" : "off") the next time this virtual machine starts.")
        }
    }

    private func noticeBinding(_ notice: RestartNotice) -> Binding<Bool> {
        Binding(get: { restartNotice == notice }, set: { if !$0 { restartNotice = nil } })
    }

    private func restartNoticeView(_ text: String) -> some View {
        Label(text, systemImage: "arrow.clockwise")
            .font(.callout)
            .padding(14)
            .frame(width: 280, alignment: .leading)
    }

    private func update(_ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't change the setting", message: error.localizedDescription)
        }
    }
}

// MARK: - Network

private struct NetworkPopover: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: connectionBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network")
                        .font(.headline)
                    Text(isConnected ? "Connected to the shared network" : "Cable unplugged")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if let address = model.address(for: machine) {
                    valueRow("IP Address", value: address)
                }
                if let command = model.sshCommand(for: machine) {
                    valueRow("SSH", value: command)
                }
                if let interface = machine.configuration.networkInterfaces.first {
                    valueRow("MAC Address", value: interface.macAddress)
                }
            }

            if model.sshCommand(for: machine) != nil {
                Button("Open in Terminal", systemImage: "apple.terminal") {
                    model.openTerminal(for: machine)
                }
                .disabled(machine.state != .running)
            }

            if !machine.configuration.networkInterfaces.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Port Forwarding")
                        .font(.headline)
                    Text("Reach a port in the guest as localhost on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                PortForwardsEditor(machine: machine)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var isConnected: Bool {
        machine.configuration.networkInterfaces.first?.isConnected ?? false
    }

    private var connectionBinding: Binding<Bool> {
        Binding(get: { isConnected }, set: { connected in
            do {
                try machine.updateConfiguration { configuration in
                    guard !configuration.networkInterfaces.isEmpty else { return }
                    configuration.networkInterfaces[0].isConnected = connected
                }
            } catch {
                machine.lastError = VMErrorInfo(title: "Couldn't change the network connection", message: error.localizedDescription)
            }
        })
    }

    private func valueRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy \(title)", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}

// MARK: - Shared folders

struct SharedFoldersPopover: View {
    let machine: VirtualMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared Folders")
                .font(.headline)

            SharedFoldersEditor(machine: machine)

            SharedFoldersGuestHint(configuration: machine.configuration, isMountedByAgent: machine.hasAgentMountedSharedFolders)
        }
        .padding(16)
        .frame(width: 400)
    }
}

/// Says where shared folders show up in the guest, or how to mount them when the guest doesn't do it itself.
struct SharedFoldersGuestHint: View {
    let configuration: VMConfiguration
    /// The guest tools have mounted the folders in a guest that doesn't do so by itself.
    var isMountedByAgent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch configuration.os.family {
            case .macOS:
                hint("Folders appear in the guest under “My Shared Files” in the Finder sidebar.")
            case .windows:
                hint("Folders appear in the guest as a network drive.")
            case .linux:
                if configuration.mountsSharedFoldersAutomatically || isMountedByAgent {
                    hint("Folders appear in the guest under \(GuestIntegration.sharedFoldersMountPoint). Changes apply right away.")
                } else {
                    hint("This system wasn't set up by SwiftVM, so it doesn't mount shared folders by itself. With the guest tools installed (Install Guest Tools… in the Virtual Machine menu) they are mounted whenever it runs. Without them, run this in the guest's terminal:")
                    CopyableCommand(command: GuestIntegration.linuxMountCommand)
                    hint("Folders then appear under \(GuestIntegration.sharedFoldersMountPoint). To mount them at every start, also run this once (after installing, not in a live session):")
                    CopyableCommand(command: GuestIntegration.linuxPersistentMountCommand)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A shell command the user can select or copy.
struct CopyableCommand: View {
    let command: String

    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(didCopy ? "Copied" : "Copy Command", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// The list of shared folders with add, remove and read-only controls. Edits apply to a running guest.
struct SharedFoldersEditor: View {
    let machine: VirtualMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if machine.configuration.sharedFolders.isEmpty {
                Text("No folders are shared with this virtual machine.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(machine.configuration.sharedFolders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name)
                            .lineLimit(1)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Toggle("Read Only", isOn: readOnlyBinding(for: folder))
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .accessibilityLabel("\(folder.name), Read Only")
                    Button("Stop Sharing \(folder.name)", systemImage: "minus.circle") {
                        update { $0.sharedFolders.removeAll { $0.id == folder.id } }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop sharing")
                }
            }
            Button("Add Folder…", systemImage: "plus") { addFolder() }
        }
    }

    private func readOnlyBinding(for folder: SharedFolder) -> Binding<Bool> {
        Binding(get: { folder.readOnly }, set: { readOnly in
            update { configuration in
                guard let index = configuration.sharedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
                configuration.sharedFolders[index].readOnly = readOnly
            }
        })
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        panel.message = "Choose folders to share with “\(machine.name)”."
        guard panel.runModal() == .OK else { return }
        update { configuration in
            for url in panel.urls where !configuration.sharedFolders.contains(where: { $0.path == url.path }) {
                configuration.sharedFolders.append(SharedFolder(name: url.lastPathComponent, path: url.path))
            }
        }
    }

    private func update(_ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't change shared folders", message: error.localizedDescription)
        }
    }
}
