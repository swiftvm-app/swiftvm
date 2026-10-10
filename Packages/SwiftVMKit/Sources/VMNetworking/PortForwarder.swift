import Foundation
import Observation
import VMCore

/// Keeps the relays for forwarded ports in step with what the running machines ask for.
@MainActor
@Observable
public final class PortForwarder {
    /// How each forwarded port is doing, by the forward's identifier. A forward that isn't listed isn't
    /// being relayed, because its machine isn't running.
    public private(set) var statuses: [UUID: PortRelay.Status] = [:]

    private struct Entry {
        let relay: PortRelay
        /// Tells this relay's reports from those of an earlier relay for the same forward.
        let token: UUID
        let startedAt = Date()
    }

    @ObservationIgnored private var entries: [UUID: Entry] = [:]

    /// How long to wait before trying again to open a port that couldn't be opened. Whatever was holding
    /// it may have let go since.
    public var retryInterval: TimeInterval = 10

    public init() {}

    /// Makes the running relays match `routes`: starts what is new, stops what is gone and replaces what
    /// has changed. Call it again from time to time to retry ports that couldn't be opened.
    public func apply(_ routes: [UUID: PortRelay.Route]) {
        for (id, entry) in entries where routes[id] != entry.relay.route {
            entry.relay.stop()
            entries[id] = nil
        }
        for id in statuses.keys where routes[id] == nil {
            statuses[id] = nil
        }

        var owners: [PortClaim: UUID] = [:]
        for (id, entry) in entries {
            owners[PortClaim(entry.relay.route)] = id
        }
        // In a fixed order, so that of two forwards asking for the same port the same one wins every time.
        for (id, route) in routes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let entry = entries[id] {
                guard case .failed = statuses[id], Date().timeIntervalSince(entry.startedAt) >= retryInterval else { continue }
                entry.relay.stop()
                entries[id] = nil
            }
            let claim = PortClaim(route)
            if let owner = owners[claim], owner != id {
                statuses[id] = .failed("Port \(route.hostPort) is already forwarded to another virtual machine.")
                continue
            }
            owners[claim] = id
            start(route, for: id)
        }
    }

    /// Stops every relay.
    public func stopAll() {
        apply([:])
    }

    private func start(_ route: PortRelay.Route, for id: UUID) {
        let token = UUID()
        let relay = PortRelay(route: route) { [weak self] status in
            Task { @MainActor in self?.report(status, for: id, token: token) }
        }
        let entry = Entry(relay: relay, token: token)
        entries[id] = entry
        if statuses[id] == nil {
            statuses[id] = .starting
        }
        entry.relay.start()
    }

    private func report(_ status: PortRelay.Status, for id: UUID, token: UUID) {
        guard entries[id]?.token == token else { return }
        // While a port is being retried it keeps saying why it failed, rather than flicker.
        if status == .starting, case .failed = statuses[id] { return }
        statuses[id] = status
    }

    /// A port on this Mac, which only one relay can listen on.
    private struct PortClaim: Hashable {
        var transport: PortForward.TransportProtocol
        var port: UInt16

        init(_ route: PortRelay.Route) {
            transport = route.transport
            port = route.hostPort
        }
    }
}
