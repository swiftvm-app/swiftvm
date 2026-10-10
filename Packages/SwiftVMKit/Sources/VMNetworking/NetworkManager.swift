import Foundation
import VMCore
import vmnet

/// A live vmnet network. The underlying network exists for as long as this object does.
public final class VmnetNetwork: @unchecked Sendable {
    /// The `vmnet_network_ref` to hand to `VZVmnetNetworkDeviceAttachment`.
    public let reference: OpaquePointer
    public let subnet: IPv4Subnet
    /// Reservations that were applied when the network was created.
    public let reservations: [MACAddress: IPv4Address]

    init(reference: OpaquePointer, subnet: IPv4Subnet, reservations: [MACAddress: IPv4Address]) {
        self.reference = reference
        self.subnet = subnet
        self.reservations = reservations
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(reference)).release()
    }
}

/// What a network should provide when it comes up: a fixed address for each machine.
///
/// Forwarded ports are not part of this, although vmnet offers them: like reservations they can only be
/// set while the network is created, so changing one would mean shutting down every machine. They are
/// relayed by the app instead (``PortRelay``).
public struct NetworkPlan: Sendable, Hashable {
    public struct Reservation: Sendable, Hashable {
        public var macAddress: MACAddress
        public var address: IPv4Address

        public init(macAddress: MACAddress, address: IPv4Address) {
            self.macAddress = macAddress
            self.address = address
        }
    }

    public var reservations: [Reservation]

    public init(reservations: [Reservation] = []) {
        self.reservations = reservations
    }
}

public enum NetworkError: Error, LocalizedError {
    case creationFailed(code: Int, subnet: IPv4Subnet)
    case noSubnetAvailable

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let code, let subnet):
            "Couldn't create the virtual network \(subnet) (vmnet error \(code)). Another app may be using this address range."
        case .noSubnetAvailable:
            "Couldn't find a free private address range for the virtual network."
        }
    }
}

/// Owns the app-managed virtual networks that machines attach to.
///
/// The default network is a NAT network with a fixed subnet. It is created when the first machine starts
/// and released when the last one stops. Two vmnet behaviors force this: DHCP reservations can only be
/// set while a network is being created, and they stop being honored once every interface has left the
/// network, even if the network object is kept.
@MainActor
public final class NetworkManager {
    /// The subnet of the default network; persisted so guest addresses stay stable across launches.
    public private(set) var defaultSubnet: IPv4Subnet

    /// Supplies the reservations to apply the next time the network is created.
    public var planProvider: (@MainActor () -> NetworkPlan)?

    /// Called when the default network moves to another subnet, with the old and new subnets.
    public var onDefaultSubnetChange: (@MainActor (IPv4Subnet, IPv4Subnet) -> Void)?

    private var network: VmnetNetwork?
    private var pendingCreation: Task<VmnetNetwork, any Error>?
    private var users: Set<UUID> = []
    private let settingsURL: URL

