import Foundation
import Observation

/// Hands the USB devices that this Mac has given the app to its guests: when asked to, and by itself for
/// a device that a machine is set to take whenever both are there.
///
/// A device is with one guest at a time, and only with a guest that is running. Which devices there are
/// is for the host to say (``deviceDidConnect(_:)``, ``deviceDidDisconnect(_:)``); which guest has one
/// is what the machines say themselves (``VirtualMachine/usbDevices``).
///
/// A device that a guest lets go of comes back to this Mac as a new device a moment later: reported
/// gone, then there again under another number. Much of what follows is about telling that from a
/// device that someone has plugged in.
@MainActor
@Observable
public final class USBPassthrough {
    /// Whether this copy of the app can take USB devices at all.
    public enum Availability: Sendable, Hashable {
        /// Not known yet: macOS has been asked and hasn't answered.
        case starting
        case available
        /// The app isn't signed for it, as a copy that was built without a provisioning profile isn't.
        case notSigned
        /// macOS wouldn't let the app at USB devices, for the reason it gave.
        case failed(String)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable(Availability)
        case gone(device: String)
        case inUse(device: String, by: String)
        case onItsWay(device: String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(.failed(let reason)):
                "macOS doesn't let this app use USB devices: \(reason)"
            case .unavailable(.starting):
                "The app is still finding out which USB devices it has. Try again in a moment."
            case .unavailable:
                "This copy of the app can't use USB devices: it was built without the provisioning profile that macOS wants for them."
            case .gone(let device):
                "“\(device)” isn't with this app any more. It was pulled out, or given back to this Mac."
            case .inUse(let device, let machine):
                "“\(device)” is in use by “\(machine)”. Detach it there first."
            case .onItsWay(let device):
                "“\(device)” is being attached right now."
            }
        }
    }

    public var availability: Availability = .starting
    /// The devices this Mac has given the app, in the order they came, whether a guest has them or not.
    public private(set) var devices: [USBDevice] = []
    /// The machines there are, in the order in which they are offered a device that several would take.
    @ObservationIgnored public var machines: @MainActor () -> [VirtualMachine] = { [] }
    /// For how long after a detach by hand the device's return to this Mac is taken for just that, and
    /// not for someone plugging it in, which a machine that takes the device by itself would act on.
    @ObservationIgnored public var holdOff: Duration = .seconds(5)
    /// How long a device that a guest has let go of may take to come back to this Mac. Until it has, the
    /// old one is still listed and can't be handed to anyone.
    @ObservationIgnored public var settlingTime: Duration = .seconds(3)

    /// Devices that are being handed to a guest at this moment.
    @ObservationIgnored private var onTheirWay: Set<USBDevice.ID> = []
    /// When each device that was detached by hand was, by what stays the same when it comes back.
    @ObservationIgnored private var detachedByHand: [String: ContinuousClock.Instant] = [:]
    /// The machine that had each device last, by what stays the same about the device.
    @ObservationIgnored private var lastHolders: [String: UUID] = [:]

    public init() {}

    /// The machine whose guest has the device, if one does.
    public func holder(of id: USBDevice.ID) -> VirtualMachine? {
        machines().first { machine in machine.usbDevices.contains { $0.id == id } }
    }

    // MARK: What the host reports

    /// This Mac has given the app a device.
    public func deviceDidConnect(_ device: USBDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        offer(device)
    }

    /// A device is gone: pulled out, or given back to this Mac.
    public func deviceDidDisconnect(_ id: USBDevice.ID) {
        devices.removeAll { $0.id == id }
        holder(of: id)?.usbDeviceDidDisappear(id)
    }

    /// A machine's guest has come up. It takes the devices it is set to take that are free.
    public func machineDidStart(_ machine: VirtualMachine) {
        for device in devices where machine.configuration.usb.connectsAutomatically(device) && isFree(device) {
            attachByItself(device, to: machine)
        }
    }

    // MARK: By hand

    /// Hands a device to a machine's running guest.
    public func attach(_ device: USBDevice, to machine: VirtualMachine) async throws {
        guard availability == .available else { throw Failure.unavailable(availability) }
        guard devices.contains(where: { $0.id == device.id }) else { throw Failure.gone(device: device.name) }
        if let holder = holder(of: device.id) {
            guard holder.id != machine.id else { return }
            throw Failure.inUse(device: device.name, by: holder.name)
        }
        guard onTheirWay.insert(device.id).inserted else { throw Failure.onItsWay(device: device.name) }
        defer { onTheirWay.remove(device.id) }
        try await machine.attachUSBDevice(device)
        lastHolders[Self.mark(of: device)] = machine.id
        // Pulled out while it was on its way, the device was reported gone when no guest had it yet.
        guard devices.contains(where: { $0.id == device.id }) else {
            machine.usbDeviceDidDisappear(device.id)
            throw Failure.gone(device: device.name)
        }
    }

    /// Gives a device that a machine's guest has back to this Mac, and returns when this Mac has it:
    /// from then on it can be handed to another guest.
    public func detach(_ device: USBDevice, from machine: VirtualMachine) async throws {
        guard machine.usbDevices.contains(where: { $0.id == device.id }) else { return }
        let mark = Self.mark(of: device)
        detachedByHand[mark] = .now
        try await machine.detachUSBDevice(device.id)

        let deadline = ContinuousClock.now + settlingTime
        while ContinuousClock.now < deadline {
            let isBack = !devices.contains { $0.id == device.id } && devices.contains { Self.mark(of: $0) == mark }
            if isBack { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Sets whether a machine takes devices of this make by itself whenever both are there. Turned on
    /// for a device that is free while the machine runs, it takes that device now.
    public func setConnectsAutomatically(_ isOn: Bool, _ device: USBDevice, to machine: VirtualMachine) throws {
        try machine.updateConfiguration { $0.usb.setConnectsAutomatically(isOn, for: device) }
        if isOn, machine.state == .running, devices.contains(where: { $0.id == device.id }), isFree(device) {
            attachByItself(device, to: machine)
        }
    }

    // MARK: By itself

    /// Hands a device that has just come to a running machine that is set to take it: the one that had
    /// it last, or else the first.
    private func offer(_ device: USBDevice) {
        guard isFree(device) else { return }
        let mark = Self.mark(of: device)
        // The first time a device shows up after it was detached by hand is this Mac getting it back.
        if let detached = detachedByHand.removeValue(forKey: mark), ContinuousClock.now - detached < holdOff {
            return
        }
        let wanting = machines().filter { $0.configuration.usb.connectsAutomatically(device) }
        if let last = wanting.first(where: { $0.id == lastHolders[mark] }) {
            if last.state == .running {
                attachByItself(device, to: last)
                return
            }
            // A machine that restarts has let go of the device and is on its way back up. It takes the
            // device when it is up; until then nobody else does.
            if last.isRestartPending || last.state == .starting || last.state == .restoring {
                return
            }
        }
        if let taker = wanting.first(where: { $0.state == .running }) {
            attachByItself(device, to: taker)
        }
    }

    private func attachByItself(_ device: USBDevice, to machine: VirtualMachine) {
        Task {
            // Nobody asked for this, so whatever has changed since it was decided is a reason to leave it.
            guard machine.state == .running, isFree(device) else { return }
            do {
                try await attach(device, to: machine)
            } catch VMError.notRunning, VMError.busy, Failure.gone, Failure.inUse, Failure.onItsWay {
                // The machine stopped or is busy, the device went, or someone was quicker.
            } catch {
                // A machine that restarts reaches for the device it has just let go of before it has
                // come back. The one that comes back is offered to it anew, and what went wrong with
                // the old one is of no interest. Nor is it once the machine has stopped, or has the
                // device after all.
                try? await Task.sleep(for: settlingTime)
                guard devices.contains(where: { $0.id == device.id }), holder(of: device.id) == nil, machine.state == .running else { return }
                machine.lastError = VMErrorInfo(title: "Couldn't attach “\(device.name)” to “\(machine.name)”", message: error.localizedDescription)
            }
        }
    }

    private func isFree(_ device: USBDevice) -> Bool {
        holder(of: device.id) == nil && !onTheirWay.contains(device.id)
    }

    /// What is the same about a device the next time it shows up, unlike its number.
    private static func mark(of device: USBDevice) -> String {
        "\(device.identifier) \(device.serialNumber ?? "")"
    }
}
