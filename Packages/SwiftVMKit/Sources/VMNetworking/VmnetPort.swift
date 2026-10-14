import Foundation
import VMCore
import vmnet

/// A machine's place on a vmnet network, for an engine that doesn't attach to vmnet by itself: QEMU.
///
/// The app starts an interface on the network and passes frames between it and a socket whose other end
/// the engine has, one frame to a datagram. So a QEMU guest is on the same network as the others: its
/// address is reserved for its MAC address, and forwarded ports and SSH reach it the same way.
public final class VmnetPort: @unchecked Sendable {
    private let interface: interface_ref
    private let peer: Int32
    private let queue = DispatchQueue(label: "app.swiftvm.vmnet-port")
    private let lock = NSLock()
    private var isClosed = false
    /// The thread that reads from the engine closes the socket once the engine is gone. Whoever uses
    /// it checks first, with the lock held: its number may be another's after.
    private var isPeerClosed = false
    private let maximumPacketSize: Int

    /// The most frames a socket holds for its reader. macOS has room for two by default, which drops
    /// frames whenever a guest sends a burst.
    private static let socketBuffer: Int32 = 2 << 20
    /// The largest frame either end sends: Ethernet's, with some to spare.
    private static let largestFrame = 9216

    private init(interface: interface_ref, peer: Int32, maximumPacketSize: Int) {
        self.interface = interface
        self.peer = peer
        self.maximumPacketSize = maximumPacketSize
    }

    /// Makes the pair of sockets a port and its engine talk over: the first end is for ``open(on:peer:)``,
    /// the second for the engine. Both are set up to hold bursts of frames.
    public static func makeSocketPair() throws -> (port: Int32, engine: Int32) {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &ends) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for end in ends {
            var receive = socketBuffer
            var send = Int32(largestFrame * 2)
            setsockopt(end, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(end, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(end, F_SETNOSIGPIPE, 1)
        }
        return (ends[0], ends[1])
    }

    /// Starts an interface on `network` and passes frames between it and `peer`, which the port takes
    /// over. The guest keeps its own MAC address, so that its reservation applies.
    public static func open(on network: VmnetNetwork, peer: Int32) async throws -> VmnetPort {
        let description = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(description, vmnet_allocate_mac_address_key, false)
        let queue = DispatchQueue(label: "app.swiftvm.vmnet-port.start")
        let outcome = StartOutcome()
        var started: interface_ref?
        let (status, packetSize): (vmnet_return_t, Int) = await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            started = vmnet_interface_start_with_network(network.reference, description, queue) { status, parameters in
                let size = parameters.map { Int(xpc_dictionary_get_uint64($0, vmnet_max_packet_size_key)) } ?? 0
                outcome.finish(status, size > 0 ? size : 1514)
            }
            if started == nil {
                outcome.finish(.VMNET_FAILURE, 0)
            }
        }
        guard status == .VMNET_SUCCESS, let interface = started else {
            Darwin.close(peer)
            throw VmnetPortError.couldNotStart(Int(status.rawValue))
        }
        let port = VmnetPort(interface: interface, peer: peer, maximumPacketSize: packetSize)
        port.start()
        return port
    }

    /// Stops passing frames and takes the interface off the network. Waits until vmnet has let go of it.
    public func close() async {
        let shouldClose = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        // The thread that reads from the engine is out of its wait once its socket is shut.
        lock.withLock {
            if !isPeerClosed { _ = shutdown(peer, SHUT_RDWR) }
        }
        vmnet_interface_set_event_callback(interface, [], nil, nil)
        // A callback that is under way when it is taken away finishes first.
        queue.sync {}
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let status = vmnet_stop_interface(interface, queue) { _ in continuation.resume() }
            if status != .VMNET_SUCCESS {
                continuation.resume()
            }
        }
    }

    private var closed: Bool { lock.withLock { isClosed } }

    private func start() {
        // From the network to the guest: whatever vmnet has, whenever it says it has some.
        vmnet_interface_set_event_callback(interface, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, _ in
            self?.forwardFromNetwork()
        }
        // From the guest to the network: one frame to a datagram, on a thread that waits for them.
        let thread = Thread { [self] in forwardFromGuest() }
        thread.name = "app.swiftvm.vmnet-port"
        thread.start()
    }

    private func forwardFromNetwork() {
        let size = max(maximumPacketSize, Self.largestFrame)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while !closed {
            var vector = iovec(iov_base: buffer, iov_len: size)
            var count: Int32 = 1
            let status = withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var packet = vmpktdesc(vm_pkt_size: size, vm_pkt_iov: vectorPointer, vm_pkt_iovcnt: 1, vm_flags: 0)
                let status = vmnet_read(interface, &packet, &count)
                if status == .VMNET_SUCCESS, count == 1 {
                    // A guest that doesn't keep up loses the frame, as it would on a wire.
                    lock.withLock {
                        if !isPeerClosed { _ = Darwin.send(peer, buffer, packet.vm_pkt_size, MSG_DONTWAIT) }
                    }
                }
                return status
            }
            guard status == .VMNET_SUCCESS, count == 1 else { return }
        }
    }

    private func forwardFromGuest() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.largestFrame, alignment: 16)
        defer {
            buffer.deallocate()
            lock.withLock {
                isPeerClosed = true
                Darwin.close(peer)
            }
        }
        while !closed {
            let received = recv(peer, buffer, Self.largestFrame, 0)
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { return }
            var vector = iovec(iov_base: buffer, iov_len: received)
            var count: Int32 = 1
            withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var packet = vmpktdesc(vm_pkt_size: received, vm_pkt_iov: vectorPointer, vm_pkt_iovcnt: 1, vm_flags: 0)
                _ = vmnet_write(interface, &packet, &count)
            }
        }
    }
}

/// How starting an interface went, said once: by its completion, or by the start itself when it
/// returns no interface at all.
private final class StartOutcome: @unchecked Sendable {
    var continuation: CheckedContinuation<(vmnet_return_t, Int), Never>?
    private let lock = NSLock()

    func finish(_ status: vmnet_return_t, _ packetSize: Int) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: (status, packetSize))
    }
}

public enum VmnetPortError: Error, LocalizedError, Equatable {
    case couldNotStart(Int)

    public var errorDescription: String? {
        switch self {
        case .couldNotStart(let code):
            "The virtual machine couldn't join the virtual network (vmnet error \(code))."
        }
    }
}
