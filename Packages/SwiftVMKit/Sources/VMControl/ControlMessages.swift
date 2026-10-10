import Foundation

/// A request sent to the running app over its control socket (one JSON document per line).
public struct ControlRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable, CaseIterable {
        case list
        case start
        /// Ask the guest to shut down and wait until it has.
        case stop
        case forceStop = "force-stop"
        case suspend
        case pause
        case resume
        case restart
        /// Show the machine's window.
        case open
        case create
        case delete
        /// Quit the app. Refused while a machine is running.
        case quit
        /// Share a host folder with the machine (applies to a running guest immediately).
        case share
        case unshare
    }

    public struct ShareParameters: Codable, Sendable, Equatable {
        /// Absolute host path of the folder.
        public var path: String
        public var readOnly: Bool

        public init(path: String, readOnly: Bool = false) {
            self.path = path
            self.readOnly = readOnly
        }
    }

    public struct CreateParameters: Codable, Sendable, Equatable {
        /// What to install: `macos`, or a Linux catalog identifier such as `ubuntu-26.04`.
        public var distribution: String
        public var name: String?
        public var cpuCount: Int?
        public var memoryGigabytes: Int?
        public var diskGigabytes: Int?
        public var user: String?
        public var password: String?
        /// macOS: absolute path of a restore image (IPSW) to install instead of downloading the latest.
        public var restoreImagePath: String?
        public var start: Bool

        /// The `distribution` value that installs macOS.
        public static let macOS = "macos"

        public init(
            distribution: String, name: String? = nil, cpuCount: Int? = nil, memoryGigabytes: Int? = nil,
            diskGigabytes: Int? = nil, user: String? = nil, password: String? = nil, restoreImagePath: String? = nil,
            start: Bool = true
        ) {
            self.distribution = distribution
            self.name = name
            self.cpuCount = cpuCount
            self.memoryGigabytes = memoryGigabytes
            self.diskGigabytes = diskGigabytes
            self.user = user
            self.password = password
            self.restoreImagePath = restoreImagePath
            self.start = start
        }
    }

    public var command: Command
    /// Name, SSH alias or UUID of the machine the command applies to.
    public var machine: String?
    public var create: CreateParameters?
    public var share: ShareParameters?

    public init(command: Command, machine: String? = nil, create: CreateParameters? = nil, share: ShareParameters? = nil) {
        self.command = command
        self.machine = machine
        self.create = create
        self.share = share
    }
}

/// What the app knows about one machine.
public struct MachineSummary: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var state: String
    public var system: String
    public var address: String?
    public var sshAlias: String?
    public var cpuCount: Int
    public var memorySize: UInt64
    public var diskAllocated: UInt64
    public var diskCapacity: UInt64

    public init(
        id: UUID, name: String, state: String, system: String, address: String?, sshAlias: String?,
        cpuCount: Int, memorySize: UInt64, diskAllocated: UInt64, diskCapacity: UInt64
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.system = system
        self.address = address
        self.sshAlias = sshAlias
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskAllocated = diskAllocated
        self.diskCapacity = diskCapacity
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    /// The machines the command touched, or all of them for `list`.
    public var machines: [MachineSummary]

    public init(ok: Bool, error: String? = nil, machines: [MachineSummary] = []) {
        self.ok = ok
        self.error = error
        self.machines = machines
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

/// Where the app listens and where its generated files live.
public enum ControlPaths {
    /// Same rule as `VMLibrary.defaultRootDirectory`: `SWIFTVM_HOME` selects another data directory.
    public static var applicationSupport: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTVM_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return URL.applicationSupportDirectory.appending(path: "SwiftVM", directoryHint: .isDirectory)
    }

    public static var socket: URL { applicationSupport.appending(path: "control.sock") }
    public static var sshConfig: URL { applicationSupport.appending(path: "ssh_config") }
}
