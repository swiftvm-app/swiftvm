import Foundation
import Testing
@testable import VMNetworking

/// Plain sockets on the loopback interface: a stand-in for a service in a guest, and a client for it.
private enum Loopback {
    static let address = IPv4Address("127.0.0.1")!

    static func socketAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = Loopback.address.inAddr
        return address
    }

    /// Binds a socket of `type` to a free port and returns both.
    static func bound(_ type: Int32) throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, type, 0)
        var address = socketAddress(port: 0)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard descriptor >= 0, result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &assigned) { pointer in
            _ = pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return (descriptor, UInt16(bigEndian: assigned.sin_port))
    }

    /// A port nothing is listening on right now.
    static func freePort(_ type: Int32 = SOCK_STREAM) throws -> UInt16 {
        let (descriptor, port) = try bound(type)
        close(descriptor)
        return port
    }

    /// Starts a TCP server that sends back whatever it receives and closes when the client has finished.
    /// Returns its port; it serves until the process ends.
    static func startEchoServer() throws -> UInt16 {
        let (descriptor, port) = try bound(SOCK_STREAM)
        listen(descriptor, 8)
        Thread.detachNewThread {
            while true {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = read(connection, &buffer, buffer.count)
                        guard count > 0 else { break }
                        var offset = 0
                        while offset < count {
                            let written = write(connection, Array(buffer[offset..<count]), count - offset)
                            guard written > 0 else { break }
                            offset += written
                        }
                    }
                    close(connection)
                }
            }
        }
        return port
    }

    /// Starts a UDP server that answers every datagram with the same bytes in upper case.
    static func startDatagramServer() throws -> UInt16 {
        let (descriptor, port) = try bound(SOCK_DGRAM)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var sender = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length) }
                }
                guard count >= 0 else { return }
                let reply = Array(String(decoding: buffer[0..<count], as: UTF8.self).uppercased().utf8)
                _ = withUnsafePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, reply, reply.count, 0, $0, length) }
                }
            }
        }
        return port
    }

    /// Connects to `port`, sends `payload`, says it is done and returns everything that comes back until the
    /// other side closes. `nil` if the connection is refused.
    static func exchange(_ payload: Data, port: UInt16) -> Data? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Writing to a connection the other side has dropped must fail, not end the test run.
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = socketAddress(port: port)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }

        // Write from another thread: a large payload comes back while it is still being sent.
        let writerIsDone = DispatchSemaphore(value: 0)
        let writer = Thread {
            payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    guard written > 0 else { break }
                    offset += written
                }
            }
            shutdown(descriptor, SHUT_WR)
            writerIsDone.signal()
        }
        writer.start()

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        // The descriptor is closed on return, and its number may go to another test's socket at once. The
        // writer must be finished with it by then.
        writerIsDone.wait()
        return received
    }
}

/// Collects what a relay reports, for tests to wait on.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PortRelay.Status.starting

    func set(_ status: PortRelay.Status) { lock.withLock { value = status } }
    var status: PortRelay.Status { lock.withLock { value } }

    /// Waits until the relay has either opened its port or given up.
    func settled() async -> PortRelay.Status {
        for _ in 0..<300 where status == .starting {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return status
    }
}

/// The tests that open sockets run one at a time. They find free ports by asking the system for one, and
/// two tests running side by side could be handed the same.
@Suite(.serialized) struct PortForwardingTests {
@Suite struct PortRelayTests {
    private func startRelay(_ route: PortRelay.Route) async -> (relay: PortRelay, status: PortRelay.Status) {
        let box = StatusBox()
        let relay = PortRelay(route: route) { box.set($0) }
        relay.start()
        return (relay, await box.settled())
    }

