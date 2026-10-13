import AppKit
import GuestChannel
import Observation

/// A virtual machine in the library: its bundle, configuration and live state.
@MainActor
@Observable
public final class VirtualMachine: Identifiable {
    public nonisolated let id: UUID
    /// Where the machine is on disk. It only changes when the machine is moved, which it is shut down for.
    public private(set) var bundle: VMBundle
    /// The guest's serial console. It stays the same across restarts.
    public nonisolated let console: SerialConsole
    public private(set) var configuration: VMConfiguration
    public private(set) var state: VMState
    /// The most recent error; cleared when the user dismisses it or the next operation starts.
    public var lastError: VMErrorInfo?
    /// Something to tell the user that isn't an error, such as what is left for them to do. Kept apart
    /// from ``lastError`` so that an operation which clears or reports errors leaves it alone.
    public var notice: VMErrorInfo?
    /// Bytes the machine's disks occupy on the host.
    public private(set) var allocatedDiskSize: UInt64 = 0
    /// Points the machine can go back to, oldest first.
    public private(set) var snapshots: [VMSnapshot] = []
    /// Work in progress on the machine's files. Until it is over the machine can't be started or stopped.
    public private(set) var activity: VMActivity?
    /// How far that work has come, from 0 to 1, for work that takes long enough to say.
    public private(set) var activityProgress: Double?
    /// The line to the agent in the guest. It is only ever connected while the guest is up and has one.
    public let agent = GuestAgent()
    /// Whether the agent has mounted the shared folders, in a guest that doesn't mount them by itself.
    public private(set) var hasAgentMountedSharedFolders = false
    /// The USB devices of this Mac that the guest has been handed. They are the guest's while it runs: a
    /// machine that stops gives them back, and none is written down.
    public private(set) var usbDevices: [USBDevice] = []
    /// How many times the guest has come up since the app was launched, booted or resumed. It tells one
    /// run of the guest from the next, which the state alone doesn't: a restart can be over between two looks.
    @ObservationIgnored public private(set) var startCount = 0
    /// Called when the guest's agent reports addresses, or is gone and reports none any more.
    @ObservationIgnored public var onGuestAddressesChange: (@MainActor (VirtualMachine) -> Void)?
    /// Called when the guest's agent has connected, and when one that was connected is gone.
    @ObservationIgnored public var onGuestAgentChange: (@MainActor (VirtualMachine) -> Void)?
    /// Called with text that was copied in the guest, where its agent shares the clipboard.
    @ObservationIgnored public var onGuestClipboard: (@MainActor (VirtualMachine, String) -> Void)?
    /// Called when the guest asks for what is on this Mac's clipboard.
    @ObservationIgnored public var onGuestClipboardRequest: (@MainActor (VirtualMachine) -> Void)?

    /// The account to set up on the first boot after installation. Kept in memory only: if the app quits
    /// before that boot, the guest shows its own setup assistant instead.
    @ObservationIgnored public var pendingProvisioning: GuestProvisioning?

    @ObservationIgnored public weak var backendProvider: (any VMBackendProvider)?
    @ObservationIgnored public var onConfigurationChange: (@MainActor (VirtualMachine) -> Void)?
    /// Called when the guest has been resumed from saved memory, where it believes no time has passed.
    @ObservationIgnored public var onResume: (@MainActor (VirtualMachine) -> Void)?
    /// Called when the guest has come up, booted or resumed. Not when it carries on after a snapshot,
    /// for which it was only away for a moment.
    @ObservationIgnored public var onGuestStart: (@MainActor (VirtualMachine) -> Void)?
    /// How long a guest gets to act on a shutdown request. A guest that is still up after that either
    /// ignored the request or is waiting for someone to confirm it on its screen, so the machine counts as
    /// running again rather than staying stuck in ``VMState/stopping``.
    @ObservationIgnored public var shutdownRequestTimeout: Duration = .seconds(60)
    /// How often a shutdown request is repeated until the guest has acted on it. A request that arrives
    /// while the guest is still starting up is lost, because nothing is listening for the power button
    /// yet. Guests that answer with a question on their screen are only ever asked once.
    @ObservationIgnored public var shutdownRequestRepeatInterval: Duration = .seconds(5)
    /// Whether this Mac's screen is locked. A suspended guest can't be resumed while it is.
    @ObservationIgnored public var isHostLocked: @MainActor () -> Bool = { HostSession.isScreenLocked }
    /// Asked before every start. While it says no, starting does nothing and the machine stays as it is.
    @ObservationIgnored public var isStartAllowed: @MainActor () -> Bool = { true }
    /// The time zone this Mac is in, by its name in the time zone database.
    @ObservationIgnored public var hostTimeZone: @MainActor () -> String = { TimeZone.current.identifier }

