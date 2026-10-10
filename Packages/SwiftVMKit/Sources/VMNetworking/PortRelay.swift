import Foundation
import Network
import VMCore

/// Relays a port on this Mac to a port in a guest.
///
/// A guest can be reached at its own address without this. A relay is for what insists on `localhost`
/// (a browser's rules for secure pages, a sign-in that redirects there) and for letting other devices on
/// the network in.
public final class PortRelay: @unchecked Sendable {
    public struct Route: Sendable, Hashable {
        public var transport: PortForward.TransportProtocol
        public var hostPort: UInt16
        public var guestAddress: IPv4Address
        public var guestPort: UInt16
        /// Listen on every interface rather than on the loopback interface only.
        public var allowsOtherDevices: Bool

        public init(
            transport: PortForward.TransportProtocol = .tcp, hostPort: UInt16, guestAddress: IPv4Address, guestPort: UInt16,
            allowsOtherDevices: Bool = false
        ) {
            self.transport = transport
            self.hostPort = hostPort
            self.guestAddress = guestAddress
            self.guestPort = guestPort
            self.allowsOtherDevices = allowsOtherDevices
        }
    }

    public enum Status: Sendable, Hashable {
        case starting
        case listening
        /// The port couldn't be opened; the text says why.
        case failed(String)
    }

    public let route: Route
    private let onStatusChange: @Sendable (Status) -> Void
    private let queue: DispatchQueue
    // Everything below is only touched on `queue`.
    private var listener: NWListener?
    private var flows: [ObjectIdentifier: Flow] = [:]
    private var sweepTimer: DispatchSourceTimer?
    private var isStopped = false
    private var attempts = 0

    /// A port that another relay has just let go of takes a moment to become free, so "in use" is only
    /// believed after this many tries, a tenth of a second apart.
    static let maximumAttempts = 10

    /// How long a UDP conversation is kept without traffic. UDP has no way of saying it is over.
    static let datagramIdleTimeout: TimeInterval = 60

    public init(route: Route, onStatusChange: @escaping @Sendable (Status) -> Void) {
        self.route = route
        self.onStatusChange = onStatusChange
        self.queue = DispatchQueue(label: "SwiftVM port relay \(route.transport.rawValue) \(route.hostPort)")
    }

    public func start() {
        queue.async { self.startListening() }
    }

    /// Closes the port and every connection going through it.
    public func stop() {
        queue.async {
            self.isStopped = true
            self.listener?.cancel()
            self.listener = nil
            self.sweepTimer?.cancel()
            self.sweepTimer = nil
            self.flows.values.forEach { $0.cancel() }
            self.flows.removeAll()
        }
    }

    /// How long the guest gets to accept a connection. A guest that is paused or has lost its network
    /// doesn't refuse, it just doesn't answer, and the caller shouldn't wait out the system's long default.
    static let guestConnectionTimeout = 10

    /// The transport settings for either side of the relay.
    private var transportParameters: NWParameters {
        guard route.transport == .tcp else { return .udp }
        let options = NWProtocolTCP.Options()
        // Pass every piece on as it comes; holding small pieces back makes a shell through the relay sluggish.
        options.noDelay = true
        options.connectionTimeout = Self.guestConnectionTimeout
        return NWParameters(tls: nil, tcp: options)
    }

    private var listenerParameters: NWParameters {
        let parameters = transportParameters
        // Without this the port stays unusable for a while after a relay with open connections is stopped.
        parameters.allowLocalEndpointReuse = true
        if !route.allowsOtherDevices {
            parameters.requiredInterfaceType = .loopback
        }
        return parameters
    }

