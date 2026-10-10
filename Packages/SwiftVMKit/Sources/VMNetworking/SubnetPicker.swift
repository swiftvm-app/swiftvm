import Foundation

/// Chooses a private subnet for an app-managed network that doesn't collide with networks the host is on.
public enum SubnetPicker {
    /// Candidate /24 networks, in order of preference.
    static var candidates: [IPv4Subnet] {
        let preferred = [230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 205, 206, 207, 208, 209]
        return preferred.compactMap { IPv4Subnet("192.168.\($0).0/24") }
            + (16...31).compactMap { IPv4Subnet("172.\($0).230.0/24") }
    }

    /// The first candidate that overlaps none of the subnets in `inUse`.
    public static func pick(avoiding inUse: [IPv4Subnet], alsoAvoiding reserved: [IPv4Subnet] = []) -> IPv4Subnet? {
        candidates.first { candidate in
            !(inUse + reserved).contains { $0.overlaps(candidate) }
        }
    }

    /// Subnets of the host's configured IPv4 interfaces.
    public static func hostSubnets() -> [IPv4Subnet] {
        var result: [IPv4Subnet] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addressPointer = interface.pointee.ifa_addr,
                  let maskPointer = interface.pointee.ifa_netmask,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
            let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address($0.pointee.sin_addr) }
            let prefixLength = mask.rawValue.nonzeroBitCount
            // Loopback and link-local addresses never conflict with a private /24.
            guard address.rawValue >> 24 != 127, address.rawValue >> 16 != 0xA9FE else { continue }
            if let subnet = IPv4Subnet(network: address, prefixLength: max(8, min(prefixLength, 30))) {
                result.append(subnet)
            }
        }
        return result
    }
}