    @ObservationIgnored private var backend: (any VMBackend)?
    @ObservationIgnored private var restartsAfterStop = false
    @ObservationIgnored private var shutdownRequestExpiry: Task<Void, Never>?
    /// The guest has shut down for a restart and its start is about to begin.
    @ObservationIgnored private var isAboutToRestart = false
    /// A pause or resume is under way. Neither has a state of its own.
    @ObservationIgnored private var isChangingPause = false
    /// How many USB devices are being handed to the guest at this moment.
    @ObservationIgnored private var usbDevicesOnTheirWay = 0
    /// The guest's clock stood still for a while, suspended or paused, and has not been set since.
    @ObservationIgnored private var isGuestClockStale = false
    /// Counts the times the guest's clock has gone stale, to tell whether it did again while it was being set.
    @ObservationIgnored private var clockStandstills = 0
    /// The run of the guest that ``setupFailureRecordChanges`` counts for.
    @ObservationIgnored private var setupFailureRecordRun: Int?
    /// How often what is on record of the setup scripts' failure has changed in this run of the guest.
    @ObservationIgnored private var setupFailureRecordChanges = 0
    /// A script can fail, be put right and run again, and the next one can fail after it: each of those
    /// is news. A guest that says one thing and then the other without end is heard this often in a
    /// run, and no more.
    private static let maximumSetupFailureRecordChanges = 16
    @ObservationIgnored private var isLookingAfterGuest = false
    @ObservationIgnored private var shouldLookAfterGuestAgain = false

    public init(bundle: VMBundle, configuration: VMConfiguration) {
        self.id = configuration.id
        self.bundle = bundle
        self.console = SerialConsole(logURL: bundle.consoleLogURL)
        self.configuration = configuration
        // Copies left by a revert that was cut short. The files they were meant to replace are intact.
        bundle.removeRestoreLeftovers()
        self.state = bundle.hasSavedState ? .suspended : .stopped
        self.snapshots = bundle.loadSnapshots()
        refreshDiskUsage()
        agent.onConnect = { [weak self] hello in self?.agentDidConnect(hello) }
        agent.onAddressesChange = { [weak self] in
            guard let self else { return }
            onGuestAddressesChange?(self)
        }
        agent.onDisconnect = { [weak self] in
            guard let self else { return }
            // A guest that restarts by itself keeps its machine running, and comes back with nothing mounted.
            hasAgentMountedSharedFolders = false
            onGuestAgentChange?(self)
        }
        agent.onClipboard = { [weak self] text in
            guard let self else { return }
            onGuestClipboard?(self, text)
        }
        agent.onClipboardRequest = { [weak self] in
            guard let self else { return }
            onGuestClipboardRequest?(self)
        }
        agent.onSetupChange = { [weak self] status in self?.guestSetupDidChange(to: status) }
    }

    public convenience init(bundle: VMBundle) throws {
        try self.init(bundle: bundle, configuration: bundle.loadConfiguration())
    }

    public var name: String { configuration.name }

    /// What there is to show the user about this machine right now: an error first, then a notice.
    public var message: VMErrorInfo? { lastError ?? notice }

    /// The user has seen ``message``.
    public func dismissMessage() {
        if lastError != nil {
            lastError = nil
        } else {
            notice = nil
        }
    }

    /// Whether the guest has shut down, or is about to, in order to be started again right away.
    public var isRestartPending: Bool { restartsAfterStop || isAboutToRestart }

    /// The guest display, available while the machine is active.
    public var displayView: NSView? { backend?.displayView }

    // MARK: Configuration

    /// Mutates and persists the configuration. Changes that can apply to a running guest are applied live.
    public func updateConfiguration(_ body: (inout VMConfiguration) -> Void) throws {
        var updated = configuration
        body(&updated)
        guard updated != configuration else { return }
        try bundle.save(updated)
        let previous = configuration
        configuration = updated

        if let backend, state == .running || state == .paused {
            if previous.sharedFolders != updated.sharedFolders {
                try backend.setSharedFolders(updated.sharedFolders)
            }
            for interface in updated.networkInterfaces {
                let before = previous.networkInterfaces.first { $0.id == interface.id }
                if let before, before.isConnected != interface.isConnected {
                    try backend.setNetworkInterface(interface.id, connected: interface.isConnected)
                }
            }
            if previous.keyboard != updated.keyboard {
                backend.setCapturesSystemKeys(updated.keyboard.capturesSystemKeys)
            }
        }
        onConfigurationChange?(self)
    }

    // MARK: Removable drives

