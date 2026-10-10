import Foundation

/// An IPv4 address.
public struct IPv4Address: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The address in host byte order, e.g. `192.168.1.10` is `0xC0A8010A`.
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        rawValue = value
    }

    public var description: String {
        "\(rawValue >> 24 & 0xFF).\(rawValue >> 16 & 0xFF).\(rawValue >> 8 & 0xFF).\(rawValue & 0xFF)"
    }

    /// The address as a `struct in_addr` (network byte order).
    public var inAddr: in_addr {
        in_addr(s_addr: rawValue.bigEndian)
    }

    public init(_ address: in_addr) {
        rawValue = UInt32(bigEndian: address.s_addr)
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let address = IPv4Address(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid IPv4 address \(string)"))
        }
        self = address
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// An IPv4 network such as `192.168.230.0/24`.
public struct IPv4Subnet: Sendable, Hashable, Codable, CustomStringConvertible {
    public let network: IPv4Address
    public let prefixLength: Int

    public init?(network: IPv4Address, prefixLength: Int) {
        guard (8...30).contains(prefixLength) else { return nil }
        let mask = Self.maskValue(prefixLength)
        self.network = IPv4Address(rawValue: network.rawValue & mask)
        self.prefixLength = prefixLength
    }

    /// Parses CIDR notation, e.g. `192.168.230.0/24`.
    public init?(_ string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2, let address = IPv4Address(String(parts[0])), let prefix = Int(parts[1]) else { return nil }
        self.init(network: address, prefixLength: prefix)
    }

    public var mask: IPv4Address { IPv4Address(rawValue: Self.maskValue(prefixLength)) }
    public var broadcast: IPv4Address { IPv4Address(rawValue: network.rawValue | ~mask.rawValue) }
    /// The address vmnet assigns to the host (the gateway guests see).
    public var hostAddress: IPv4Address { IPv4Address(rawValue: network.rawValue + 1) }

    public var description: String { "\(network)/\(prefixLength)" }

    public func contains(_ address: IPv4Address) -> Bool {
        address.rawValue & mask.rawValue == network.rawValue
    }

    public func overlaps(_ other: IPv4Subnet) -> Bool {
        contains(other.network) || other.contains(network)
    }

    /// Addresses that can be reserved for guests: everything except the network, host and broadcast
    /// addresses, starting a little above the host so the low range stays free for manual use.
    public var assignableAddresses: ClosedRange<UInt32> {
        let first = network.rawValue + min(10, (broadcast.rawValue - network.rawValue) / 2)
        let last = broadcast.rawValue - 1
        return first...max(first, last)
    }

    /// The lowest assignable address that isn't in `used`.
    public func firstAvailableAddress(excluding used: Set<IPv4Address>) -> IPv4Address? {
        for raw in assignableAddresses {
            let candidate = IPv4Address(rawValue: raw)
            if !used.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func maskValue(_ prefixLength: Int) -> UInt32 {
        prefixLength == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefixLength)
    }
}
