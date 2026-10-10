import AppKit
import Observation

/// A virtual machine in the library: its bundle, configuration and live state.
@MainActor
@Observable
public final class VirtualMachine: Identifiable {
    public nonisolated let id: UUID
    public let bundle: VMBundle
    public private(set) var configuration: VMConfiguration
    public private(set) var state: VMState
    /// The most recent error; cleared when the user dismisses it or the next operation starts.
    public var lastError: VMErrorInfo?
    /// Bytes the machine's disks occupy on the host.
    public private(set) var allocatedDiskSize: UInt64 = 0

    @ObservationIgnored public weak var backendProvider: (any VMBackendProvider)?
    @ObservationIgnored public var onConfigurationChange: (@MainActor (VirtualMachine) -> Void)?
    @ObservationIgnored private var backend: (any VMBackend)?
    @ObservationIgnored private var restartsAfterStop = false

    public init(bundle: VMBundle, configuration: VMConfiguration) {
        self.id = configuration.id
        self.bundle = bundle
        self.configuration = configuration
        self.state = bundle.hasSavedState ? .suspended : .stopped
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
        }
        onConfigurationChange?(self)
    }

    public func refreshDiskUsage() {
        allocatedDiskSize = bundle.allocatedSize(of: configuration.disks.filter { !$0.readOnly })
    }

    // MARK: Lifecycle

    /// Boots the machine, or restores it if it was suspended.
    public func start() async {
        guard state == .stopped || state == .suspended else { return }
        let restoring = state == .suspended && bundle.hasSavedState
        lastError = nil
        state = restoring ? .restoring : .starting
        do {
            guard let backendProvider else { throw VMError.noBackendProvider }
            let backend = try await backendProvider.makeBackend(for: self)
            backend.eventHandler = { [weak self] event in self?.handle(event) }
            self.backend = backend
            try await backend.start(restoringFrom: restoring ? bundle.savedStateURL : nil)
            if restoring {
                bundle.removeSavedState()
            }
            state = .running
        } catch {
            tearDownBackend()
            state = restoring ? .suspended : .stopped
            report(error, title: restoring ? "Couldn't resume “\(name)”" : "Couldn't start “\(name)”")
        }
    }

    /// Asks the guest to shut down. Falls back to a forced stop when the guest can't be asked.
    public func shutDown() async {
        guard state == .running, let backend else { return }
        if backend.canRequestStop {
            do {
                try backend.requestStop()
                state = .stopping
                return
            } catch {
                // Fall through to a forced stop.
            }
        }
        await forceStop()
    }

    /// Stops the machine immediately, like pulling the power cord.
    public func forceStop() async {
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
        guard state == .running, let backend else { return }
        do {
            try await backend.pause()
            state = .paused
        } catch {
            report(error, title: "Couldn't pause “\(name)”")
        }
    }

    public func resume() async {
        guard state == .paused, let backend else { return }
        do {
            try await backend.resume()
            state = .running
        } catch {
            report(error, title: "Couldn't resume “\(name)”")
        }
    }

    /// Saves the guest's state to disk and releases its memory.
    public func suspend() async {
        guard state == .running || state == .paused, let backend else { return }
        let wasRunning = state == .running
        state = .suspending
        do {
            if wasRunning {
                try await backend.pause()
            }
            try await backend.saveState(to: bundle.savedStateURL)
            try await backend.stop()
            tearDownBackend()
            state = .suspended
            refreshDiskUsage()
        } catch {
            bundle.removeSavedState()
            if wasRunning {
                try? await backend.resume()
                state = .running
            } else {
                state = .paused
            }
            report(error, title: "Couldn't suspend “\(name)”")
        }
    }

    public func restart() async {
        guard state == .running else { return }
        restartsAfterStop = true
        await shutDown()
    }

    /// Throws away the suspended state so the next start is a cold boot.
    public func discardSavedState() {
        guard state == .suspended else { return }
        bundle.removeSavedState()
        state = .stopped
    }

    // MARK: Backend events

    private func handle(_ event: VMBackendEvent) {
        switch event {
        case .guestDidStop:
            let restart = restartsAfterStop
            finishStop()
            if restart {
                Task { await start() }
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
        tearDownBackend()
        state = .stopped
        refreshDiskUsage()
    }

    private func tearDownBackend() {
        guard backend != nil else { return }
        backend?.eventHandler = nil
        backend?.invalidate()
        backend = nil
        backendProvider?.backendDidStop(for: self)
    }

    private func report(_ error: any Error, title: String) {
        lastError = VMErrorInfo(title: title, message: error.localizedDescription)
    }
}