    /// Plugs a disc or disk image in as a USB drive: right away if the guest is running, otherwise from
    /// the next start.
    public func attachImage(_ image: RemovableImage) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: image.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw VMError.invalidConfiguration("“\(image.path)” isn't a disc or disk image.")
        }
        guard !configuration.removableImages.contains(where: { $0.path == image.path }) else {
            throw VMError.invalidConfiguration("“\(image.name)” is already attached to “\(name)”.")
        }
        if let backend = try backendForDriveChange() {
            try await backend.attachRemovableImage(image)
        }
        try updateConfiguration { $0.removableImages.append(image) }
    }

    /// Unplugs a drive, like pulling a USB stick: a guest that is still writing to it loses that data.
    public func ejectImage(_ id: UUID) async throws {
        guard configuration.removableImages.contains(where: { $0.id == id }) else { return }
        if let backend = try backendForDriveChange() {
            try await backend.detachRemovableImage(id)
        }
        try updateConfiguration { $0.removableImages.removeAll { $0.id == id } }
    }

    /// The backend to tell about a drive being plugged in or pulled, `nil` if the machine is shut down.
    /// Throws while drives can't change at all.
    private func backendForDriveChange() throws -> (any VMBackend)? {
        if let activity {
            throw VMError.busy(name: name, activity)
        }
        switch state {
        case .stopped:
            return nil
        case .running, .paused:
            return backend
        case .suspended:
            // The saved memory expects the drives it was saved with.
            throw VMError.invalidConfiguration("“\(name)” is suspended. Resume it to change its drives.")
        case .starting, .restoring, .suspending, .stopping:
            throw VMError.invalidConfiguration("“\(name)” is busy starting up or shutting down. Try again in a moment.")
        }
    }

    // MARK: USB devices

    /// Hands a USB device of this Mac to the running guest. The Mac is without it until it is detached
    /// or pulled out, or the machine stops.
    public func attachUSBDevice(_ device: USBDevice) async throws {
        if let activity {
            throw VMError.busy(name: name, activity)
        }
        guard state != .paused else {
            throw VMError.invalidConfiguration("“\(name)” is paused. Resume it to attach a USB device.")
        }
        guard state == .running, let backend else { throw VMError.notRunning(name: name) }
        guard !usbDevices.contains(where: { $0.id == device.id }) else { return }
        usbDevicesOnTheirWay += 1
        defer { usbDevicesOnTheirWay -= 1 }
        try await backend.attachUSBDevice(device)
        guard isCurrent(backend) else {
            // The guest stopped while the device was on its way, and its machine gave it back.
            throw VMError.notRunning(name: name)
        }
        usbDevices.append(device)
    }

    /// Gives a USB device back to this Mac, like pulling it out of the guest: a guest that is still
    /// writing to it loses that data.
    public func detachUSBDevice(_ id: USBDevice.ID) async throws {
        guard usbDevices.contains(where: { $0.id == id }), let backend else { return }
        try await backend.detachUSBDevice(id)
        usbDevices.removeAll { $0.id == id }
    }

    /// A USB device that the guest had is gone from this Mac. The engine says so itself when a device is
    /// pulled out; this is for the host's word, which may come first or be the only one.
    public func usbDeviceDidDisappear(_ id: USBDevice.ID) {
        guard usbDevices.contains(where: { $0.id == id }) else { return }
        usbDevices.removeAll { $0.id == id }
        if let backend {
            // What the engine still holds of it is of no use to the guest.
            Task { try? await backend.detachUSBDevice(id) }
        }
    }

    // MARK: Guest agent

    /// Starts looking for the agent in a guest that has just come up.
    private func reachForAgent() {
        guard configuration.canHaveGuestAgent else { return }
        agent.start { [weak self] in
            guard let self else { throw CancellationError() }
            return try await connectToGuest(port: GuestProtocol.agentPort)
        }
    }

    private func agentDidConnect(_ hello: AgentHello) {
        // The guest knows best what it is. One that was upgraded says so here, and one that was installed
        // from a disc says it for the first time.
        if let name = hello.system.displayName {
            try? updateConfiguration { configuration in
                configuration.os.productName = name
                if configuration.os.family == .linux, let distribution = hello.system.id, !distribution.isEmpty {
                    configuration.os.distribution = distribution
                }
                if let build = hello.system.build, !build.isEmpty {
                    configuration.os.build = build
                }
            }
        }
        onGuestAgentChange?(self)
        Task { await lookAfterGuest() }
    }

    /// What the guest's setup script is called while it is still to run or running, and `nil` once it
    /// is over: `Setting up KDE Plasma`.
    public var setupTitle: String? {
        guard state == .running, let setup = agent.setup, setup.isUnderWay else { return nil }
        return setup.title
    }

    /// What that script is busy with: the step it says it is at, or failing that what it is called.
    public var setupActivity: String? {
        guard let setupTitle else { return nil }
        return agent.setup?.step ?? setupTitle
    }

    /// The guest's setup scripts have got somewhere. That one failed is news once, also when it failed
    /// while the app wasn't looking: what the user has been told is written down, so that a guest
    /// that comes back up with a script that failed long ago has nothing new to tell. Run again, it is
    /// at work again, and a failure after that is news once more.
    private func guestSetupDidChange(to status: GuestSetupStatus) {
        let hasFailed = status.state == .failed
        guard hasFailed != configuration.installation.hasReportedSetupFailure else { return }
        if setupFailureRecordRun != startCount {
            setupFailureRecordRun = startCount
            setupFailureRecordChanges = 0
        }
        guard setupFailureRecordChanges < Self.maximumSetupFailureRecordChanges else { return }
        setupFailureRecordChanges += 1
        if hasFailed {
            let place = status.step.map { " at “\($0)”" } ?? ""
            notice = VMErrorInfo(
                title: status.name.map { "\($0) couldn't be set up in “\(name)”" } ?? "The setup script failed in “\(name)”",
                message: "The setup script stopped with an error\(place). What it printed is in \(GuestIntegration.setupLogPath) in the virtual machine. To run it again, run this there:\n\n\(GuestIntegration.setupRetryCommand)",
                copyableText: GuestIntegration.setupRetryCommand
            )
        }
        try? updateConfiguration { $0.installation.hasReportedSetupFailure = hasFailed }
    }

    /// Does through the agent what the guest needs from the host right now: a clock that is right, its
    /// shared folders mounted, and once in its life this Mac's time zone. Called when the agent connects
    /// and whenever one of them may be due.
    private func lookAfterGuest() async {
        // One round at a time. Whoever comes while one is under way has it run once more instead, so
        // that nothing is asked of the agent twice.
        guard !isLookingAfterGuest else {
            shouldLookAfterGuestAgain = true
            return
        }
        isLookingAfterGuest = true
        defer { isLookingAfterGuest = false }
        repeat {
            shouldLookAfterGuestAgain = false
            let run = startCount
            let standstills = clockStandstills
            // First the clock: until it is right, everything in the guest that goes by the time is off.
            // A guest that was paused again while the time was on its way has it set once more.
            if isGuestClockStale, await agent.setClock(), run == startCount, standstills == clockStandstills {
                isGuestClockStale = false
            }
            if !configuration.mountsSharedFoldersAutomatically, !hasAgentMountedSharedFolders,
               await agent.mountSharedFolders(tag: GuestIntegration.sharedFoldersTag, at: GuestIntegration.sharedFoldersMountPoint),
               // The answer may come after the guest has stopped, or stopped and started again.
               run == startCount, agent.isConnected {
                hasAgentMountedSharedFolders = true
            }
            // A guest that set itself up was never asked where it is. One that can be told is told once;
            // whoever picks another time zone in the guest afterwards keeps it.
            if agent.setsTimeZone, !configuration.installation.hasHostTimeZone,
               await agent.setTimeZone(hostTimeZone()), run == startCount {
                try? updateConfiguration { $0.installation.hasHostTimeZone = true }
            }
        } while shouldLookAfterGuestAgain
    }

    // MARK: Guest socket

    /// Connects to a port in the running guest over its socket device, which needs no network in the
    /// guest. The connection is closed when the returned handle is released.
    public func connectToGuest(port: UInt32) async throws -> FileHandle {
        guard state == .running, let backend else { throw VMError.notRunning(name: name) }
        return try await backend.connectToGuest(port: port)
    }

    /// Has the guest's agent take on `job`, and returns the connection that carries the job from there:
    /// ``JobFrame``s both ways, until the agent ends it or the connection is closed, which calls it off.
    ///
    /// Nothing is asked of a guest whose machine isn't to be driven from the command line, and nothing
    /// of an agent that doesn't say it does this kind of job.
    public func openJob(_ job: GuestJob, answerTimeout: TimeInterval = 15) async throws -> FileHandle {
        guard configuration.automation.isAllowed else { throw GuestJobError.notAllowed(name: name) }
        guard state == .running, let backend else { throw VMError.notRunning(name: name) }
        guard agent.isConnected else { throw GuestJobError.noAgent(name: name) }
        guard let feature = job.feature, agent.offers(feature) else {
            // The agent's version is the guest's word. What is shown of it is short and plain.
            let version = agent.version.map { ShownText.line($0, limit: 32) }
            throw GuestJobError.notOffered(name: name, version: version)
        }
        // A job is one line, and an agent passes over a line that is longer than lines may be.
        guard GuestMessageCoding.line(for: job).count < GuestProtocol.maximumLineLength else { throw GuestJobError.tooLong }
        let connection: FileHandle
        do {
            connection = try await backend.connectToGuest(port: GuestProtocol.jobPort)
        } catch {
            throw GuestJobError.noAnswer(name: name)
        }
        // Waiting for the agent's answer holds a thread of its own: not the main actor, and none of
        // the few that everything else that waits here shares.
        let descriptor = connection.fileDescriptor
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<GuestJobAnswer?, Never>) in
            Thread.detachNewThread {
                continuation.resume(returning: GuestJobLine.open(job, over: descriptor, timeout: answerTimeout))
            }
        }
        guard let answer else { throw GuestJobError.noAnswer(name: name) }
        guard answer.ok else {
            // The guest's own words, made fit to show on this Mac.
            let reason = answer.error.map { ShownText.line($0, limit: GuestJobError.longestReason) } ?? ""
            throw GuestJobError.refused(reason.isEmpty ? "The guest tools in “\(name)” refused, without saying why." : reason)
        }
        return connection
    }

    /// Has the guest's agent do `job` to its end, and returns what it put out. For a job that takes
    /// nothing in and is over in a moment: one that doesn't finish its next frame within `patience`
    /// is called off.
    public func collect(_ job: GuestJob, patience: TimeInterval = 30) async throws -> Data {
        let connection = try await openJob(job)
        let descriptor = connection.fileDescriptor
        let name = name
        let outcome: Result<Data, GuestJobError> = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                // A command is told at once that it has no input coming.
                if case .exec = job {
                    JobFrame.write(.input, to: descriptor)
                }
                var collected = Data()
                while true {
                    guard let frame = try? JobFrame.read(from: descriptor, timeout: patience) else {
                        continuation.resume(returning: .failure(.noAnswer(name: name)))
                        return
                    }
                    switch frame.kind {
                    case .output:
                        guard collected.count + frame.payload.count <= Self.longestCollectedOutput else {
                            continuation.resume(returning: .failure(.tooLong))
                            return
                        }
                        collected.append(frame.payload)
                    case .end:
                        let end = frame.end ?? .success
                        if let error = end.shownError {
                            continuation.resume(returning: .failure(.refused(error)))
                        } else if end.status != 0 {
                            continuation.resume(returning: .failure(.refused("The guest tools in “\(name)” gave up, without saying why.")))
                        } else {
                            continuation.resume(returning: .success(collected))
                        }
                        return
                    case .input, .errorOutput:
                        break
                    }
                }
            }
        }
        // Hanging up is what ends the job on the agent's side.
        try? connection.close()
        return try outcome.get()
    }

    /// The most that a job which is collected may put out: the tree of a screen is the longest.
    private nonisolated static let longestCollectedOutput = 64 << 20

    // MARK: The machine's own display, mouse and keyboard

    /// Whether this Mac does `job` itself, with the machine's own display, mouse and keyboard, rather
    /// than have the guest's agent do it.
    ///
    /// It does for macOS guests, where an agent would need the say-so of someone at the guest's screen
    /// first. Text that the machine's keyboard has no keys for is left to an agent that types.
    public func doesItself(_ job: GuestJob) -> Bool {
        guard configuration.os.family == .macOS else { return false }
        switch job {
        case .screenshot, .pointer:
            return true
        case .keys(let keys):
            return (keys.text ?? "").allSatisfy { MacKeys.press(typing: $0) != nil } || !agent.offers(GuestFeature.input)
        case .exec, .tree, .element, .permission, .unknown:
            return false
        }
    }

    /// Whether a kind of job, by its ``GuestFeature``, is done in this machine's guest right now: by
    /// its agent, or by this Mac itself.
    public func does(_ feature: String) -> Bool {
        if agent.offers(feature) {
            return true
        }
        return state == .running && configuration.os.family == .macOS && [GuestFeature.screen, GuestFeature.input].contains(feature)
    }

    /// Does a job this Mac does itself (``doesItself(_:)``), and returns what the job is for: the
    /// picture of the screen. Like any job, only for a machine that is to be driven from the command line.
    public func carryOut(_ job: GuestJob) async throws -> Data {
        guard configuration.automation.isAllowed else { throw GuestJobError.notAllowed(name: name) }
        guard state == .running, let backend else { throw VMError.notRunning(name: name) }
        switch job {
        case .screenshot:
            return try await backend.screenshot()
        case .pointer(let request):
            let turnsWheel = request.action == .scroll ? await guestTurnsWheel() : false
            try await backend.pointer(request, guestTurnsWheel: turnsWheel)
        case .keys(let request):
            try await backend.keys(request)
        case .exec, .tree, .element, .permission, .unknown:
            throw MachineDeskError.unavailable
        }
        return Data()
    }

    /// Whether the guest scrolls the other way round than its wheel is turned. macOS does, until
    /// someone turns that off in its settings, which only the guest can tell: its agent is asked, and
    /// a guest without one is taken to be as macOS comes.
    private func guestTurnsWheel() async -> Bool {
        guard agent.isConnected, agent.offers(GuestFeature.exec) else { return true }
        let setting = GuestJob.exec(.init(arguments: ["/usr/bin/defaults", "read", "-g", "com.apple.swipescrolldirection"]))
        guard let said = try? await collect(setting, patience: 5) else { return true }
        return String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    public func refreshDiskUsage() {
        allocatedDiskSize = bundle.allocatedSize(of: configuration.disks.filter { !$0.readOnly })
    }

    /// The machine's bundle is somewhere else on disk from now on: it was moved there. The machine is
    /// shut down, so nothing of it is open in the old place.
    func relocate(to bundle: VMBundle) {
        self.bundle = bundle
        console.setLogURL(bundle.consoleLogURL)
        refreshDiskUsage()
    }

    /// Says how far `activity` has come. Word that arrives after the work is over is dropped.
    func reportProgress(_ fraction: Double, of activity: VMActivity) {
        guard self.activity == activity else { return }
        activityProgress = fraction
    }

    // MARK: Lifecycle

    /// Boots the machine, or restores it if it was suspended.
    ///
    /// - Parameter inRecovery: Boot a stopped macOS guest into its recovery environment.
    public func start(inRecovery: Bool = false) async {
        guard activity == nil else { return }
        await performStart(inRecovery: inRecovery)
    }

    /// - Parameter carryingOn: The guest goes back to what it was doing a moment ago, after a snapshot.
    private func performStart(inRecovery: Bool = false, carryingOn: Bool = false) async {
        guard state == .stopped || state == .suspended, isStartAllowed() else { return }
        let restoring = state == .suspended && bundle.hasSavedState
        lastError = nil
        state = restoring ? .restoring : .starting
        do {
            guard let backendProvider else { throw VMError.noBackendProvider }
            let backend = try await backendProvider.makeBackend(for: self, console: console.connect(continuing: restoring))
            backend.eventHandler = { [weak self] event in self?.handle(event) }
            self.backend = backend

            var options = VMStartOptions()
            if restoring {
                options.savedState = bundle.savedStateURL
            } else if inRecovery {
                options.startsInRecovery = true
            } else if !configuration.installation.isProvisioned {
                options.provisioning = pendingProvisioning
            }
            if !restoring {
                // Saved memory that this boot isn't resuming belongs to a disk that is about to change.
                // Left behind, it would be offered for resuming later and wreck the file system.
                bundle.removeSavedState()
            }
            try await backend.start(options: options)
            // The guest can be gone again by the time the start is reported, for instance stopped with
            // an error. Then everything has been cleaned up already.
            guard isCurrent(backend) else { return }
            if restoring {
                bundle.removeSavedState()
            }
            if options.provisioning != nil {
                // The guest only reads the account on this boot; a later start must not offer it again.
                pendingProvisioning = nil
                try? updateConfiguration { $0.installation.isProvisioned = true }
            }
            state = .running
            startCount += 1
            isGuestClockStale = restoring
            clockStandstills += 1
            reachForAgent()
            if restoring {
                onResume?(self)
            }
            if !carryingOn {
                onGuestStart?(self)
            }
        } catch {
            tearDownBackend()
            console.disconnect()
            state = restoring && bundle.hasSavedState ? .suspended : .stopped
            if restoring, isHostLocked() {
                // The saved memory is fine; it just can't be read back right now.
                lastError = VMErrorInfo(
                    title: "Couldn't resume “\(name)”",
                    message: "This Mac is locked, and a suspended virtual machine can only be resumed while it is unlocked. Unlock the Mac and resume “\(name)” again. (\(error.localizedDescription))"
                )
            } else if restoring {
                // Trying again won't help if the saved memory doesn't fit the machine any more, and
                // nothing else can be changed while it is there. Say what the way out is.
                lastError = VMErrorInfo(
                    title: "Couldn't resume “\(name)”",
                    message: "\(error.localizedDescription)\n\nIf this keeps happening, choose Discard Saved State from the virtual machine's menu. It then starts up fresh, without what the guest had open."
                )
            } else {
                report(error, title: "Couldn't start “\(name)”")
            }
        }
    }

    /// Whether `backend` is still the one this machine runs on. After an `await`, the guest may have
    /// stopped by itself and been cleaned up in the meantime.
    private func isCurrent(_ backend: any VMBackend) -> Bool {
        self.backend === backend
    }

    /// Asks the guest to shut down. Falls back to a forced stop when the guest can't be asked.
    ///
    /// - Returns: How the guest was asked, or `nil` if it wasn't: it isn't running, or stopped meanwhile.
    @discardableResult
    public func shutDown() async -> ShutdownRequest? {
        guard activity == nil, state == .running, let backend else { return nil }
        if agent.isConnected {
            // Asked through its agent, a guest shuts down wherever it is in its startup and whatever is
            // on its screen. The power button below is for an agent that doesn't answer.
            state = .stopping
            expireShutdownRequest(after: shutdownRequestTimeout)
            if await agent.shutDown() { return .agent }
            guard isCurrent(backend), state == .stopping else { return nil }
        }
        if backend.canRequestStop {
            do {
                try backend.requestStop()
                state = .stopping
                expireShutdownRequest(after: shutdownRequestTimeout)
                return .powerButton
            } catch {
                // Fall through to a forced stop.
            }
        }
        await forceStop()
        return .forced
    }

    private func expireShutdownRequest(after timeout: Duration) {
        shutdownRequestExpiry?.cancel()
        let repeatInterval = configuration.asksBeforeShuttingDown ? nil : shutdownRequestRepeatInterval
        shutdownRequestExpiry = Task { [weak self] in
            let deadline = ContinuousClock.now + timeout
            while let repeatInterval, ContinuousClock.now + repeatInterval < deadline {
                try? await Task.sleep(for: repeatInterval)
                guard !Task.isCancelled, let self, state == .stopping else { return }
                if let backend, backend.canRequestStop {
                    try? backend.requestStop()
                }
            }
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled, let self, state == .stopping else { return }
            // Whatever the guest does from here on is its own doing, not a restart we asked for.
            restartsAfterStop = false
            state = .running
        }
    }

    /// Stops the machine immediately, like pulling the power cord.
    public func forceStop() async {
        guard activity == nil else { return }
        await performForceStop()
    }

    private func performForceStop() async {
        guard state.isActive, let backend else { return }
        state = .stopping
        do {
            try await backend.stop()
        } catch {
            report(error, title: "Couldn't stop “\(name)”")
        }
        finishStop()
    }

    public func pause() async {
        guard activity == nil, !isChangingPause, state == .running, let backend else { return }
        isChangingPause = true
        defer { isChangingPause = false }
        do {
            try await backend.pause()
            guard isCurrent(backend), state == .running else { return }
            state = .paused
        } catch {
            report(error, title: "Couldn't pause “\(name)”")
        }
    }

    public func resume() async {
        guard activity == nil, !isChangingPause, state == .paused, let backend else { return }
        isChangingPause = true
        defer { isChangingPause = false }
        do {
            try await backend.resume()
            guard isCurrent(backend), state == .paused else { return }
            state = .running
            // The guest's clock stood still while it was paused.
            isGuestClockStale = true
            clockStandstills += 1
            Task { await lookAfterGuest() }
        } catch {
            report(error, title: "Couldn't resume “\(name)”")
        }
    }

    /// Saves the guest's state to disk and releases its memory.
    public func suspend() async {
        guard activity == nil else { return }
        do {
            try await performSuspend()
        } catch {
            report(error, title: "Couldn't suspend “\(name)”")
        }
    }

    /// Suspends a running or paused machine. If that fails, the machine is left as it was.
    private func performSuspend() async throws {
        guard state == .running || state == .paused, let backend else { return }
        let wasRunning = state == .running
        state = .suspending
        do {
            // The guest's USB devices stay where they are until it has stopped: if this fails, it
            // carries on with them. They aren't part of what is saved. This Mac has them back once the
            // guest is gone, and the guest finds them unplugged when it comes back.
            if wasRunning {
                try await backend.pause()
            }
            try await backend.saveState(to: bundle.savedStateURL)
            try await backend.stop()
            guard isCurrent(backend) else {
                // It stopped on its own account while being saved; what was saved is of no use.
                bundle.removeSavedState()
                throw VMError.invalidConfiguration("“\(name)” stopped while it was being suspended.")
            }
            tearDownBackend()
            state = .suspended
            refreshDiskUsage()
        } catch {
            bundle.removeSavedState()
            // A guest that shut itself down or crashed in the meantime has been cleaned up already and
            // is not coming back.
            guard isCurrent(backend) else { throw error }
            if wasRunning {
                try? await backend.resume()
                guard isCurrent(backend) else { throw error }
                state = .running
            } else {
                state = .paused
            }
            throw error
        }
    }

    /// Shuts the guest down and starts it again once it has. Returns as ``shutDown()`` does.
    @discardableResult
    public func restart() async -> ShutdownRequest? {
        guard activity == nil, state == .running else { return nil }
        restartsAfterStop = true
        return await shutDown()
    }

    /// Throws away the suspended state so the next start is a cold boot.
    public func discardSavedState() {
        guard activity == nil, state == .suspended else { return }
        bundle.removeSavedState()
        state = .stopped
    }

    // MARK: Snapshots

    /// Saves the machine's current state as a snapshot.
    ///
    /// A running guest is suspended for the moment it takes and then carries on; its memory becomes part of
    /// the snapshot. That is the only way to be sure the disks are complete on the host: everything the
    /// guest has written is only guaranteed to be in the image files once the machine has let go of them.
    @discardableResult
    public func takeSnapshot(named name: String? = nil) async throws -> VMSnapshot {
        try begin(.takingSnapshot)
        defer { activity = nil }

        // A snapshot covers the machine's own disks. A drive the guest can write to is a file elsewhere
        // that goes on changing, and a guest brought back with its memory would write what it remembers
        // of that drive over what is on it by then.
        let holdsMemory = state.isActive || bundle.hasSavedState
        if holdsMemory, let image = configuration.removableImages.first(where: { !$0.readOnly }) {
            throw VMError.invalidConfiguration(
                "“\(image.name)” is attached and the guest can write to it, but a snapshot can't cover it. Eject it, or shut down “\(self.name)”, before taking the snapshot."
            )
        }

        let wasPaused = state == .paused
        let wasActive = state == .running || wasPaused
        if wasActive, let device = usbDevices.first {
            // A running guest is suspended for the moment the snapshot takes, which unplugs its USB
            // devices: it wouldn't come back as it was, and a snapshot can't cover what is on a device.
            throw VMError.invalidConfiguration(
                "“\(self.name)” has the USB device “\(device.name)”, which a snapshot can't cover. Eject it in the guest and detach it, or shut down “\(self.name)”, before taking the snapshot."
            )
        }
        if wasActive, isHostLocked() {
            // The guest would be suspended for the snapshot and then stay that way until someone unlocks
            // the Mac. Better to leave it running and say so.
            throw VMError.invalidConfiguration(
                "This Mac is locked. “\(self.name)” would have to be suspended for the snapshot and couldn't be resumed until the Mac is unlocked. Unlock it first, or shut the virtual machine down."
            )
        }
        if wasActive {
            try await performSuspend()
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let snapshotName = trimmed.isEmpty ? VMSnapshot.defaultName(avoiding: snapshots) : trimmed
        let result: Result<VMSnapshot, any Error>
        do {
            let (bundle, configuration) = (bundle, configuration)
            let snapshot = try await Task.detached { try bundle.takeSnapshot(named: snapshotName, of: configuration) }.value
            snapshots.append(snapshot)
            result = .success(snapshot)
        } catch {
            result = .failure(error)
        }
        if wasActive {
            // Whether or not the snapshot worked out, the guest goes back to what it was doing.
            await performStart(carryingOn: true)
            if wasPaused, state == .running, let backend, (try? await backend.pause()) != nil {
                state = .paused
            }
        }
        return try result.get()
    }

    /// Goes back to a snapshot, discarding everything the guest has done since. A running guest is stopped.
    ///
    /// Afterwards the machine is suspended if the snapshot holds the guest's memory, otherwise shut down.
    public func revert(to snapshot: VMSnapshot) async throws {
        try begin(.reverting)
        defer { activity = nil }

        // Get the snapshot's files ready first. If it can't be used, the guest carries on untouched.
        let bundle = bundle
        let staged = try await Task.detached { try bundle.stageRestore(of: snapshot) }.value
        await performForceStop()
        guard !state.isActive else {
            bundle.removeRestoreLeftovers()
            throw VMError.notStopped(name: name, state)
        }

        // From here on the files change. However this ends, the machine is what its files say it is.
        defer {
            state = bundle.hasSavedState ? .suspended : .stopped
            refreshDiskUsage()
        }
        let current = configuration
        try await Task.detached { try bundle.commitRestore(staged, replacing: current) }.value

        let reverted = configuration.reverted(to: snapshot)
        do {
            try bundle.save(reverted)
        } catch {
            // The saved memory expects the snapshot's hardware. Without that configuration it can only
            // fail to resume, so the machine is left to boot from the snapshot's disk instead.
            bundle.removeSavedState()
            throw error
        }
        configuration = reverted
        onConfigurationChange?(self)
    }

    /// Gives a snapshot another name. An empty name leaves it as it is.
    public func renameSnapshot(_ snapshot: VMSnapshot, to name: String) throws {
        if let activity {
            throw VMError.busy(name: self.name, activity)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) else { return }
        var renamed = snapshots[index]
        renamed.name = trimmed
        try bundle.saveSnapshot(renamed)
        snapshots[index] = renamed
    }

    public func deleteSnapshot(_ snapshot: VMSnapshot) throws {
        if let activity {
            throw VMError.busy(name: name, activity)
        }
        try bundle.removeSnapshot(snapshot.id)
        snapshots.removeAll { $0.id == snapshot.id }
    }

    /// Runs `operation` on a machine that is shut down and keeps it that way until the operation is over.
    public func whileStopped<T>(_ activity: VMActivity, _ operation: () async throws -> T) async throws -> T {
        try begin(activity)
        defer {
            self.activity = nil
            activityProgress = nil
        }
        guard state == .stopped else { throw VMError.notStopped(name: name, state) }
        return try await operation()
    }

    /// Runs `operation` on the machine's files in whatever state the machine is, and keeps it in that
    /// state until the operation is over: a guest that is up stays up. For work that only reads what
    /// the guest doesn't write to, such as a snapshot.
    func whileClaimed<T>(_ activity: VMActivity, _ operation: () async throws -> T) async throws -> T {
        try begin(activity)
        defer {
            self.activity = nil
            activityProgress = nil
        }
        return try await operation()
    }

    /// Claims the machine for work on its files. Throws if it is already claimed or in the middle of
    /// starting up or shutting down.
    private func begin(_ activity: VMActivity) throws {
        if let current = self.activity {
            throw VMError.busy(name: name, current)
        }
        // A USB device that is on its way to the guest isn't on its list yet, and a snapshot goes by that list.
        guard !state.isTransitioning, !isAboutToRestart, !isChangingPause, usbDevicesOnTheirWay == 0 else {
            throw VMError.invalidConfiguration("“\(name)” is busy starting up or shutting down. Try again in a moment.")
        }
        self.activity = activity
        activityProgress = nil
    }

    // MARK: Backend events

    private func handle(_ event: VMBackendEvent) {
        switch event {
        case .guestDidStop:
            let restart = restartsAfterStop
            finishStop()
            if restart {
                // Until the start has begun, the machine looks shut down. Nothing may claim it for
                // work on its files in that gap, or the restart would be lost.
                isAboutToRestart = true
                Task {
                    isAboutToRestart = false
                    await performStart()
                }
            }
        case .stoppedWithError(let message):
            finishStop()
            lastError = VMErrorInfo(title: "“\(name)” stopped unexpectedly", message: message)
        case .networkDisconnected(let message):
            lastError = VMErrorInfo(title: "Network disconnected in “\(name)”", message: message)
        case .usbDeviceDisconnected(let id):
            // Pulling a device out is nothing to report.
            usbDevices.removeAll { $0.id == id }
        }
    }

    private func finishStop() {
        restartsAfterStop = false
        shutdownRequestExpiry?.cancel()
        shutdownRequestExpiry = nil
        tearDownBackend()
        state = .stopped
        refreshDiskUsage()
    }

    private func tearDownBackend() {
        guard backend != nil else { return }
        agent.stop()
        isGuestClockStale = false
        hasAgentMountedSharedFolders = false
        // A machine that is gone holds no device: this Mac has them back.
        usbDevices = []
        backend?.eventHandler = nil
        backend?.invalidate()
        backend = nil
        console.disconnect()
        backendProvider?.backendDidStop(for: self)
    }

    private func report(_ error: any Error, title: String) {
        lastError = VMErrorInfo(title: title, message: error.localizedDescription)
    }
}
