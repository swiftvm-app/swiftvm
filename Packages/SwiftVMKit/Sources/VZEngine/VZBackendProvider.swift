import DiskTools
import Foundation
import VMCore
import VMNetworking
import Virtualization

/// Builds Virtualization-framework backends and wires them to the app-managed networks.
@MainActor
public final class VZBackendProvider: VMBackendProvider {
    public enum ProviderError: Error, LocalizedError {
        case virtualizationUnavailable
        case networkUnavailable

        public var errorDescription: String? {
            switch self {
            case .virtualizationUnavailable:
                "Virtualization isn't available on this Mac."
            case .networkUnavailable:
                "The virtual network isn't available."
            }
        }
    }

    private let networkManager: NetworkManager
    /// Knows the USB devices of this Mac that a guest can be handed. `nil` where there are none to hand out.
    private let usbAccessories: USBAccessoryService?

    public init(networkManager: NetworkManager, usbAccessories: USBAccessoryService? = nil) {
        self.networkManager = networkManager
        self.usbAccessories = usbAccessories
    }

    public func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd, ownership: PackageOwnership) async throws -> any VMBackend {
        let configuration = machine.configuration
        guard configuration.engine == .virtualization else {
            throw VMError.unsupportedEngine(configuration.engine)
        }
        guard VZVirtualMachine.isSupported else {
            throw ProviderError.virtualizationUnavailable
        }

        let machineID = machine.id
        do {
            // Keep the shared network alive even with its cable out, so it can be plugged back in.
            let network = configuration.networkInterfaces.contains(where: \.usesSharedNetwork)
                ? try await networkManager.acquireDefaultNetwork(for: machineID) : nil
            var attachments: [UUID: VZNetworkDeviceAttachment] = [:]
            for interface in configuration.networkInterfaces where interface.isConnected {
                attachments[interface.id] = try Self.attachment(for: interface, sharedNetwork: network)
            }
            var diskExports: [CompressedDiskExport] = []
            let vzConfiguration = try VZConfigurationBuilder(
                bundle: machine.bundle,
                configuration: configuration,
                networkAttachments: attachments,
                console: console
            ).build(diskExports: &diskExports)
            try ownership.expectRuntimeResource(configuration.os.family == .macOS ? "aux.img" : "efi-vars.fd")
            return VZBackend(
                vzConfiguration: vzConfiguration,
                machineConfiguration: configuration,
                ownership: ownership,
                diskExports: diskExports,
                attachmentProvider: { [weak self] interface in
                    try Self.attachment(for: interface, sharedNetwork: self?.networkManager.liveDefaultNetwork)
                },
                usbAccessory: { [weak usbAccessories] id in usbAccessories?.accessory(for: id) }
            )
        } catch {
            networkManager.release(user: machineID)
            throw error
        }
    }

    public func backendDidStop(for machine: VirtualMachine) {
        networkManager.release(user: machine.id)
    }

    static func attachment(for interface: NetworkInterfaceConfiguration, sharedNetwork: VmnetNetwork?) throws -> VZNetworkDeviceAttachment {
        if let identifier = interface.bridgedInterfaceIdentifier {
            return try VZBridgedNetworkDeviceAttachment(interface: BridgedNetworking.interface(named: identifier))
        }
        guard let sharedNetwork else { throw ProviderError.networkUnavailable }
        return VZVmnetNetworkDeviceAttachment(network: sharedNetwork.reference)
    }
}
