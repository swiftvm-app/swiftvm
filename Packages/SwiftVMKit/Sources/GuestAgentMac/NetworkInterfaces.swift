import Foundation
import GuestChannel

/// The system's network cards and the addresses they hold.
enum NetworkInterfaces {
    /// The network cards that hold an address the Mac could use, in the system's order. Addresses that
    /// only work on the link itself are left out, and with them the cards that hold nothing else.
    static func current(limit: Int = 64) -> [GuestInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var names: [String] = []
        var hardwareAddresses: [String: String] = [:]
        var addresses: [String: [String]] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, Int32(entry.pointee.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                if let hardwareAddress = hardwareAddress(of: address) {
                    names.append(name)
                    hardwareAddresses[name] = hardwareAddress
                }
            case AF_INET:
                let internet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let value = UInt32(bigEndian: internet.s_addr)
                // 169.254.0.0/16 is what a card gives itself when nobody hands it an address.
                guard value >> 16 != 0xA9FE, let text = withUnsafeBytes(of: internet, { text(of: $0, family: AF_INET) }) else { continue }
                addresses[name, default: []].append(text)
            case AF_INET6:
                let internet = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: internet) { Array($0.prefix(2)) }
                // fe80::/10
                guard !(bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80),
                      let text = withUnsafeBytes(of: internet, { text(of: $0, family: AF_INET6) })
                else { continue }
                addresses[name, default: []].append(text)
            default:
                continue
            }
        }
        let interfaces = names.compactMap { name -> GuestInterface? in
            guard let hardwareAddress = hardwareAddresses[name], let held = addresses[name], !held.isEmpty else { return nil }
            return GuestInterface(name: name, mac: hardwareAddress, addresses: held)
        }
        return Array(interfaces.prefix(limit))
    }

    /// The hardware address in a link-level address, if it is an Ethernet card's.
    private static func hardwareAddress(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
            guard link.pointee.sdl_type == UInt8(IFT_ETHER), link.pointee.sdl_alen == 6,
                  let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)
            else { return nil }
            // The card's name comes first in the data, the address right behind it.
            let bytes = UnsafeRawPointer(link).advanced(by: dataOffset + Int(link.pointee.sdl_nlen))
            return (0..<6).map { String(format: "%02x", bytes.load(fromByteOffset: $0, as: UInt8.self)) }.joined(separator: ":")
        }
    }

    /// An address the way it is written, from its bytes.
    private static func text(of address: UnsafeRawBufferPointer, family: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return buffer.withUnsafeMutableBytes { written -> String? in
            let characters = written.baseAddress!.assumingMemoryBound(to: CChar.self)
            guard inet_ntop(family, address.baseAddress, characters, socklen_t(written.count)) != nil else { return nil }
            return String(decoding: written.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
