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
        /// Quit the app. Refused while a machine is running, and while one is being created unless
        /// ``ControlRequest/cancelsCreations`` is set.
        case quit
        /// Throw away a suspended machine's saved memory, so that it starts up fresh.
        case discardState = "discard-state"
        /// Share a host folder with the machine (applies to a running guest immediately).
        case share
        case unshare
        /// Everything the app knows about one machine.
        case info
        /// Plug a disc or disk image in as a USB drive (applies to a running guest immediately).
        case attach
        case eject
        /// Grow the machine's disk.
        case resize
        /// Make a copy of a machine that is shut down.
        case clone
        case snapshot
        case snapshots
        case revert
        case deleteSnapshot = "delete-snapshot"
        /// Give a snapshot the name in ``ControlRequest/name``.
        case renameSnapshot = "rename-snapshot"
        /// Forward a port on this Mac to a port in the machine.
        case forward
        case unforward
        /// Attach to the machine's serial console. After the answer, the connection carries the console's
        /// bytes in both directions until either side closes it.
        case console
        /// Connect to ``ControlRequest/port`` in the guest over the machine's socket device (virtio-vsock),
        /// which needs no network. After the answer, the connection carries that conversation.
        case vsock
        /// Plug the machine's network cable in, or pull it.
        case plug
        case unplug
        /// Install the guest tools in a running guest: over SSH, or with ``ControlRequest/usesDisc`` by
        /// plugging in the guest tools disc for someone to install from inside the guest.
        case installTools = "install-tools"
        /// Turn sharing the clipboard with the machine on or off, as ``ControlRequest/isOn`` says.
        case shareClipboard = "share-clipboard"
        /// The USB devices this Mac has given the app, and which machine has each.
        case usbList = "usb-list"
        /// Hand the USB device named by ``ControlRequest/usbDevice`` to a running machine.
        case usbAttach = "usb-attach"
        /// Give it back to this Mac.
        case usbDetach = "usb-detach"
        /// Have a machine take that USB device by itself whenever both are there, or stop, as
        /// ``ControlRequest/isOn`` says.
        case usbAuto = "usb-auto"
    }

    public struct ForwardParameters: Codable, Sendable, Equatable {
        public var hostPort: UInt16
        /// `nil` means the same port as on the host.
        public var guestPort: UInt16?
        public var udp: Bool
        /// Accept connections from other devices on the network, not only from this Mac.
        public var allowsOtherDevices: Bool

        public init(hostPort: UInt16, guestPort: UInt16? = nil, udp: Bool = false, allowsOtherDevices: Bool = false) {
            self.hostPort = hostPort
            self.guestPort = guestPort
            self.udp = udp
            self.allowsOtherDevices = allowsOtherDevices
        }
    }

    public struct DriveParameters: Codable, Sendable, Equatable {
        /// Absolute host path of the image. For `eject`, a file name is enough.
        public var path: String
        public var readOnly: Bool

        public init(path: String, readOnly: Bool = false) {
            self.path = path
            self.readOnly = readOnly
        }
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
    public var drive: DriveParameters?
    /// The name for a copy of a machine or for a new snapshot, or the new name of an existing snapshot.
    public var name: String?
    /// Name or UUID of the snapshot the command applies to.
    public var snapshot: String?
    /// The disk size to grow to, in GB.
    public var diskGigabytes: Int?
    public var forward: ForwardParameters?
    /// For `quit`: give up the machines that are still being created instead of refusing to quit.
    public var cancelsCreations: Bool?
    /// For `vsock`: the port in the guest to connect to.
    public var port: UInt32?
    /// For `install-tools`: plug in the guest tools disc instead of installing over SSH.
    public var usesDisc: Bool?
    /// For `install-tools` over SSH: the guest account's password, which macOS wants before it lets
    /// anything be installed.
    public var password: String?
    /// For `share-clipboard` and `usb-auto`: whether it is to be on.
    public var isOn: Bool?
    /// For the `usb-` commands that deal with one device: its number in the list, its `vendor:product`,
    /// its serial number or its name.
    public var usbDevice: String?

    public init(
        command: Command, machine: String? = nil, create: CreateParameters? = nil, share: ShareParameters? = nil,
        drive: DriveParameters? = nil, name: String? = nil, snapshot: String? = nil, diskGigabytes: Int? = nil,
        forward: ForwardParameters? = nil, cancelsCreations: Bool? = nil, port: UInt32? = nil, usesDisc: Bool? = nil,
        password: String? = nil, isOn: Bool? = nil, usbDevice: String? = nil
    ) {
        self.command = command
        self.machine = machine
        self.create = create
        self.share = share
        self.drive = drive
        self.name = name
        self.snapshot = snapshot
        self.diskGigabytes = diskGigabytes
        self.forward = forward
        self.cancelsCreations = cancelsCreations
        self.port = port
        self.usesDisc = usesDisc
        self.password = password
        self.isOn = isOn
        self.usbDevice = usbDevice
    }
}

extension ControlRequest.Command {
    /// Whether a successful answer is followed by a byte stream instead of further requests.
    public var opensStream: Bool {
        self == .console || self == .vsock
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
    /// Only filled in for `info`.
    public var details: MachineDetails?

    public init(
        id: UUID, name: String, state: String, system: String, address: String?, sshAlias: String?,
        cpuCount: Int, memorySize: UInt64, diskAllocated: UInt64, diskCapacity: UInt64, details: MachineDetails? = nil
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
        self.details = details
    }
}

/// The parts of a machine that don't fit in a table row.
public struct MachineDetails: Codable, Sendable, Equatable {
    public struct Drive: Codable, Sendable, Equatable {
        public var path: String
        public var readOnly: Bool

