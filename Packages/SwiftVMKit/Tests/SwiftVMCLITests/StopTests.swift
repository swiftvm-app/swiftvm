import Testing
import VMControl
@testable import SwiftVMCLI

@Suite struct StopTests {
    @Test func ordinaryStopKeepsItsExistingCommand() throws {
        #expect(try Stop.parse(["desk"]) == ControlRequest(command: .stop, machine: "desk"))
    }

    @Test func theOptInUsesADistinctWireCommandAndOneMechanism() throws {
        #expect(try Stop.parse(["desk", "--once", "--via", "agent"]) ==
                ControlRequest(command: .shutdownOnce, machine: "desk", timeout: 30, shutdownMechanism: "agent"))
        #expect(try Stop.parse(["desk", "--timeout", "0.5", "--via", "power-button", "--once"]) ==
                ControlRequest(command: .shutdownOnce, machine: "desk", timeout: 0.5, shutdownMechanism: "power-button"))
    }

    @Test(arguments: [
        [String](), ["desk", "--once"], ["desk", "--via", "agent"], ["desk", "--timeout", "1"],
        ["desk", "--once", "--via", "agent", "--via", "power-button"],
        ["desk", "--once", "--once", "--via", "agent"], ["desk", "--once", "--via", "other"],
        ["desk", "--once", "--via", "agent", "--timeout", "nan"],
        ["desk", "--once", "--via", "agent", "--timeout", "-1"],
        ["desk", "--once", "--via", "agent", "--timeout", "1e300"],
    ])
    func ambiguousOrUnboundedRequestsAreRejected(arguments: [String]) {
        #expect(throws: Stop.ParseError.self) { try Stop.parse(arguments) }
    }

    @Test func processStatusReportsObservationRatherThanAssumingAcknowledgmentMeansStopped() {
        #expect(Stop.status(for: .init(delivery: "accepted", observedState: "running", timedOut: true)) == 124)
        #expect(Stop.status(for: .init(delivery: "unknown", observedState: "stopped", timedOut: false)) == 0)
        #expect(Stop.status(for: .init(delivery: "unsupported", observedState: "running", timedOut: false)) == 1)
    }
}
