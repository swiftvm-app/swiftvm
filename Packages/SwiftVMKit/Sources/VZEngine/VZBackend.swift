import AccessoryAccess
import AppKit
import DiskTools
import GuestChannel
import VMCore
import Virtualization

/// A machine running on Apple's Virtualization framework.
@MainActor
public final class VZBackend: NSObject, VMBackend {
    public var eventHandler: (@MainActor (VMBackendEvent) -> Void)?

    private let virtualMachine: VZVirtualMachine
    private let vzConfiguration: VZVirtualMachineConfiguration
    private let machineConfiguration: VMConfiguration
    /// Creates a fresh attachment when an interface is plugged back in.
    private let attachmentProvider: @MainActor (NetworkInterfaceConfiguration) throws -> VZNetworkDeviceAttachment
    private var view: VZVirtualMachineView?
    /// The display, the mouse and the keyboard for the app's own use, from when it first asks for them.
    private var desk: MachineDesk?
    private var capturesSystemKeys: Bool
    /// The interfaces whose cable is out because the user pulled it.
    private var unpluggedInterfaces: Set<UUID>
    /// Finds what the system knows a USB device of this Mac by, which is what the guest is handed.
    private let usbAccessory: @MainActor (USBDevice.ID) -> AAUSBAccessory?
    /// The USB devices of this Mac that the guest has.
    private var passthroughDevices: [USBDevice.ID: VZUSBPassthroughDevice] = [:]
    /// The compressed disks of the machine, which the app serves to it for as long as it is there.
    private var diskExports: [CompressedDiskExport]

    init(
        vzConfiguration: VZVirtualMachineConfiguration,
        machineConfiguration: VMConfiguration,
        diskExports: [CompressedDiskExport] = [],
        attachmentProvider: @escaping @MainActor (NetworkInterfaceConfiguration) throws -> VZNetworkDeviceAttachment,
        usbAccessory: @escaping @MainActor (USBDevice.ID) -> AAUSBAccessory? = { _ in nil }
    ) {
        self.vzConfiguration = vzConfiguration
        self.machineConfiguration = machineConfiguration
        self.capturesSystemKeys = machineConfiguration.keyboard.capturesSystemKeys
        self.unpluggedInterfaces = Set(machineConfiguration.networkInterfaces.filter { !$0.isConnected }.map(\.id))
        self.attachmentProvider = attachmentProvider
        self.usbAccessory = usbAccessory
        self.diskExports = diskExports
        // Without an explicit queue the machine uses the main queue, matching this class's isolation.
        self.virtualMachine = VZVirtualMachine(configuration: vzConfiguration)
        super.init()
        virtualMachine.delegate = self
        virtualMachine.usbControllers.first?.delegate = self
    }

    // MARK: Display

    public var displayView: NSView {
        if let view {
            return view
        }
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = capturesSystemKeys
        view.automaticallyReconfiguresDisplay = machineConfiguration.display.automaticallyResizes
        self.view = view
        return view
    }

    private var ownDesk: MachineDesk {
        if let desk {
            return desk
        }
        let desk = MachineDesk(virtualMachine: virtualMachine)
        self.desk = desk
        return desk
    }

    public func screenshot() async throws -> Data {
        try await ownDesk.screenshot()
    }

    public func pointer(_ request: GuestJob.Pointer, guestTurnsWheel: Bool) async throws {
        try await ownDesk.pointer(request, guestTurnsWheel: guestTurnsWheel)
    }

    public func keys(_ request: GuestJob.Keys) async throws {
        try await ownDesk.keys(request)
    }

    // MARK: Lifecycle

    public var canRequestStop: Bool { virtualMachine.canRequestStop }

