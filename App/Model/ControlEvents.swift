import Foundation
import Observation
import VMControl

/// What `watch` compares to tell what has changed: each machine as a row of the list, with its guest
/// tools, and each creation.
struct WatchedWorld: Equatable {
    struct Machine: Equatable {
        var summary: MachineSummary
        var guestTools: MachineDetails.GuestTools?
        var setup: MachineDetails.Setup?
    }

    /// In the library's order.
    var machines: [Machine] = []
    var creations: [CreationSummary] = []

    /// What happened between `old` and `new`, as `watch` tells it: creations first, so that a creation
    /// that is over comes before the machine it made, and then the machines.
    static func events(from old: WatchedWorld, to new: WatchedWorld) -> [ControlEvent] {
        var events: [ControlEvent] = []
        let oldCreations = Dictionary(old.creations.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let newNames = Set(new.creations.map(\.name))
        for creation in new.creations where oldCreations[creation.name] != creation {
            events.append(ControlEvent(.creation, creation: creation))
        }
        for creation in old.creations where !newNames.contains(creation.name) {
            events.append(ControlEvent(.creationEnded, creation: creation))
        }
        let oldMachines = Dictionary(old.machines.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.machines.map(\.summary.id))
        for machine in new.machines {
            guard let before = oldMachines[machine.summary.id] else {
                events.append(ControlEvent(.machineAdded, machine: machine.summary))
                continue
            }
            let (was, now) = (before.summary, machine.summary)
            if was.name != now.name || was.state != now.state || was.address != now.address {
                events.append(ControlEvent(.machineChanged, machine: now))
            }
            if before.guestTools != machine.guestTools || before.setup != machine.setup {
                events.append(ControlEvent(.guestTools, machine: now, guestTools: machine.guestTools, setup: machine.setup))
            }
        }
        for machine in old.machines where !newIDs.contains(machine.summary.id) {
            events.append(ControlEvent(.machineRemoved, machine: machine.summary))
        }
        return events
    }
}

/// The `watch` connections, and what tells them of changes while there are any.
final class ControlEventHub {
    private var writers: [UUID: ControlEventWriter] = [:]
    private var following: Task<Void, Never>?

    /// Starts telling `writer` what changes in `world`, until it is removed.
    func add(_ writer: ControlEventWriter, world: @escaping @MainActor () -> WatchedWorld) -> UUID {
        let id = UUID()
        writers[id] = writer
        if following == nil {
            // What changes from here on is told: taken now, before the connection hears of anything.
            let baseline = world()
            following = Task { [weak self] in
                var last = baseline
                for await now in Observations({ world() }) {
                    guard let self, !Task.isCancelled else { return }
                    let events = WatchedWorld.events(from: last, to: now)
                    last = now
                    let lines = events.compactMap { try? JSONEncoder().encode($0) }
                    for writer in self.writers.values {
                        lines.forEach(writer.write)
                    }
                }
            }
        }
        return id
    }

    func remove(_ id: UUID) {
        writers[id] = nil
        if writers.isEmpty {
            following?.cancel()
            following = nil
        }
    }
}

/// Writes events to one `watch` connection without holding up the app: they queue up behind a slow
/// reader, and one that has stopped reading is let go once too much has piled up, as
/// `ConsoleClientWriter` does.
nonisolated final class ControlEventWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "SwiftVM watch connection")
    private let lock = NSLock()
    private var backlog = 0
    private var isFinished = false
    private var waiting: CheckedContinuation<Void, Never>?

    static let backlogLimit = 4 << 20

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Writes `line` and a newline, behind what is already on its way.
    func write(_ line: Data) {
        let size = line.count + 1
        let isAccepted = lock.withLock {
            guard !isFinished else { return false }
            backlog += size
            return backlog <= Self.backlogLimit
        }
        guard isAccepted else {
            finish()
            return
        }
        queue.async { [self] in
            defer { lock.withLock { backlog -= size } }
            guard !lock.withLock({ isFinished }) else { return }
            do {
                try ControlSocket.writeLine(line, to: descriptor)
            } catch {
                finish()
            }
        }
    }

    /// Lets the connection go: the reader has hung up, fallen too far behind, or can't be written to.
    func finish() {
        let resumed = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isFinished = true
            defer { waiting = nil }
            return waiting
        }
        resumed?.resume()
    }

    /// Returns once the connection is let go, and nothing more will be written to it.
    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let finishedAlready = lock.withLock {
                if isFinished { return true }
                waiting = continuation
                return false
            }
            if finishedAlready { continuation.resume() }
        }
        queue.sync {}
    }
}
