import Foundation

/// An Ethernet MAC address.
public struct MACAddress: Sendable, Hashable, CustomStringConvertible {
    public let octets: [UInt8]

    public init?(octets: [UInt8]) {
        guard octets.count == 6 else { return nil }
        self.octets = octets
    }

    /// Parses `02:1a:2b:3c:4d:5e`. Octets may omit a leading zero (`2:1a:…`), as in DHCP lease files.
    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count), let value = UInt8(part, radix: 16) else { return nil }
            octets.append(value)
        }
        self.octets = octets
    }

    /// A random, locally administered, unicast address.
    public static func random() -> MACAddress {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random(using generator: inout some RandomNumberGenerator) -> MACAddress {
        var octets = (0..<6).map { _ in UInt8.random(in: 0...255, using: &generator) }
        // Set the locally-administered bit, clear the multicast bit.
        octets[0] = (octets[0] | 0x02) & 0xFE
        return MACAddress(octets: octets)!
    }

    public var description: String {
        octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
