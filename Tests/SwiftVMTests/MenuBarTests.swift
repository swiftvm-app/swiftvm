import AppKit
import Foundation
import SwiftUI
import Testing
import VMCore
@testable import SwiftVM

/// A guest that starts, pauses and stops at once, and does nothing else.
@MainActor
private final class StubBackend: VMBackend {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)?
    let displayView = NSView()
    let canRequestStop = true
    /// What the guest's agent says once the machine has reached it, a line to each. Empty for a guest
    /// without one.
    var agentLines: [String] = []
    /// The guest's end of the lines to its agent, kept open for as long as the guest is.
    private var agentEnds: [FileHandle] = []

    func start(options: VMStartOptions) async throws {}
    func requestStop() throws {}
    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func saveState(to url: URL) async throws { try Data("state".utf8).write(to: url) }
    func setNetworkInterface(_ id: UUID, connected: Bool) throws {}
    func setSharedFolders(_ folders: [SharedFolder]) throws {}
    func attachRemovableImage(_ image: RemovableImage) async throws {}
    func detachRemovableImage(_ id: UUID) async throws {}
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool) {}
    func connectToGuest(port: UInt32) async throws -> FileHandle {
        guard !agentLines.isEmpty else { throw POSIXError(.ECONNRESET) }
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.EMFILE) }
        let guest = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        try guest.write(contentsOf: Data(agentLines.map { $0 + "\n" }.joined().utf8))
        agentEnds.append(guest)
        return FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    }
    func invalidate() {}
}

@MainActor
private final class StubProvider: VMBackendProvider {
    /// What the agents of the guests made from here on say. See ``StubBackend/agentLines``.
    var agentLines: [String] = []

    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        let backend = StubBackend()
        backend.agentLines = agentLines
        return backend
    }
    func backendDidStop(for machine: VirtualMachine) {}
}

/// Machines to list, in a folder of their own.
@MainActor
private struct Scratch {
    let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-app-tests-\(UUID().uuidString)")
    let provider = StubProvider()

