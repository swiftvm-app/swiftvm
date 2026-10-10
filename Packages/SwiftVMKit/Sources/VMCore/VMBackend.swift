import AppKit

/// Lifecycle state of a virtual machine as shown in the UI.
public enum VMState: String, Sendable, Hashable {
    case stopped
    case starting
    case running
    /// Paused in memory; still holds host RAM.
    case paused
    /// Writing guest state to disk.
    case suspending
    /// State saved to disk; no host resources in use.
    case suspended
    /// Loading saved state back into memory.
    case restoring
    case stopping

    /// The machine currently owns a running or paused guest.
    public var isActive: Bool {
        switch self {
        case .stopped, .suspended: false
        default: true
        }
    }

    public var isTransitioning: Bool {
        switch self {
        case .starting, .suspending, .restoring, .stopping: true
        default: false
        }
    }
}

/// Something a backend reports on its own, outside of a requested operation.
public enum VMBackendEvent: Sendable {
    /// The guest shut itself down.
    case guestDidStop
    /// The machine stopped because of an error.
    case stoppedWithError(String)
    /// A network interface lost its attachment.
    case networkDisconnected(String)
}

/// A running instance of a virtual machine in one engine (Virtualization.framework or QEMU).
@MainActor
public protocol VMBackend: AnyObject {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)? { get set }

    /// The view that shows the guest display and receives input. Created once and reused.
    var displayView: NSView { get }

    /// Whether the guest can be asked to shut down gracefully right now.
    var canRequestStop: Bool { get }

    /// Boots the guest, or restores it from `savedState` and resumes it.
    func start(restoringFrom savedState: URL?) async throws
    /// Asks the guest to shut down (like pressing the power button).
    func requestStop() throws
    /// Stops the guest immediately.
    func stop() async throws
    func pause() async throws
    func resume() async throws
    /// Saves the state of a paused guest.
    func saveState(to url: URL) async throws

    /// Plugs or unplugs the virtual network cable of an interface.
    func setNetworkInterface(_ id: UUID, connected: Bool) throws
    /// Replaces the folders shared with the running guest.
    func setSharedFolders(_ folders: [SharedFolder]) throws

    /// Lets go of host resources (network attachments, the display) after the guest has stopped, without
    /// waiting for the backend object itself to be deallocated.
    func invalidate()
}

/// Creates backends and manages the host resources (networks, …) they hold.
@MainActor
public protocol VMBackendProvider: AnyObject {
    func makeBackend(for machine: VirtualMachine) async throws -> any VMBackend
    /// Called after a machine's backend is gone so shared resources can be released.
    func backendDidStop(for machine: VirtualMachine)
}

/// An error surfaced to the user for a specific machine.
public struct VMErrorInfo: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public enum VMError: Error, LocalizedError {
    case noBackendProvider
    case unsupportedEngine(VMEngineKind)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .noBackendProvider:
            "No virtualization engine is available."
        case .unsupportedEngine(let engine):
            "The \(engine.rawValue) engine isn't available in this build."
        case .invalidConfiguration(let reason):
            reason
        }
    }
}
