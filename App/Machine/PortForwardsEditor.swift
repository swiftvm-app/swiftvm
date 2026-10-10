import SwiftUI
import VMCore
import VMNetworking

/// The ports this Mac forwards to a machine, with controls to add and remove them. Changes take effect at
/// once while the machine runs.
struct PortForwardsEditor: View {
    let machine: VirtualMachine

    @Environment(AppModel.self) private var model
    @State private var hostPort = ""
    @State private var guestPort = ""
    @State private var transport = PortForward.TransportProtocol.tcp
    @State private var allowsOtherDevices = false
    @State private var problem: String?

    private var forwards: [PortForward] {
        machine.configuration.networkInterfaces.flatMap(\.portForwards)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(forwards) { forward in
                row(for: forward)
            }

            HStack(spacing: 6) {
                TextField("Port on this Mac", text: $hostPort, prompt: Text("Mac port"))
                    .frame(width: 84)
                    .onSubmit(add)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Port in the guest", text: $guestPort, prompt: Text(hostPortNumber.map(String.init) ?? "Guest port"))
                    .frame(width: 84)
                    .onSubmit(add)
                Picker("Protocol", selection: $transport) {
                    Text("TCP").tag(PortForward.TransportProtocol.tcp)
                    Text("UDP").tag(PortForward.TransportProtocol.udp)
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                Button("Add", action: add)
                    .disabled(hostPortNumber == nil || (!guestPort.isEmpty && guestPortNumber == nil))
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()

            Toggle("Let other devices on the network connect", isOn: $allowsOtherDevices)
                .toggleStyle(.checkbox)
                .font(.callout)

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: hostPort) { problem = nil }
    }

    private func row(for forward: PortForward) -> some View {
        let status = model.portForwarder.statuses[forward.id]
        return HStack(spacing: 10) {
            Circle()
                .fill(color(for: status))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("localhost:\(String(forward.hostPort)) → \(String(forward.guestPort))\(forward.transport == .udp ? " UDP" : "")")
                    .monospacedDigit()
                    // The dot's color and the arrow, in words.
                    .accessibilityLabel("\(forward.transport == .udp ? "UDP port" : "Port") \(String(forward.hostPort)) on this Mac to port \(String(forward.guestPort)) in the guest, \(statusLabel(for: status))")
                Text(detail(for: forward, status: status))
                    .font(.caption)
                    .foregroundStyle(isFailure(status) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Stop forwarding port \(String(forward.hostPort))", systemImage: "minus.circle") { remove(forward) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Stop forwarding")
        }
    }

    private func color(for status: PortRelay.Status?) -> Color {
        switch status {
        case .listening: .green
        case .starting: .yellow
        case .failed: .red
        case nil: .secondary.opacity(0.4)
        }
    }

    private func statusLabel(for status: PortRelay.Status?) -> String {
        switch status {
        case .listening: "Open"
        case .starting: "Opening"
        case .failed: "Not open"
        case nil: "Closed"
        }
    }

    private func isFailure(_ status: PortRelay.Status?) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func detail(for forward: PortForward, status: PortRelay.Status?) -> String {
        if case .failed(let reason) = status {
            return reason
        }
        let scope = forward.allowsOtherDevices ? "Open to this Mac and other devices on the network" : "Open to this Mac only"
        return status == nil ? "\(scope), while the virtual machine runs" : scope
    }

    // MARK: Editing

    private static func port(from text: String) -> UInt16? {
        guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    private var hostPortNumber: UInt16? { Self.port(from: hostPort) }
    private var guestPortNumber: UInt16? { Self.port(from: guestPort) }

    private func add() {
        guard let hostPortNumber else { return }
        guard guestPort.isEmpty || guestPortNumber != nil else { return }
        let forward = PortForward(
            transport: transport, hostPort: hostPortNumber, guestPort: guestPortNumber ?? hostPortNumber,
            allowsOtherDevices: allowsOtherDevices
        )
        do {
            try model.addPortForward(forward, to: machine)
            hostPort = ""
            guestPort = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove(_ forward: PortForward) {
        do {
            try model.removePortForward(forward.id, from: machine)
        } catch {
            problem = error.localizedDescription
        }
    }
}