    /// - Parameter isSuspended: The machine has state saved on disk, as one that was suspended has.
    func makeMachine(named name: String, os: GuestOS = GuestOS(family: .linux, productName: "Ubuntu 26.04 LTS"), isSuspended: Bool = false) throws -> VirtualMachine {
        let configuration = VMConfiguration(name: name, os: os, cpuCount: 2, memorySize: 4 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        if isSuspended {
            try Data("state".utf8).write(to: bundle.savedStateURL)
        }
        let machine = try VirtualMachine(bundle: bundle)
        machine.backendProvider = provider
        // Whatever the Mac running the tests is doing.
        machine.isHostLocked = { false }
        return machine
    }

    func makeRunningMachine(named name: String) async throws -> VirtualMachine {
        let machine = try makeMachine(named: name)
        await machine.start()
        try #require(machine.state == .running)
        return machine
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite struct MachineListingTests {
    private let scratch = Scratch()

    @Test func machinesThatHoldAGuestAreListedFirst() async throws {
        defer { scratch.cleanUp() }
        let stopped = try scratch.makeMachine(named: "Stopped")
        let running = try await scratch.makeRunningMachine(named: "Running")
        let suspended = try scratch.makeMachine(named: "Suspended", isSuspended: true)
        let paused = try await scratch.makeRunningMachine(named: "Paused")
        await paused.pause()
        #expect(suspended.state == .suspended)
        #expect(paused.state == .paused)

        let groups = MachineListing.groups(of: [stopped, running, suspended, paused], sortedBy: .created)

        // Within a group, in the order the library has them.
        #expect(groups.running.map(\.name) == ["Running", "Paused"])
        #expect(groups.notRunning.map(\.name) == ["Stopped", "Suspended"])
        #expect(groups.all.map(\.name) == ["Running", "Paused", "Stopped", "Suspended"])
        #expect(!groups.isEmpty)

        await running.forceStop()
        await paused.forceStop()
    }

    @Test func sortsByNameTheWayTheFinderDoes() throws {
        defer { scratch.cleanUp() }
        let machines = try ["VM 10", "vm 2", "Alpha"].map { try scratch.makeMachine(named: $0) }

        #expect(MachineListing.groups(of: machines, sortedBy: .name).notRunning.map(\.name) == ["Alpha", "vm 2", "VM 10"])
        #expect(MachineListing.groups(of: machines, sortedBy: .created).notRunning.map(\.name) == ["VM 10", "vm 2", "Alpha"])
    }

    @Test func theFilterLeavesOutOtherSystems() throws {
        defer { scratch.cleanUp() }
        let linux = try scratch.makeMachine(named: "Linux")
        let mac = try scratch.makeMachine(named: "Mac", os: GuestOS(family: .macOS))

        #expect(MachineListing.groups(of: [linux, mac], sortedBy: .created, showing: .macOS).all.map(\.name) == ["Mac"])
        #expect(MachineListing.groups(of: [linux, mac], sortedBy: .created, showing: nil).all.map(\.name) == ["Linux", "Mac"])
        #expect(MachineListing.groups(of: [linux, mac], sortedBy: .created, showing: .windows).isEmpty)
    }

    @Test func aMachineThatIsOffSaysWhatItIsMadeOf() throws {
        defer { scratch.cleanUp() }
        let memory = Formatting.bytes(4 << 30)
        let stopped = try scratch.makeMachine(named: "Box")
        let suspended = try scratch.makeMachine(named: "Asleep", isSuspended: true)

        // The address a stopped machine has reserved is no news.
        #expect(MachineListing.statusLine(for: stopped, address: "192.168.64.3", sshCommand: "ssh box") == "2 CPU · \(memory) RAM · Ubuntu 26.04 LTS")
        #expect(MachineListing.statusLine(for: suspended) == "Suspended · 2 CPU · \(memory) RAM")
    }

    @Test func aRunningMachineSaysWhereItIsReached() async throws {
        defer { scratch.cleanUp() }
        let machine = try await scratch.makeRunningMachine(named: "Box")

        #expect(MachineListing.statusLine(for: machine, address: "192.168.64.3", sshCommand: "ssh box") == "192.168.64.3 · ssh box")
        #expect(MachineListing.statusLine(for: machine, address: "192.168.64.3") == "192.168.64.3")
        // Nothing is known yet in the first moments of a start.
        #expect(MachineListing.statusLine(for: machine) == "Running")

        await machine.pause()
        #expect(MachineListing.statusLine(for: machine, address: "192.168.64.3", sshCommand: "ssh box") == "Paused · 192.168.64.3")

        await machine.forceStop()
    }

    @Test func aMachineThatIsBeingSetUpSaysWhatItIsAt() async throws {
        defer { scratch.cleanUp() }
        // A guest whose agent reports a desktop on its way in.
        scratch.provider.agentLines = [
            #"{"type":"hello","protocol":1,"agent":"1.1"}"#,
            #"{"type":"setup","state":"running","name":"KDE Plasma","step":"Installing KDE Plasma"}"#,
        ]
        let machine = try await scratch.makeRunningMachine(named: "Desk")
        let deadline = ContinuousClock.now + .seconds(5)
        while machine.setupActivity == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // That says more than where it is reached, which is still to change.
        #expect(MachineListing.statusLine(for: machine, address: "192.168.64.3", sshCommand: "ssh desk") == "Installing KDE Plasma…")

        await machine.pause()
        #expect(MachineListing.statusLine(for: machine, address: "192.168.64.3") == "Paused · 192.168.64.3")
        await machine.forceStop()
        #expect(machine.setupActivity == nil)
    }

    @Test func workOnAMachinesFilesComesBeforeItsState() async throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine(named: "Box")

        try await machine.whileStopped(.duplicating) {
            #expect(MachineListing.statusLine(for: machine) == "Duplicating…")
        }
    }

    @Test func theHeadlineCountsMachines() {
        #expect(MachineListing.headline(running: 0, total: 0) == "No virtual machines")
        #expect(MachineListing.headline(running: 0, total: 1) == "1 virtual machine")
        #expect(MachineListing.headline(running: 0, total: 3) == "3 virtual machines")
        #expect(MachineListing.headline(running: 2, total: 5) == "2 of 5 running")
        #expect(MachineListing.headline(running: 1, total: 1) == "1 of 1 running")
    }
}

@MainActor
@Suite struct PendingMessageTests {
    private let scratch = Scratch()

    @Test func nothingToSayIsNothingToShow() throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine(named: "Box")

        #expect(PendingMessage.next(general: nil, machines: [machine], openWindows: []) == nil)
    }

    @Test func aProblemOfTheAppsComesBeforeAMachines() throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine(named: "Box")
        machine.lastError = VMErrorInfo(title: "Couldn't start", message: "…")
        let general = VMErrorInfo(title: "No network", message: "…")

        let first = PendingMessage.next(general: general, machines: [machine], openWindows: [])
        #expect(first?.info.id == general.id)
        guard case .general = first else {
            Issue.record("An app-wide problem should come as one.")
            return
        }
    }

    @Test func aMachineWithItsWindowOpenSaysItThere() throws {
        defer { scratch.cleanUp() }
        let shown = try scratch.makeMachine(named: "Shown")
        let hidden = try scratch.makeMachine(named: "Hidden")
        shown.lastError = VMErrorInfo(title: "Shown's", message: "…")
        hidden.notice = VMErrorInfo(title: "Hidden's", message: "…", copyableText: "sudo sh install.sh")

        let next = PendingMessage.next(general: nil, machines: [shown, hidden], openWindows: [shown.id])

        #expect(next?.info.title == "Hidden's")
        #expect(next?.info.copyableText == "sudo sh install.sh")
        guard case .machine(let machine, _) = next else {
            Issue.record("A machine's notice should come with its machine.")
            return
        }
        #expect(machine === hidden)
        #expect(PendingMessage.next(general: nil, machines: [shown, hidden], openWindows: [shown.id, hidden.id]) == nil)
    }