    public func start(options: VMStartOptions) async throws {
        if let savedState = options.savedState {
            try await perform { self.virtualMachine.restoreMachineStateFrom(url: savedState, completionHandler: $0) }
            try await resume()
        } else if machineConfiguration.os.family == .macOS {
            let startOptions = VZMacOSVirtualMachineStartOptions()
            startOptions.startUpFromMacOSRecovery = options.startsInRecovery
            if let provisioning = options.provisioning {
                try startOptions.setGuestProvisioning(provisioning.macOptions)
            }
            try await perform { self.virtualMachine.start(options: startOptions, completionHandler: $0) }
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                virtualMachine.start { continuation.resume(with: $0) }
            }
        }
    }

    public func requestStop() throws {
        try virtualMachine.requestStop()
    }

    public func stop() async throws {
        guard virtualMachine.canStop else { return }
        try await perform { self.virtualMachine.stop(completionHandler: $0) }
    }

    public func pause() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            virtualMachine.pause { continuation.resume(with: $0) }
        }
    }

    public func resume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            virtualMachine.resume { continuation.resume(with: $0) }
        }
    }

    public func saveState(to url: URL) async throws {
        try vzConfiguration.validateSaveRestoreSupport()
        try? FileManager.default.removeItem(at: url)
        try await perform { self.virtualMachine.saveMachineStateTo(url: url, completionHandler: $0) }
    }

    /// Runs a completion-handler API and suspends until it reports success or failure.
    private func perform(_ operation: (@escaping ((any Error)?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            operation { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: Live device changes

    public func setNetworkInterface(_ id: UUID, connected: Bool) throws {
        guard let index = machineConfiguration.networkInterfaces.firstIndex(where: { $0.id == id }),
              virtualMachine.networkDevices.indices.contains(index)
        else { return }
        let device = virtualMachine.networkDevices[index]
        if connected {
            device.attachment = try attachmentProvider(machineConfiguration.networkInterfaces[index])
            unpluggedInterfaces.remove(id)
        } else {
            unpluggedInterfaces.insert(id)
            device.attachment = nil
        }
    }

    /// A vmnet network stays reserved for as long as any attachment to it exists, and the framework can keep
    /// the machine and its configuration alive for a while after it stops. Dropping the attachments here
    /// frees the network right away.
    public func invalidate() {
        virtualMachine.delegate = nil
        virtualMachine.usbControllers.first?.delegate = nil
        passthroughDevices = [:]
        for device in virtualMachine.networkDevices {
            device.attachment = nil
        }
        for device in vzConfiguration.networkDevices {
            device.attachment = nil
        }
        view?.virtualMachine = nil
        view = nil
        desk?.invalidate()
        desk = nil
        // The machine has stopped, so nothing is being written any more. What a disk can't commit
        // now stays in its journal and is brought back when it is opened again.
        for export in diskExports { try? export.close() }
        diskExports = []
    }

    public func setSharedFolders(_ folders: [SharedFolder]) throws {
        let tag = VZConfigurationBuilder.sharedFoldersTag(for: machineConfiguration.os.family)
        let device = virtualMachine.directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDevice }
            .first { $0.tag == tag }
        device?.share = VZConfigurationBuilder.makeShare(for: folders)
    }

    public func attachRemovableImage(_ image: RemovableImage) async throws {
        guard let controller = virtualMachine.usbControllers.first else {
            throw VMError.invalidConfiguration("This virtual machine has no USB controller.")
        }
        let drive = VZUSBMassStorageDevice(configuration: try VZConfigurationBuilder.makeRemovableDrive(for: image))
        try await perform { controller.attach(device: drive, completionHandler: $0) }
    }

    public func detachRemovableImage(_ id: UUID) async throws {
        guard let controller = virtualMachine.usbControllers.first,
              let drive = controller.usbDevices.first(where: { $0.uuid == id })
        else { return }
        try await perform { controller.detach(device: drive, completionHandler: $0) }
    }

    public func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {
        self.capturesSystemKeys = capturesSystemKeys
        view?.capturesSystemKeys = capturesSystemKeys
    }

    // MARK: USB devices

    public func attachUSBDevice(_ device: USBDevice) async throws {
        guard let controller = virtualMachine.usbControllers.first else {
            throw VMError.invalidConfiguration("This virtual machine has no USB controller.")
        }
        guard let accessory = usbAccessory(device.id) else {
            throw VMError.invalidConfiguration("“\(device.name)” isn't with this app any more. It was pulled out, or given back to this Mac.")
        }
        do {
            let passthrough = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
            try await perform { controller.attach(device: passthrough, completionHandler: $0) }
            passthroughDevices[device.id] = passthrough
        } catch {
            // The framework's own words for this are a number. The usual cause is a device that a guest
            // has only just let go of: it comes back to this Mac as a new one a moment later.
            throw VMError.invalidConfiguration("The guest couldn't be handed “\(device.name)”. If it was only just detached or plugged in, try again in a moment. (\(error.localizedDescription))")
        }
    }

    public func detachUSBDevice(_ id: USBDevice.ID) async throws {
        guard let controller = virtualMachine.usbControllers.first, let passthrough = passthroughDevices[id] else { return }
        try await perform { controller.detach(device: passthrough, completionHandler: $0) }
        passthroughDevices[id] = nil
    }

    // MARK: Guest socket

    public func connectToGuest(port: UInt32) async throws -> FileHandle {
        guard let device = virtualMachine.socketDevices.lazy.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
            throw VMError.invalidConfiguration("This virtual machine has no socket device.")
        }
        let descriptor: Int32 = try await withCheckedThrowingContinuation { continuation in
            device.connect(toPort: port) { result in
                continuation.resume(with: result.flatMap { connection -> Result<Int32, any Error> in
                    // The connection object closes its descriptor when it is released. The caller gets
                    // one of its own, which keeps the line open for as long as the caller holds it.
                    let descriptor = dup(connection.fileDescriptor)
                    let code = errno
                    connection.close()
                    return descriptor >= 0 ? .success(descriptor) : .failure(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
                })
            }
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

// The machine runs on the main queue, so its delegate callbacks arrive on the main actor.
extension VZBackend: @preconcurrency VZVirtualMachineDelegate {
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        eventHandler?(.guestDidStop)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        eventHandler?(.stoppedWithError(error.localizedDescription))
    }

    public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: any Error
    ) {
        // A cable that the user has pulled is no news. The framework reports one all the same when a
        // guest is resumed with its cable out.
        if let index = virtualMachine.networkDevices.firstIndex(where: { $0 === networkDevice }),
           machineConfiguration.networkInterfaces.indices.contains(index),
           unpluggedInterfaces.contains(machineConfiguration.networkInterfaces[index].id) {
            return
        }
        eventHandler?(.networkDisconnected(error.localizedDescription))
    }
}

extension VZBackend: VZUSBController.Delegate {
    /// A device the guest had was pulled out. The framework has taken it off the controller already.
    ///
    /// Nothing says which queue this arrives on, so it is taken on any and passed to the main one, and
    /// the device, which isn't made to travel between them, is told from the others by what it is.
    public nonisolated func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        let gone = ObjectIdentifier(device)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let id = self.passthroughDevices.first(where: { ObjectIdentifier($0.value) == gone })?.key else { return }
                self.passthroughDevices[id] = nil
                self.eventHandler?(.usbDeviceDisconnected(id))
            }
        }
    }
}
