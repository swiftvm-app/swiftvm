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

    public func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        let configuration = machine.configuration
        guard configuration.engine == .virtualization else {
            throw VMError.unsupportedEngine(configuration.engine)
        }
        guard VZVirtualMachine.isSupported else {
            throw ProviderError.virtualizationUnavailable
        }

        let machineID = machine.id
        do {
            // Every interface attaches to the default network for now, so the machine registers once.
            let network = try await networkManager.acquireDefaultNetwork(for: machineID)
            var attachments: [UUID: VZNetworkDeviceAttachment] = [:]
            for interface in configuration.networkInterfaces where interface.isConnected {
                attachments[interface.id] = VZVmnetNetworkDeviceAttachment(network: network.reference)
            }
            let vzConfiguration = try VZConfigurationBuilder(
                bundle: machine.bundle,
                configuration: configuration,
                networkAttachments: attachments,
                console: console
            ).build()
            return VZBackend(
                vzConfiguration: vzConfiguration,
                machineConfiguration: configuration,
                attachmentProvider: { [weak self] _ in
                    // Plugging the cable back in: the machine is still registered, so the network is live.
                    guard let network = self?.networkManager.liveDefaultNetwork else {
                        throw ProviderError.networkUnavailable
                    }
                    return VZVmnetNetworkDeviceAttachment(network: network.reference)
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
}