        public init(path: String, readOnly: Bool) {
            self.path = path
            self.readOnly = readOnly
        }
    }

    public struct Folder: Codable, Sendable, Equatable {
        public var name: String
        public var path: String
        public var readOnly: Bool

        public init(name: String, path: String, readOnly: Bool) {
            self.name = name
            self.path = path
            self.readOnly = readOnly
        }
    }

    public struct Forward: Codable, Sendable, Equatable {
        public var hostPort: UInt16
        public var guestPort: UInt16
        public var udp: Bool
        public var allowsOtherDevices: Bool
        /// `listening`, `starting`, the reason the port couldn't be opened, or `nil` while the machine isn't running.
        public var status: String?

        public init(hostPort: UInt16, guestPort: UInt16, udp: Bool, allowsOtherDevices: Bool, status: String?) {
            self.hostPort = hostPort
            self.guestPort = guestPort
            self.udp = udp
            self.allowsOtherDevices = allowsOtherDevices
            self.status = status
        }
    }

    /// Where the machine's bundle is on the host.
    public var location: String
    public var macAddress: String?
    public var drives: [Drive]
    public var sharedFolders: [Folder]
    public var forwards: [Forward]?
    public var snapshotCount: Int
    /// What is known of the guest tools, for guests that can have them.
    public var guestTools: GuestTools?
    /// Whether the clipboard is shared with the machine. `nil` from an app that doesn't say.
    public var sharesClipboard: Bool?
    /// The USB devices of this Mac that the machine's guest has right now.
    public var usbDevices: [USBDeviceSummary]?
    /// The devices the machine takes by itself whenever they are there, each as its name and
    /// `vendor:product`.
    public var usbAutoConnect: [String]?

    public struct GuestTools: Codable, Sendable, Equatable {
        /// The version of the agent that is connected. `nil` while none is.
        public var version: String?
        /// The guest's kernel, as its agent reports it.
        public var kernel: String?

        public init(version: String?, kernel: String?) {
            self.version = version
            self.kernel = kernel
        }
    }

    public init(
        location: String, macAddress: String?, drives: [Drive], sharedFolders: [Folder], forwards: [Forward]? = nil,
        snapshotCount: Int, guestTools: GuestTools? = nil, sharesClipboard: Bool? = nil,
        usbDevices: [USBDeviceSummary]? = nil, usbAutoConnect: [String]? = nil
    ) {
        self.location = location
        self.macAddress = macAddress
        self.drives = drives
        self.sharedFolders = sharedFolders
        self.forwards = forwards
        self.snapshotCount = snapshotCount
        self.guestTools = guestTools
        self.sharesClipboard = sharesClipboard
        self.usbDevices = usbDevices
        self.usbAutoConnect = usbAutoConnect
    }
}

/// A USB device that this Mac has given the app.
public struct USBDeviceSummary: Codable, Sendable, Equatable {
    /// The device's number for as long as it stays plugged in. The next time it has another.
    public var id: UInt64
    public var name: String
    /// Vendor and product, as in `0781:5581`.
    public var identifier: String
    public var manufacturer: String?
    public var serialNumber: String?
    /// The machine whose guest has the device, if one does.
    public var machine: String?

    public init(id: UInt64, name: String, identifier: String, manufacturer: String? = nil, serialNumber: String? = nil, machine: String? = nil) {
        self.id = id
        self.name = name
        self.identifier = identifier
        self.manufacturer = manufacturer
        self.serialNumber = serialNumber
        self.machine = machine
    }
}

/// One snapshot of a machine.
public struct SnapshotSummary: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Going back to it resumes the guest where it was instead of booting it.
    public var includesMemory: Bool

    public init(id: UUID, name: String, createdAt: Date, includesMemory: Bool) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.includesMemory = includesMemory
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    /// The machines the command touched, or all of them for `list`.
    public var machines: [MachineSummary]
    /// The machine's snapshots, for the commands that deal with them.
    public var snapshots: [SnapshotSummary]?
    /// The USB devices this Mac has given the app, for `usb-list`.
    public var usbDevices: [USBDeviceSummary]?
    /// Something for the person at the terminal to read once the command has done its part, such as
    /// what is left for them to do.
    public var note: String?

    public init(
        ok: Bool, error: String? = nil, machines: [MachineSummary] = [], snapshots: [SnapshotSummary]? = nil, note: String? = nil,
        usbDevices: [USBDeviceSummary]? = nil
    ) {
        self.ok = ok
        self.error = error
        self.machines = machines
        self.snapshots = snapshots
        self.note = note
        self.usbDevices = usbDevices
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

/// Where the app listens and where its generated files live.
public enum ControlPaths {
    /// Environment variable that points the app and the `swiftvm` tool at another data directory, for
    /// a copy with machines of its own.
    public static let homeEnvironmentKey = "SWIFTVM_HOME"

    /// The data directory of the copy of SwiftVM that this program is part of. The app keeps its
    /// machines there and listens there, and the `swiftvm` tool looks for the app there.
    public static var applicationSupport: URL {
        applicationSupport(for: .current, environment: ProcessInfo.processInfo.environment)
    }

    /// `SWIFTVM_HOME` goes first. Without it the app and its development copy each have a folder of
    /// their own in Application Support.
    static func applicationSupport(for identity: AppIdentity, environment: [String: String]) -> URL {
        if let override = environment[homeEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return URL.applicationSupportDirectory.appending(path: identity.dataDirectoryName, directoryHint: .isDirectory)
    }

    public static var socket: URL { applicationSupport.appending(path: "control.sock") }
    public static var sshConfig: URL { applicationSupport.appending(path: "ssh_config") }
}