    private func startListening() {
        guard !isStopped else { return }
        if attempts == 0 {
            onStatusChange(.starting)
        }
        attempts += 1
        guard let port = NWEndpoint.Port(rawValue: route.hostPort) else {
            onStatusChange(.failed("\(route.hostPort) isn't a port number."))
            return
        }
        do {
            let listener = try NWListener(using: listenerParameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    onStatusChange(.listening)
                    if route.transport == .udp {
                        startSweeping()
                    }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    self.listener = nil
                    fail(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            fail(error)
        }
    }

    /// Reports that the port couldn't be opened, unless it is worth another try.
    private func fail(_ error: any Error) {
        if Self.isAddressInUse(error), attempts < Self.maximumAttempts {
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.startListening()
            }
        } else {
            onStatusChange(.failed(Self.describe(error, port: route.hostPort)))
        }
    }

    static func isAddressInUse(_ error: any Error) -> Bool {
        if let error = error as? NWError, case .posix(.EADDRINUSE) = error {
            return true
        }
        return false
    }

    static func describe(_ error: any Error, port: UInt16) -> String {
        if let error = error as? NWError, case .posix(let code) = error {
            switch code {
            case .EADDRINUSE: return "Port \(port) is already in use on this Mac."
            case .EACCES, .EPERM: return "This Mac doesn't allow apps to open port \(port)."
            default: break
            }
        }
        return error.localizedDescription
    }

    private func accept(_ inbound: NWConnection) {
        guard let port = NWEndpoint.Port(rawValue: route.guestPort) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: NWEndpoint.Host(route.guestAddress.description), port: port, using: transportParameters)
        let flow = Flow(inbound: inbound, outbound: outbound, isStream: route.transport == .tcp, queue: queue)
        let key = ObjectIdentifier(flow)
        flows[key] = flow
        flow.onEnd = { [weak self] in self?.flows[key] = nil }
        flow.start()
    }

    private func startSweeping() {
        guard sweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(-Self.datagramIdleTimeout)
            for flow in flows.values where flow.lastActivity < deadline {
                flow.cancel()
            }
        }
        timer.resume()
        sweepTimer = timer
    }
}

/// One connection through a relay: what arrives on either side is passed on to the other.
///
/// Only ever touched on the relay's queue, which is also where its connections report.
private final class Flow: @unchecked Sendable {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let isStream: Bool
    private let queue: DispatchQueue
    /// Connections that have been established at some point.
    private var established: Set<ObjectIdentifier> = []
    /// Directions of a stream that haven't reached their end yet.
    private var openDirections = 2
    private var isCancelled = false
    private(set) var lastActivity = Date()
    var onEnd: (() -> Void)?

    init(inbound: NWConnection, outbound: NWConnection, isStream: Bool, queue: DispatchQueue) {
        self.inbound = inbound
        self.outbound = outbound
        self.isStream = isStream
        self.queue = queue
    }

    func start() {
        for connection in [inbound, outbound] {
            let id = ObjectIdentifier(connection)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    established.insert(id)
                case .waiting, .failed:
                    // Nothing answers on that port in the guest: don't leave the caller hanging.
                    //
                    // Once a connection is up, its state is no longer a reason to stop. A connection that
                    // both sides have finished with reports "failed" while its last bytes are still
                    // waiting to be read, and acting on that would cut them off. The end of a
                    // conversation is found by reading it to the end.
                    if !established.contains(id) {
                        cancel()
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        inbound.cancel()
        outbound.cancel()
        onEnd?()
        onEnd = nil
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        let handler: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, isComplete, error in
            guard let self, !isCancelled else { return }
            lastActivity = Date()
            // Every datagram is complete in itself; only a stream ends by being complete.
            let hasEnded = error != nil || (isStream && isComplete)
            guard let data, !data.isEmpty else {
                if hasEnded {
                    end(towards: destination)
                } else {
                    pump(from: source, to: destination)
                }
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, !isCancelled else { return }
                if sendError != nil {
                    cancel()
                } else if hasEnded {
                    end(towards: destination)
                } else {
                    pump(from: source, to: destination)
                }
            })
        }
        if isStream {
            source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024, completion: handler)
        } else {
            source.receiveMessage(completion: handler)
        }
    }

    /// One side has nothing more to say. A stream passes that on and ends once both sides have finished,
    /// so that an answer still on its way gets through.
    private func end(towards destination: NWConnection) {
        guard isStream else {
            cancel()
            return
        }
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self, !isCancelled else { return }
            openDirections -= 1
            if openDirections == 0 {
                cancel()
            }
        })
    }
}
