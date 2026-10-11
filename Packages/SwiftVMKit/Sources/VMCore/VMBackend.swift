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
    /// A USB device that the guest had been handed is gone: pulled out, or taken back by the host.
    case usbDeviceDisconnected(USBDevice.ID)
}

/// How a guest was asked to shut down.
public enum ShutdownRequest: Sendable, Hashable {
    /// Through its agent, which shuts it down whatever is on its screen.
    case agent
    /// With the power button. Some guests answer that with a question on their screen.
    case powerButton
    /// It couldn't be asked, and was stopped outright.
    case forced
}

/// How a machine should start.
public struct VMStartOptions: Sendable, Hashable {
    /// Restore the guest from this saved state instead of booting it.
    public var savedState: URL?
    /// Account to set up on the first boot after installation (macOS guests).
    public var provisioning: GuestProvisioning?
    /// Boot into the recovery environment (macOS guests).
    public var startsInRecovery: Bool

    public init(savedState: URL? = nil, provisioning: GuestProvisioning? = nil, startsInRecovery: Bool = false) {
        self.savedState = savedState
        self.provisioning = provisioning
        self.startsInRecovery = startsInRecovery
    }
}

/// The account a freshly installed guest sets up by itself, so nobody has to click through first-run setup.
///
/// macOS only looks at this on the first boot after installation, and only from macOS 27 on.
public struct GuestProvisioning: Sendable, Hashable {
    public var fullName: String
    public var userName: String
    public var password: String
    public var logsInAutomatically: Bool
    /// Turn on Remote Login (SSH) in the guest.
    public var enablesRemoteLogin: Bool

    public init(fullName: String, userName: String, password: String, logsInAutomatically: Bool = true, enablesRemoteLogin: Bool = true) {
        self.fullName = fullName
        self.userName = userName
        self.password = password
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    /// The first major macOS version that sets itself up from these options. Older guests ignore them.
    public static let minimumMacOSMajorVersion = 27

    /// Why `userName` can't be used as a macOS account name, or `nil` if it can.
    public static func problem(withUserName userName: String) -> String? {
        guard let first = userName.first else { return "Enter an account name." }
        let isValid = first.isASCII && first.isLowercase
            && userName.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            && userName.count <= 32
        if !isValid {
            return "Use lowercase letters, digits, “-”, “_” and “.”, starting with a letter."
        }
        if reservedUserNames.contains(userName) {
            return "“\(userName)” is reserved by macOS. Choose another account name."
        }
        return nil
    }

    private static let reservedUserNames: Set<String> = ["root", "admin", "daemon", "nobody", "guest", "wheel", "staff"]
}

/// A running instance of a virtual machine in one engine (Virtualization.framework or QEMU).
@MainActor
public protocol VMBackend: AnyObject {
    var eventHandler: (@MainActor (VMBackendEvent) -> Void)? { get set }

    /// The view that shows the guest display and receives input. Created once and reused.
    var displayView: NSView { get }

    /// Whether the guest can be asked to shut down gracefully right now.
    var canRequestStop: Bool { get }

    /// Boots the guest, or restores it from saved state and resumes it.
    func start(options: VMStartOptions) async throws
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
    /// Plugs a disc or disk image into the running guest as a USB drive.
    func attachRemovableImage(_ image: RemovableImage) async throws
    /// Unplugs a drive the guest started with or that was plugged in later.
    func detachRemovableImage(_ id: UUID) async throws
    /// Sends shortcuts such as Command-Tab to the guest, or leaves them to the host.
    func setCapturesSystemKeys(_ capturesSystemKeys: Bool)
    /// Hands a USB device of this Mac to the running guest. The Mac is without it until it is detached.
    func attachUSBDevice(_ device: USBDevice) async throws
    /// Gives a USB device that the guest was handed back to this Mac.
    func detachUSBDevice(_ id: USBDevice.ID) async throws

    /// Connects to a port that something in the guest listens on, over the machine's socket device
    /// (virtio-vsock). The line doesn't run over the guest's network, so it is there when the network
    /// isn't. The connection is closed when the returned handle is released.
    func connectToGuest(port: UInt32) async throws -> FileHandle

    /// Lets go of host resources (network attachments, the display) after the guest has stopped, without
    /// waiting for the backend object itself to be deallocated.
    func invalidate()
}

extension VMBackend {
    // An engine that can't hand USB devices over says so when asked, and has none to give back.
    public func attachUSBDevice(_ device: USBDevice) async throws {
        throw VMError.invalidConfiguration("This virtual machine's engine can't take USB devices.")
    }

    public func detachUSBDevice(_ id: USBDevice.ID) async throws {}
}

/// Creates backends and manages the host resources (networks, …) they hold.
@MainActor
public protocol VMBackendProvider: AnyObject {
    /// - Parameter console: The guest's end of the machine's serial console, to wire up as its serial port.
    func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend
    /// Called after a machine's backend is gone so shared resources can be released.
    func backendDidStop(for machine: VirtualMachine)
}

/// Something to tell the user about a specific machine: most often an error, sometimes what is left for
/// them to do.
public struct VMErrorInfo: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var title: String
    public var message: String
    /// A command from the message that the user is meant to run somewhere else, to offer for copying.
    public var copyableText: String?

    public init(title: String, message: String, copyableText: String? = nil) {
        self.title = title
        self.message = message
        self.copyableText = copyableText
    }
}

public enum VMError: Error, LocalizedError {
    case noBackendProvider
    case unsupportedEngine(VMEngineKind)
    case invalidConfiguration(String)
    /// Something else is being done to the machine right now.
    case busy(name: String, VMActivity)
    /// The operation needs the machine to be shut down.
    case notStopped(name: String, VMState)
    /// The operation needs a guest that is up.
    case notRunning(name: String)

    public var errorDescription: String? {
        switch self {
        case .noBackendProvider:
            "No virtualization engine is available."
        case .unsupportedEngine(let engine):
            "The \(engine.rawValue) engine isn't available in this build."
        case .invalidConfiguration(let reason):
            reason
        case .busy(let name, let activity):
            "“\(name)” is busy (\(activity.label.lowercased())). Try again in a moment."
        case .notStopped(let name, let state):
            state == .suspended
                ? "“\(name)” is suspended. Resume it and shut it down first."
                : "Shut down “\(name)” first."
        case .notRunning(let name):
            "“\(name)” isn't running."
        }
    }
}

/// Work on a machine's files during which it can't be started, stopped or changed.
public enum VMActivity: Sendable, Hashable {
    case takingSnapshot
    case reverting
    case duplicating
    case resizingDisk

    public var label: String {
        switch self {
        case .takingSnapshot: "Taking Snapshot"
        case .reverting: "Reverting"
        case .duplicating: "Duplicating"
        case .resizingDisk: "Resizing Disk"
        }
    }
}
