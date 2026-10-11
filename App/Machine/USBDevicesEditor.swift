import SwiftUI
import VMControl
import VMCore

/// What to tell someone who is looking for a USB device that isn't in the list.
enum USBDevicesHint {
    /// macOS decides which app a USB device is used with, and asks the person at the Mac.
    static var howToGiveOne: String {
        "To use a USB device in a virtual machine, plug it in and choose “Use with \(AppIdentity.current.name)” for it in the Virtual Machine Accessories menu, in the menu bar."
    }
}

/// The USB devices this Mac has given the app, each with a switch that hands it to this machine's guest
/// or takes it back, and the devices the machine takes by itself whenever they are there.
struct USBDevicesEditor: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model

    private var usb: USBPassthrough { model.usb }

    /// Devices the machine takes by itself that aren't here right now.
    private var absentRules: [USBConfiguration.DeviceRule] {
        machine.configuration.usb.autoConnect.filter { rule in !usb.devices.contains(where: rule.matches) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch usb.availability {
            case .available:
                if usb.devices.isEmpty {
                    note("No USB devices have been given to \(AppIdentity.current.name).")
                }
                ForEach(usb.devices) { device in
                    row(for: device)
                }
                if machine.state != .running, !usb.devices.isEmpty {
                    note("A device can be attached while the virtual machine is running.")
                }
            case .starting:
                note("Looking for USB devices…")
            case .notSigned, .failed:
                note(USBPassthrough.Failure.unavailable(usb.availability).localizedDescription)
            }

            ForEach(absentRules) { rule in
                HStack(spacing: 10) {
                    Image(systemName: "cable.connector.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Attached whenever it is here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Stop Attaching \(rule.name) by Itself", systemImage: "minus.circle") {
                        update { $0.usb.autoConnect.removeAll { $0.id == rule.id } }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop attaching it by itself")
                }
            }
        }
    }

    private func row(for device: USBDevice) -> some View {
        let holder = usb.holder(of: device.id)
        let isElsewhere = holder != nil && holder?.id != machine.id
        // A guest takes a device while it runs, and can give one back for as long as it has it.
        let canChange = !isElsewhere && (machine.state == .running || holder != nil)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "cable.connector.horizontal")
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(isElsewhere ? "In use by “\(holder?.name ?? "")”" : [device.manufacturer, device.identifier].compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Toggle("Attach \(device.name)", isOn: attachmentBinding(for: device))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!canChange)
                    .help(isElsewhere ? "Detach it from “\(holder?.name ?? "")” first" : "Hand this device to the virtual machine, or give it back to this Mac")
            }
            Toggle("Attach whenever it is plugged in", isOn: automaticBinding(for: device))
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.leading, 30)
                .accessibilityLabel("Attach \(device.name) whenever it is plugged in")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    private func attachmentBinding(for device: USBDevice) -> Binding<Bool> {
        Binding(get: { machine.usbDevices.contains { $0.id == device.id } }, set: { attach in
            Task {
                do {
                    if attach {
                        try await usb.attach(device, to: machine)
                    } else {
                        try await usb.detach(device, from: machine)
                    }
                } catch {
                    machine.lastError = VMErrorInfo(
                        title: "Couldn't \(attach ? "attach" : "detach") “\(device.name)”", message: error.localizedDescription
                    )
                }
            }
        })
    }

    private func automaticBinding(for device: USBDevice) -> Binding<Bool> {
        Binding(get: { machine.configuration.usb.connectsAutomatically(device) }, set: { isOn in
            do {
                try usb.setConnectsAutomatically(isOn, device, to: machine)
            } catch {
                machine.lastError = VMErrorInfo(title: "Couldn't save the setting", message: error.localizedDescription)
            }
        })
    }

    private func update(_ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't save the setting", message: error.localizedDescription)
        }
    }
}

/// The toolbar popover for the USB devices a machine can be handed.
struct USBDevicesPopover: View {
    let machine: VirtualMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("USB Devices")
                .font(.headline)

            USBDevicesEditor(machine: machine)

            USBDevicesFootnote()
        }
        .padding(16)
        .frame(width: 400)
    }
}

/// How devices get here and what attaching one means, under the list.
struct USBDevicesFootnote: View {
    var body: some View {
        Text("\(USBDevicesHint.howToGiveOne) An attached device is gone from this Mac until it is detached. Eject a drive in the guest before detaching it or pulling it out.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
