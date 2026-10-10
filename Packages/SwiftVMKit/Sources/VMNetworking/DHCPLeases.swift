import Foundation
import VMCore

/// Reads the system DHCP lease database to find the addresses a guest was given.
public enum DHCPLeases {
    public static let systemLeasesURL = URL(fileURLWithPath: "/var/db/dhcpd_leases")

    public struct Lease: Sendable, Hashable {
        /// Host name the client announced.
        public var name: String?
        public var address: IPv4Address
        /// `nil` when the client identified itself with something other than its MAC address.
        public var macAddress: MACAddress?
        /// Lease expiry as a Unix timestamp; newer leases win.
        public var expiry: UInt64
    }

    /// Addresses of unexpired leases inside `subnet` that belong to the given MAC address or to a client that
    /// announced `hostName`, most recently issued first.
    ///
    /// Matching by host name covers guests whose DHCP client sends a generated identifier instead of its
    /// MAC. More than one address can come back: a guest may have held different leases at different stages
    /// of its boot, and an older one stays in the database until it expires.
    public static func currentAddresses(
        macAddress: MACAddress,
        hostName: String?,
        in subnet: IPv4Subnet,
        now: Date = Date(),
        leasesURL: URL = systemLeasesURL
    ) -> [IPv4Address] {
        let timestamp = UInt64(max(now.timeIntervalSince1970, 0))
        let matching = leases(in: leasesURL)
            .filter { $0.expiry > timestamp && subnet.contains($0.address) }
            .filter { lease in
                if lease.macAddress == macAddress { return true }
                guard let hostName, !hostName.isEmpty else { return false }
                return lease.name == hostName
            }
            .sorted { $0.expiry > $1.expiry }
        var seen: Set<IPv4Address> = []
        return matching.map(\.address).filter { seen.insert($0).inserted }
    }

    public static func leases(in url: URL = systemLeasesURL) -> [Lease] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Parses the brace-delimited `key=value` records of `dhcpd_leases`.
    public static func parse(_ text: String) -> [Lease] {
        var leases: [Lease] = []
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                fields = [:]
            } else if line == "}" {
                if let lease = lease(from: fields) {
                    leases.append(lease)
                }
                fields = [:]
            } else if let separator = line.firstIndex(of: "=") {
                fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
            }
        }
        return leases
    }

    private static func lease(from fields: [String: String]) -> Lease? {
        guard let addressString = fields["ip_address"], let address = IPv4Address(addressString) else { return nil }
        // hw_address is "<type>,<id>". Type 1 is Ethernet, where the id is the MAC address with leading zeros
        // stripped from each octet ("1,2:1a:2b:3:4d:5e"); other types carry an opaque client identifier.
        var macAddress: MACAddress?
        if let hardware = fields["hw_address"] {
            let parts = hardware.split(separator: ",", maxSplits: 1)
            if parts.count == 2, parts[0] == "1" {
                macAddress = MACAddress(String(parts[1]))
            }
        }
        let expiry = fields["lease"].flatMap { UInt64($0.dropFirst(2), radix: 16) } ?? 0
        return Lease(name: fields["name"], address: address, macAddress: macAddress, expiry: expiry)
    }
}