    public init(rootDirectory: URL) throws {
        settingsURL = rootDirectory.appending(path: "network.json")
        if let data = try? Data(contentsOf: settingsURL),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            defaultSubnet = settings.defaultSubnet
        } else {
            guard let subnet = SubnetPicker.pick(avoiding: SubnetPicker.hostSubnets()) else {
                throw NetworkError.noSubnetAvailable
            }
            defaultSubnet = subnet
            try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            saveSettings()
        }
    }

    /// The default network if it currently exists (at least one machine is attached).
    public var liveDefaultNetwork: VmnetNetwork? { network }

    /// Whether the default network currently exists.
    public var isActive: Bool { network != nil }

    /// The address reserved for `macAddress` on the live network, if the reservation is in effect.
    public func activeReservation(for macAddress: MACAddress) -> IPv4Address? {
        network?.reservations[macAddress]
    }

    /// Returns the default network, creating it if no machine is attached yet, and registers `user`.
    ///
    /// If the persisted subnet can't be used (another app holds it, or the system still holds it for a
    /// process that exited without detaching), the network moves to the next free subnet and
    /// ``onDefaultSubnetChange`` is called so reserved addresses can follow.
    public func acquireDefaultNetwork(for user: UUID) async throws -> VmnetNetwork {
        if let pendingCreation {
            let created = try await pendingCreation.value
            users.insert(user)
            return created
        }
        if let network {
            // A live network can't take new reservations; a machine added since gets a dynamic address
            // until the network is next rebuilt.
            users.insert(user)
            return network
        }
        let task = Task { try await createDefaultNetwork() }
        pendingCreation = task
        defer { pendingCreation = nil }
        let created = try await task.value
        network = created
        users.insert(user)
        return created
    }

    /// Unregisters `user`. The network is released when nobody is attached any more.
    public func release(user: UUID) {
        users.remove(user)
        if users.isEmpty, pendingCreation == nil {
            network = nil
        }
    }

    private static let maximumSubnetAttempts = 6
    /// How long to keep trying the same subnet. A machine that has just stopped can hold it briefly.
    private static let sameSubnetRetries = 8

    private func createDefaultNetwork() async throws -> VmnetNetwork {
        let original = defaultSubnet
        var unusable: [IPv4Subnet] = []
        var firstError: (any Error)?
        for attempt in 0..<Self.maximumSubnetAttempts {
            let retries = attempt == 0 ? Self.sameSubnetRetries : 1
            for retry in 0..<retries {
                do {
                    let plan = planProvider?() ?? NetworkPlan()
                    let created = try Self.makeSharedNetwork(subnet: defaultSubnet, plan: plan)
                    if defaultSubnet != original {
                        saveSettings()
                    }
                    return created
                } catch {
                    firstError = firstError ?? error
                    if retry + 1 < retries {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            unusable.append(defaultSubnet)
            guard let replacement = SubnetPicker.pick(avoiding: SubnetPicker.hostSubnets(), alsoAvoiding: unusable) else { break }
            move(to: replacement)
        }
        // Nothing worked, so the cause isn't the subnet. Go back rather than leave addresses shuffled.
        if defaultSubnet != original {
            move(to: original)
        }
        throw firstError ?? NetworkError.noSubnetAvailable
    }

    private func move(to subnet: IPv4Subnet) {
        let previous = defaultSubnet
        defaultSubnet = subnet
        onDefaultSubnetChange?(previous, subnet)
    }

    /// Moves the default network to a different subnet if the current one now collides with a network the
    /// host has joined. Only possible while no machine is attached.
    public func relocateDefaultSubnetIfNeeded() {
        guard network == nil else { return }
        let hostSubnets = SubnetPicker.hostSubnets()
        guard hostSubnets.contains(where: { $0.overlaps(defaultSubnet) }),
              let replacement = SubnetPicker.pick(avoiding: hostSubnets)
        else { return }
        move(to: replacement)
        saveSettings()
    }

    /// Re-maps an address from one subnet to the same host number in another.
    public nonisolated static func remap(_ address: IPv4Address, from old: IPv4Subnet, to new: IPv4Subnet) -> IPv4Address {
        let hostPart = address.rawValue & ~old.mask.rawValue
        return IPv4Address(rawValue: new.network.rawValue | (hostPart & ~new.mask.rawValue))
    }

    // MARK: vmnet

    private static func makeSharedNetwork(subnet: IPv4Subnet, plan: NetworkPlan) throws -> VmnetNetwork {
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let configuration = vmnet_network_configuration_create(.VMNET_SHARED_MODE, &status) else {
            throw NetworkError.creationFailed(code: Int(status.rawValue), subnet: subnet)
        }
        defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(configuration)).release() }

        // vmnet wants the host's own address here, not the network address. Given the network address the
        // network is still created, but every interface fails with "Internal Network Error" once a guest uses it.
        var hostAddress = subnet.hostAddress.inAddr
        var mask = subnet.mask.inAddr
        status = vmnet_network_configuration_set_ipv4_subnet(configuration, &hostAddress, &mask)
        guard status == .VMNET_SUCCESS else {
            throw NetworkError.creationFailed(code: Int(status.rawValue), subnet: subnet)
        }

        var applied: [MACAddress: IPv4Address] = [:]
        for reservation in plan.reservations where subnet.contains(reservation.address) {
            // Skip duplicates; vmnet rejects a second reservation for the same MAC or address.
            guard applied[reservation.macAddress] == nil, !applied.values.contains(reservation.address) else { continue }
            let o = reservation.macAddress.octets
            var client = ether_addr_t(octet: (o[0], o[1], o[2], o[3], o[4], o[5]))
            var address = reservation.address.inAddr
            if vmnet_network_configuration_add_dhcp_reservation(configuration, &client, &address) == .VMNET_SUCCESS {
                applied[reservation.macAddress] = reservation.address
            }
        }

        guard let reference = vmnet_network_create(configuration, &status) else {
            throw NetworkError.creationFailed(code: Int(status.rawValue), subnet: subnet)
        }
        return VmnetNetwork(reference: reference, subnet: subnet, reservations: applied)
    }

    // MARK: Settings

    private struct Settings: Codable {
        var defaultSubnet: IPv4Subnet

        enum CodingKeys: String, CodingKey { case defaultSubnet }

        init(defaultSubnet: IPv4Subnet) {
            self.defaultSubnet = defaultSubnet
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let string = try container.decode(String.self, forKey: .defaultSubnet)
            guard let subnet = IPv4Subnet(string) else {
                throw DecodingError.dataCorruptedError(forKey: .defaultSubnet, in: container, debugDescription: "Invalid subnet \(string)")
            }
            defaultSubnet = subnet
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(defaultSubnet.description, forKey: .defaultSubnet)
        }
    }

    private func saveSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Settings(defaultSubnet: defaultSubnet)) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
}
