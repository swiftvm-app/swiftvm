import AppKit
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
    private var capturesSystemKeys: Bool

    init(
        vzConfiguration: VZVirtualMachineConfiguration,
        machineConfiguration: VMConfiguration,
        attachmentProvider: @escaping @MainActor (NetworkInterfaceConfiguration) throws -> VZNetworkDeviceAttachment
    ) {
        self.vzConfiguration = vzConfiguration
        self.machineConfiguration = machineConfiguration
        self.capturesSystemKeys = machineConfiguration.keyboard.capturesSystemKeys
        self.attachmentProvider = attachmentProvider
        // Without an explicit queue the machine uses the main queue, matching this class's isolation.
        self.virtualMachine = VZVirtualMachine(configuration: vzConfiguration)
        super.init()
        virtualMachine.delegate = self
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
        } else {
            device.attachment = nil
        }
    }

    /// A vmnet network stays reserved for as long as any attachment to it exists, and the framework can keep
    /// the machine and its configuration alive for a while after it stops. Dropping the attachments here
    /// frees the network right away.
    public func invalidate() {
        virtualMachine.delegate = nil
        for device in virtualMachine.networkDevices {
            device.attachment = nil
        }
        for device in vzConfiguration.networkDevices {
            device.attachment = nil
        }
        view?.virtualMachine = nil
        view = nil
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
        eventHandler?(.networkDisconnected(error.localizedDescription))
    }
}