    @Test func passesAConversationThroughInBothDirections() async throws {
        let servicePort = try Loopback.startEchoServer()
        let hostPort = try Loopback.freePort()
        let (relay, status) = await startRelay(.init(hostPort: hostPort, guestAddress: Loopback.address, guestPort: servicePort))
        defer { relay.stop() }
        #expect(status == .listening)

        // The echo only ends once the service has seen the client finish, so getting an answer at all
        // shows that "I'm done" travels through the relay too.
        let reply = await Task.detached { Loopback.exchange(Data("hello, guest".utf8), port: hostPort) }.value
        #expect(reply == Data("hello, guest".utf8))
    }

    @Test func carriesMoreThanFitsInOneBuffer() async throws {
        let servicePort = try Loopback.startEchoServer()
        let hostPort = try Loopback.freePort()
        let (relay, status) = await startRelay(.init(hostPort: hostPort, guestAddress: Loopback.address, guestPort: servicePort))
        defer { relay.stop() }
        #expect(status == .listening)

        let payload = Data((0..<(6 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
        let reply = await Task.detached { Loopback.exchange(payload, port: hostPort) }.value
        #expect(reply?.count == payload.count)
        #expect(reply == payload)
    }

    @Test func servesSeveralClientsAtOnce() async throws {
        let servicePort = try Loopback.startEchoServer()
        let hostPort = try Loopback.freePort()
        let (relay, status) = await startRelay(.init(hostPort: hostPort, guestAddress: Loopback.address, guestPort: servicePort))
        defer { relay.stop() }
        #expect(status == .listening)

        let replies = await withTaskGroup(of: (Int, Data?).self) { group in
            for index in 0..<8 {
                group.addTask {
                    (index, Loopback.exchange(Data("client \(index)".utf8), port: hostPort))
                }
            }
            var replies: [Int: Data?] = [:]
            for await (index, reply) in group { replies[index] = reply }
            return replies
        }
        for index in 0..<8 {
            #expect(replies[index] == Data("client \(index)".utf8))
        }
    }

    @Test func aCallerIsNotLeftHangingWhenNothingAnswersInTheGuest() async throws {
        let hostPort = try Loopback.freePort()
        let deadPort = try Loopback.freePort()
        let (relay, status) = await startRelay(.init(hostPort: hostPort, guestAddress: Loopback.address, guestPort: deadPort))
        defer { relay.stop() }
        #expect(status == .listening)

        let started = ContinuousClock.now
        let reply = await Task.detached { Loopback.exchange(Data("anyone?".utf8), port: hostPort) }.value
        #expect(reply?.isEmpty ?? true)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func saysWhenThePortIsTaken() async throws {
        let (descriptor, port) = try Loopback.bound(SOCK_STREAM)
        defer { close(descriptor) }
        listen(descriptor, 1)

        let (relay, status) = await startRelay(.init(hostPort: port, guestAddress: Loopback.address, guestPort: 80))
        defer { relay.stop() }
        #expect(status == .failed("Port \(port) is already in use on this Mac."))
    }

    @Test func thePortIsFreeAgainAfterStopping() async throws {
        let servicePort = try Loopback.startEchoServer()
        let hostPort = try Loopback.freePort()
        let route = PortRelay.Route(hostPort: hostPort, guestAddress: Loopback.address, guestPort: servicePort)

        for round in 0..<3 {
            let (relay, status) = await startRelay(route)
            #expect(status == .listening)
            let reply = await Task.detached { Loopback.exchange(Data("round \(round)".utf8), port: hostPort) }.value
            #expect(reply == Data("round \(round)".utf8))
            relay.stop()
            // Stopping is asynchronous; wait until nothing accepts connections any more.
            for _ in 0..<200 {
                if await Task.detached(operation: { Loopback.exchange(Data(), port: hostPort) }).value == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test func relaysDatagrams() async throws {
        let servicePort = try Loopback.startDatagramServer()
        let hostPort = try Loopback.freePort(SOCK_DGRAM)
        let (relay, status) = await startRelay(.init(transport: .udp, hostPort: hostPort, guestAddress: Loopback.address, guestPort: servicePort))
        defer { relay.stop() }
        #expect(status == .listening)

        let reply = await Task.detached { () -> String? in
            let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            defer { close(descriptor) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = Loopback.socketAddress(port: hostPort)
            var answers: [String] = []
            for message in ["ping", "pong"] {
                let bytes = Array(message.utf8)
                _ = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = recv(descriptor, &buffer, buffer.count, 0)
                guard count > 0 else { return nil }
                answers.append(String(decoding: buffer[0..<count], as: UTF8.self))
            }
            return answers.joined(separator: " ")
        }.value
        #expect(reply == "PING PONG")
    }
}

@MainActor
@Suite struct PortForwarderTests {
    private func settle(_ forwarder: PortForwarder, _ ids: UUID...) async {
        for _ in 0..<300 where ids.contains(where: { forwarder.statuses[$0] == .starting }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func followsTheRoutesItIsGiven() async throws {
        let servicePort = try Loopback.startEchoServer()
        let forwarder = PortForwarder()
        defer { forwarder.stopAll() }
        let (first, second) = (UUID(), UUID())
        let firstPort = try Loopback.freePort()
        let secondPort = try Loopback.freePort()
        func route(_ port: UInt16) -> PortRelay.Route {
            .init(hostPort: port, guestAddress: Loopback.address, guestPort: servicePort)
        }

        forwarder.apply([first: route(firstPort)])
        await settle(forwarder, first)
        #expect(forwarder.statuses == [first: .listening])

        // A second forward comes, and the first moves to another port.
        let movedPort = try Loopback.freePort()
        forwarder.apply([first: route(movedPort), second: route(secondPort)])
        await settle(forwarder, first, second)
        #expect(forwarder.statuses == [first: .listening, second: .listening])
        #expect(await Task.detached { Loopback.exchange(Data("moved".utf8), port: movedPort) }.value == Data("moved".utf8))
        #expect(await Task.detached { Loopback.exchange(Data("second".utf8), port: secondPort) }.value == Data("second".utf8))

        forwarder.apply([second: route(secondPort)])
        #expect(forwarder.statuses == [second: .listening])
        forwarder.stopAll()
        #expect(forwarder.statuses.isEmpty)
    }

    @Test func twoForwardsCanNotShareAPort() async throws {
        let servicePort = try Loopback.startEchoServer()
        let forwarder = PortForwarder()
        defer { forwarder.stopAll() }
        let port = try Loopback.freePort()
        let route = PortRelay.Route(hostPort: port, guestAddress: Loopback.address, guestPort: servicePort)
        // The order is by identifier, so which one wins doesn't depend on chance.
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }

        forwarder.apply([ids[0]: route, ids[1]: route])
        await settle(forwarder, ids[0])
        #expect(forwarder.statuses[ids[0]] == .listening)
        #expect(forwarder.statuses[ids[1]] == .failed("Port \(port) is already forwarded to another virtual machine."))

        // Once the winner is gone, the other gets the port.
        forwarder.apply([ids[1]: route])
        for _ in 0..<300 where forwarder.statuses[ids[1]] != .listening {
            forwarder.apply([ids[1]: route])
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(forwarder.statuses == [ids[1]: .listening])
    }

    @Test func triesAgainWhenAPortBecomesFree() async throws {
        let (descriptor, port) = try Loopback.bound(SOCK_STREAM)
        listen(descriptor, 1)
        let forwarder = PortForwarder()
        forwarder.retryInterval = 0.05
        defer { forwarder.stopAll() }
        let id = UUID()
        let route = PortRelay.Route(hostPort: port, guestAddress: Loopback.address, guestPort: 80)

        forwarder.apply([id: route])
        await settle(forwarder, id)
        #expect(forwarder.statuses[id] == .failed("Port \(port) is already in use on this Mac."))

        close(descriptor)
        for _ in 0..<300 where forwarder.statuses[id] != .listening {
            forwarder.apply([id: route])
            // While it retries it keeps saying what was wrong, rather than flicker through "starting".
            #expect(forwarder.statuses[id] != .starting)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(forwarder.statuses[id] == .listening)
    }
}
}
