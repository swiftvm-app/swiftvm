/// The only mechanism a single-request shutdown may use. There is no fallback.
public enum ShutdownMechanism: String, Sendable {
    case agent
    case powerButton = "power-button"
}

/// Request delivery and observed lifecycle state are separate facts. Neither proves resource release.
public struct SingleShutdownResult: Sendable, Equatable {
    public enum Delivery: String, Sendable {
        case accepted, rejected, unknown, unsupported, alreadyStopped = "already-stopped", busy
    }

    public let delivery: Delivery
    public let state: VMState
    public let timedOut: Bool
    public let requestError: String?

    public init(delivery: Delivery, state: VMState, timedOut: Bool = false, requestError: String? = nil) {
        self.delivery = delivery
        self.state = state
        self.timedOut = timedOut
        self.requestError = requestError
    }
}
