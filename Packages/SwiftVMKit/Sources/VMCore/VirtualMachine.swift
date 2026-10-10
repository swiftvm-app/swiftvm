import AppKit
import Observation

/// A virtual machine in the library: its bundle, configuration and live state.
@MainActor
@Observable
public final class VirtualMachine: Identifiable {
    public nonisolated let id: UUID
    public let bundle: VMBundle
    /// The guest's serial console. It stays the same across restarts.
    public nonisolated let console: SerialConsole
    public private(set) var configuration: VMConfiguration
    public private(set) var state: VMState
    /// The most recent error; cleared when the user dismisses it or the next operation starts.
    public var lastError: VMErrorInfo?
    /// Bytes the machine's disks occupy on the host.
    public private(set) var allocatedDiskSize: UInt64 = 0
    /// Points the machine can go back to, oldest first.
    public private(set) var snapshots: [VMSnapshot] = []
    /// Work in progress on the machine's files. Until it is over the machine can't be started or stopped.
    public private(set) var activity: VMActivity?

    /// The account to set up on the first boot after installation. Kept in memory only: if the app quits
    /// before that boot, the guest shows its own setup assistant instead.
    @ObservationIgnored public var pendingProvisioning: GuestProvisioning?

    @ObservationIgnored public weak var backendProvider: (any VMBackendProvider)?
    @ObservationIgnored public var onConfigurationChange: (@MainActor (VirtualMachine) -> Void)?
    /// Called when the guest has been resumed from saved memory, where it believes no time has passed.
    @ObservationIgnored public var onResume: (@MainActor (VirtualMachine) -> Void)?
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

    @ObservationIgnored private var backend: (any VMBackend)?
    @ObservationIgnored private var restartsAfterStop = false
    @ObservationIgnored private var shutdownRequestExpiry: Task<Void, Never>?
    /// The guest has shut down for a restart and its start is about to begin.
    @ObservationIgnored private var isAboutToRestart = false
    /// A pause or resume is under way. Neither has a state of its own.
    @ObservationIgnored private var isChangingPause = false

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
    }

    public convenience init(bundle: VMBundle) throws {
        try self.init(bundle: bundle, configuration: bundle.loadConfiguration())
    }

    public var name: String { configuration.name }

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

    public func refreshDiskUsage() {
        allocatedDiskSize = bundle.allocatedSize(of: configuration.disks.filter { !$0.readOnly })
    }

    // MARK: Lifecycle

    /// Boots the machine, or restores it if it was suspended.
    ///
    /// - Parameter inRecovery: Boot a stopped macOS guest into its recovery environment.
    public func start(inRecovery: Bool = false) async {
        guard activity == nil else { return }
        await performStart(inRecovery: inRecovery)
    }

    private func performStart(inRecovery: Bool = false) async {
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
            if restoring {
                onResume?(self)
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
    public func shutDown() async {
        guard activity == nil, state == .running, let backend else { return }
        if backend.canRequestStop {
            do {
                try backend.requestStop()
                state = .stopping
                expireShutdownRequest(after: shutdownRequestTimeout)
                return
            } catch {
                // Fall through to a forced stop.
            }
        }
        await forceStop()
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

    public func restart() async {
        guard activity == nil, state == .running else { return }
        restartsAfterStop = true
        await shutDown()
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
            await performStart()
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
        defer { self.activity = nil }
        guard state == .stopped else { throw VMError.notStopped(name: name, state) }
        return try await operation()
    }

    /// Claims the machine for work on its files. Throws if it is already claimed or in the middle of
    /// starting up or shutting down.
    private func begin(_ activity: VMActivity) throws {
        if let current = self.activity {
            throw VMError.busy(name: name, current)
        }
        guard !state.isTransitioning, !isAboutToRestart, !isChangingPause else {
            throw VMError.invalidConfiguration("“\(name)” is busy starting up or shutting down. Try again in a moment.")
        }
        self.activity = activity
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
