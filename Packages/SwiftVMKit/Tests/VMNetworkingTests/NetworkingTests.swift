import Foundation
import Testing
import VMCore
@testable import VMNetworking

@Suite struct IPv4Tests {
    @Test func parsesAddresses() {
        #expect(IPv4Address("192.168.230.10")?.rawValue == 0xC0A8_E60A)
        #expect(IPv4Address("192.168.230.10")?.description == "192.168.230.10")
        #expect(IPv4Address("192.168.230") == nil)
        #expect(IPv4Address("192.168.230.256") == nil)
        #expect(IPv4Address("192.168.230.x") == nil)
    }

    @Test func subnetMath() throws {
        let subnet = try #require(IPv4Subnet("192.168.230.77/24"))
        #expect(subnet.description == "192.168.230.0/24")
        #expect(subnet.mask.description == "255.255.255.0")
        #expect(subnet.hostAddress.description == "192.168.230.1")
        #expect(subnet.broadcast.description == "192.168.230.255")
        #expect(subnet.contains(IPv4Address("192.168.230.200")!))
        #expect(!subnet.contains(IPv4Address("192.168.231.1")!))
        #expect(subnet.overlaps(IPv4Subnet("192.168.0.0/16")!))
        #expect(!subnet.overlaps(IPv4Subnet("10.0.0.0/8")!))
    }

    @Test func allocatesFirstFreeAddress() throws {
        let subnet = try #require(IPv4Subnet("192.168.230.0/24"))
        #expect(subnet.firstAvailableAddress(excluding: [])?.description == "192.168.230.10")
        let used: Set<IPv4Address> = [IPv4Address("192.168.230.10")!, IPv4Address("192.168.230.11")!]
        #expect(subnet.firstAvailableAddress(excluding: used)?.description == "192.168.230.12")
    }

    @Test func picksSubnetAwayFromHostNetworks() throws {
        let inUse = [IPv4Subnet("192.168.230.0/24")!, IPv4Subnet("192.168.231.0/24")!]
        #expect(SubnetPicker.pick(avoiding: inUse)?.description == "192.168.232.0/24")
        // A host on a /16 that swallows every 192.168.x.x candidate pushes the pick to 172.16/12.
        #expect(SubnetPicker.pick(avoiding: [IPv4Subnet("192.168.0.0/16")!])?.description == "172.16.230.0/24")
    }

    @Test func remapsAddressesBetweenSubnets() throws {
        let old = try #require(IPv4Subnet("192.168.230.0/24"))
        let new = try #require(IPv4Subnet("172.16.230.0/24"))
        let moved = NetworkManager.remap(IPv4Address("192.168.230.42")!, from: old, to: new)
        #expect(moved.description == "172.16.230.42")
    }
}

@Suite struct DHCPLeaseTests {
    static let sample = """
    {
    \tname=ubuntu-26-04
    \tip_address=192.168.64.5
    \thw_address=1,2:1a:2b:3:4d:5e
    \tidentifier=1,2:1a:2b:3:4d:5e
    \tlease=0x6718c1f0
    }
    {
    \tname=ubuntu-26-04
    \tip_address=192.168.64.9
    \thw_address=1,2:1a:2b:3:4d:5e
    \tidentifier=1,2:1a:2b:3:4d:5e
    \tlease=0x6719c1f0
    }
    {
    \tip_address=192.168.64.7
    \thw_address=1,aa:bb:cc:dd:ee:ff
    \tlease=0x6718c1f0
    }
    {
    \tname=debian-13
    \tip_address=192.168.64.12
    \thw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:2d:c7:41:4c:10:1c:77:7d
    \tidentifier=ff,f1:f5:dd:7f:0:2:0:0:ab:11:2d:c7:41:4c:10:1c:77:7d
    \tlease=0x6719c1f0
    }
    """

    @Test func parsesLeaseRecords() {
        let leases = DHCPLeases.parse(Self.sample)
        #expect(leases.count == 4)
        #expect(leases[0].name == "ubuntu-26-04")
        #expect(leases[0].macAddress == MACAddress("02:1a:2b:03:4d:5e"))
        #expect(leases[2].name == nil)
        // A client that sends a generated identifier has no MAC in its record.
        #expect(leases[3].macAddress == nil)
        #expect(leases[3].address.description == "192.168.64.12")
    }

    @Test func listsCurrentLeasesNewestFirst() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "leases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.sample.write(to: url, atomically: true, encoding: .utf8)
        let subnet = try #require(IPv4Subnet("192.168.64.0/24"))
        let guestMAC = try #require(MACAddress("02:1a:2b:03:4d:5e"))
        let unknownMAC = try #require(MACAddress("02:00:00:00:00:01"))
        // Between the two expiry times of the guest's leases: only the newer one is still valid.
        let betweenExpiries = Date(timeIntervalSince1970: TimeInterval(0x6719_0000))
        let beforeBoth = Date(timeIntervalSince1970: TimeInterval(0x6718_0000))

        func addresses(_ mac: MACAddress, _ name: String?, _ now: Date, _ net: IPv4Subnet = subnet) -> [String] {
            DHCPLeases.currentAddresses(macAddress: mac, hostName: name, in: net, now: now, leasesURL: url).map(\.description)
        }
        #expect(addresses(guestMAC, nil, betweenExpiries) == ["192.168.64.9"])
        #expect(addresses(guestMAC, nil, beforeBoth) == ["192.168.64.9", "192.168.64.5"])
        // A client identified only by host name is found through the name, alongside MAC matches.
        #expect(addresses(unknownMAC, "debian-13", betweenExpiries) == ["192.168.64.12"])
        #expect(addresses(guestMAC, "debian-13", betweenExpiries) == ["192.168.64.9", "192.168.64.12"])
        // Expired leases and leases from other networks don't count.
        #expect(addresses(guestMAC, "debian-13", Date(timeIntervalSince1970: TimeInterval(0x671A_0000))).isEmpty)
        #expect(addresses(guestMAC, "debian-13", betweenExpiries, try #require(IPv4Subnet("192.168.230.0/24"))).isEmpty)
    }
}

@Suite struct ReachabilityTests {
    @Test func detectsListeningAndClosedPorts() async throws {
        // Listen on an ephemeral loopback port.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        let loopback = try #require(IPv4Address("127.0.0.1"))

        #expect(await Reachability.canConnect(to: loopback, port: port))
        close(listener)
        #expect(await Reachability.canConnect(to: loopback, port: port) == false)
    }
}