    @Test func aMachinesErrorComesBeforeItsNotice() throws {
        defer { scratch.cleanUp() }
        let machine = try scratch.makeMachine(named: "Box")
        machine.notice = VMErrorInfo(title: "A notice", message: "…")
        machine.lastError = VMErrorInfo(title: "An error", message: "…")

        let error = try #require(PendingMessage.next(general: nil, machines: [machine], openWindows: []))
        #expect(error.info.title == "An error")
        #expect(!error.isNotice)

        machine.dismissMessage()
        let notice = try #require(PendingMessage.next(general: nil, machines: [machine], openWindows: []))
        #expect(notice.info.title == "A notice")
        #expect(notice.isNotice)
    }

    @Test func aProblemOfTheAppsIsNoNotice() {
        let message = PendingMessage.next(general: VMErrorInfo(title: "No network", message: "…"), machines: [], openWindows: [])
        #expect(message?.isNotice == false)
    }
}

@MainActor
@Suite struct PanelScrollAreaTests {
    private static let rowHeight: CGFloat = 40
    private static let frameHeight: CGFloat = 90

    /// The list between a header and a footer, as it is in the panel.
    private func panelHeight(rows: Int, proposing proposal: CGSize) -> CGFloat {
        let panel = VStack(spacing: 0) {
            Color.clear.frame(height: 50)
            PanelScrollArea(maximumHeight: 200, scrollTarget: Int?.none) {
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { _ in Color.clear.frame(height: Self.rowHeight) }
                }
            }
            Color.clear.frame(height: 40)
        }
        .frame(width: 360)
        return NSHostingController(rootView: panel).sizeThatFits(in: proposal).height
    }

    /// The menu bar makes the panel as small as its content allows. A list that could give way was
    /// left with no room at all, and the panel showed its header and its footer and nothing between.
    @Test func aShortListKeepsItsHeightInAPanelMadeAsSmallAsPossible() {
        #expect(panelHeight(rows: 1, proposing: .zero) == Self.frameHeight + Self.rowHeight)
        #expect(panelHeight(rows: 3, proposing: .zero) == Self.frameHeight + 3 * Self.rowHeight)
    }

    @Test func aShortListIsNoTallerInAPanelWithRoomToSpare() {
        #expect(panelHeight(rows: 3, proposing: CGSize(width: 360, height: 5000)) == Self.frameHeight + 3 * Self.rowHeight)
    }

    @Test func aLongListStopsAtItsLimitAndScrolls() {
        #expect(panelHeight(rows: 30, proposing: .zero) == Self.frameHeight + 200)
        #expect(panelHeight(rows: 30, proposing: CGSize(width: 360, height: 5000)) == Self.frameHeight + 200)
    }
}

@MainActor
@Suite struct DockPresenceTests {
    private typealias Window = DockPresence.WindowFacts

    @Test func aWindowToSwitchToPutsTheAppInTheDock() {
        #expect(DockPresence.wantsDockIcon(for: [Window(isOpen: true, canBecomeMain: true, isPanel: false)]))
    }

    @Test func theMenuBarItemAloneDoesNot() {
        // The item's own window, and the panel that drops down from it.
        let statusItem = Window(isOpen: true, canBecomeMain: false, isPanel: false)
        let panel = Window(isOpen: true, canBecomeMain: false, isPanel: true)

        #expect(!DockPresence.wantsDockIcon(for: []))
        #expect(!DockPresence.wantsDockIcon(for: [statusItem, panel]))
    }

    @Test func anAlertOrAFileDialogDoesNot() {
        #expect(!DockPresence.wantsDockIcon(for: [Window(isOpen: true, canBecomeMain: true, isPanel: true)]))
    }

    @Test func aWindowThatWasClosedDoesNot() {
        // SwiftUI keeps the window of a scene that was closed, to show it again.
        let closed = Window(isOpen: false, canBecomeMain: true, isPanel: false)
        let open = Window(isOpen: true, canBecomeMain: true, isPanel: false)

        #expect(!DockPresence.wantsDockIcon(for: [closed]))
        #expect(DockPresence.wantsDockIcon(for: [closed, open]))
    }

    /// Leaving the Dock while in front hands the front to another app, and macOS goes to the desktop
    /// that app is on: closing a machine's window threw the user onto another desktop.
    @Test func theAppInFrontStaysInTheDockWhenItsLastWindowCloses() {
        #expect(DockPresence.belongsInDock(hasWindows: false, isActive: true, isInDock: true))
    }

    @Test func itLeavesTheDockOnceTheUserHasMovedOn() {
        #expect(!DockPresence.belongsInDock(hasWindows: false, isActive: false, isInDock: true))
    }

    @Test func aWindowPutsItInTheDockWhetherInFrontOrNot() {
        #expect(DockPresence.belongsInDock(hasWindows: true, isActive: false, isInDock: false))
        #expect(DockPresence.belongsInDock(hasWindows: true, isActive: true, isInDock: true))
    }

    @Test func beingInFrontWithoutAWindowDoesNotPutItInTheDock() {
        // As it is while the panel is open, if that makes the app the one in front.
        #expect(!DockPresence.belongsInDock(hasWindows: false, isActive: true, isInDock: false))
    }
}
