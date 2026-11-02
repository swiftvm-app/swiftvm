import Foundation
import Security
import Virtualization

/// Host interfaces macOS allows a guest to bridge to. The BSD identifier is kept in the VM bundle,
/// so an unplugged adapter is reported as missing instead of silently choosing a different LAN.
public enum BridgedNetworking {
    public struct Interface: Identifiable, Sendable, Hashable {
        public let id: String
        public let name: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notEntitled
        case interfaceUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .notEntitled:
                "This copy of SwiftVM doesn't support bridged networking. It needs to be signed with a provisioning profile that grants com.apple.vm.networking."
            case .interfaceUnavailable(let identifier):
                "The host network interface “\(identifier)” isn't available for bridging. Connect the adapter or choose another interface in the virtual machine's Network settings."
            }
        }
    }

    public static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.vm.networking" as CFString, nil) as? Bool == true
    }

    public static var interfaces: [Interface] {
        VZBridgedNetworkInterface.networkInterfaces.map {
            Interface(id: $0.identifier, name: $0.localizedDisplayName ?? $0.identifier)
        }.sorted { $0.id < $1.id }
    }

    public static func interface(named identifier: String) throws -> VZBridgedNetworkInterface {
        guard isEntitled else { throw Failure.notEntitled }
        guard let interface = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == identifier }) else {
            throw Failure.interfaceUnavailable(identifier)
        }
        return interface
    }
}
