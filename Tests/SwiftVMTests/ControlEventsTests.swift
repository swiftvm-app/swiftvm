import Foundation
import Testing
import VMControl

@testable import SwiftVM

/// What `watch` tells of a change: compared row by row, as the list shows it.
@MainActor @Suite struct ControlEventsTests {
    private let id = UUID()

    private func machine(state: String = "stopped", address: String? = nil, tools: String? = nil) -> WatchedWorld.Machine {
        WatchedWorld.Machine(
            summary: MachineSummary(
                id: id, name: "desk", state: state, system: "Ubuntu 26.04", address: address, sshAlias: "desk",
                cpuCount: 4, memorySize: 1, diskAllocated: 1, diskCapacity: 1
            ),
            guestTools: tools.map { MachineDetails.GuestTools(version: $0, kernel: nil) },
            setup: nil
        )
    }

    private func creation(_ status: String, fraction: Double? = nil) -> CreationSummary {
        CreationSummary(name: "desk", system: "ubuntu-26.04", status: status, fraction: fraction, error: nil)
    }

    @Test func aCreationThatEndsComesBeforeTheMachineItMade() {
        let creating = WatchedWorld(creations: [creation("Downloading", fraction: 0.5)])
        let made = WatchedWorld(machines: [machine()])
        let events = WatchedWorld.events(from: creating, to: made)
        #expect(events.map(\.event) == [.creationEnded, .machineAdded])
        #expect(events[0].creation?.status == "Downloading")
    }

    @Test func eachChangeIsToldOnceAndNothingElse() {
        let stopped = WatchedWorld(machines: [machine()])
        #expect(WatchedWorld.events(from: stopped, to: stopped).isEmpty)
        // Only the disk filling up: not something to tell.
        var grown = stopped
        grown.machines[0].summary.diskAllocated = 2
        #expect(WatchedWorld.events(from: stopped, to: grown).isEmpty)

        let running = WatchedWorld(machines: [machine(state: "running", address: "192.168.64.5", tools: "1.4.0")])
        let events = WatchedWorld.events(from: stopped, to: running)
        #expect(events.map(\.event) == [.machineChanged, .guestTools])
        #expect(events[0].machine?.address == "192.168.64.5")
        #expect(events[1].guestTools?.version == "1.4.0")

        let progressed = WatchedWorld(creations: [creation("Downloading", fraction: 0.6)])
        #expect(WatchedWorld.events(from: WatchedWorld(creations: [creation("Downloading", fraction: 0.5)]), to: progressed).map(\.event) == [.creation])
        #expect(WatchedWorld.events(from: running, to: WatchedWorld()).map(\.event) == [.machineRemoved])
    }
}
