import Foundation

/// The persisted description of a virtual machine (`config.json` inside the bundle).
///
/// Decoding is tolerant: every section added after schema version 1 must decode with a default so that
/// older bundles keep opening.
public struct VMConfiguration: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var os: GuestOS
    public var engine: VMEngineKind
    public var cpuCount: Int
    /// Guest memory in bytes.
    public var memorySize: UInt64
    public var disks: [DiskConfiguration]
    public var display: DisplayConfiguration
    public var networkInterfaces: [NetworkInterfaceConfiguration]
    public var sharedFolders: [SharedFolder]
    public var audio: AudioConfiguration
    public var boot: BootConfiguration
    public var usb: USBConfiguration
    public var ssh: SSHConfiguration
    public var installation: InstallationConfiguration
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        os: GuestOS,
        engine: VMEngineKind? = nil,
        cpuCount: Int,
        memorySize: UInt64,
        disks: [DiskConfiguration],
        display: DisplayConfiguration = .init(),
        networkInterfaces: [NetworkInterfaceConfiguration] = [],
        sharedFolders: [SharedFolder] = [],
        audio: AudioConfiguration = .init(),
        boot: BootConfiguration = .init(),
        usb: USBConfiguration = .init(),
        ssh: SSHConfiguration = .init(),
        installation: InstallationConfiguration = .init(),
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.os = os
        self.engine = engine ?? .default(for: os.family)
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.disks = disks
        self.display = display
        self.networkInterfaces = networkInterfaces
        self.sharedFolders = sharedFolders
        self.audio = audio
        self.boot = boot
        self.usb = usb
        self.ssh = ssh
        self.installation = installation
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(.schemaVersion, default: 1)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw VMConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(GuestOS.self, forKey: .os)
        engine = try c.decode(.engine, default: .default(for: os.family))
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memorySize = try c.decode(UInt64.self, forKey: .memorySize)
        disks = try c.decode(.disks, default: [])
        display = try c.decode(.display, default: .init())
        networkInterfaces = try c.decode(.networkInterfaces, default: [])
        sharedFolders = try c.decode(.sharedFolders, default: [])
        audio = try c.decode(.audio, default: .init())
        boot = try c.decode(.boot, default: .init())
        usb = try c.decode(.usb, default: .init())
        ssh = try c.decode(.ssh, default: .init())
        installation = try c.decode(.installation, default: .init())
        createdAt = try c.decode(.createdAt, default: Date())
    }

    /// Whether the guest mounts shared folders by itself. macOS guests always do; Linux guests do when
    /// SwiftVM set them up on first boot.
    public var mountsSharedFoldersAutomatically: Bool {
        switch os.family {
        case .macOS: true
        case .linux: installation.attachesSeedImage
        case .windows: false
        }
    }

    /// The disk the guest boots from.
    public var systemDisk: DiskConfiguration? { disks.first }

    /// Total capacity of all writable disks, in bytes.
    public var totalDiskCapacity: UInt64 {
        disks.filter { !$0.readOnly }.reduce(0) { $0 + $1.capacity }
    }
}

public enum VMConfigurationError: Error, LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "This virtual machine was created by a newer version of SwiftVM (schema \(version))."
        }
    }
}

// MARK: - Storage

public struct DiskConfiguration: Codable, Sendable, Hashable, Identifiable {
    public enum Bus: String, Codable, Sendable, Hashable, CaseIterable {
        case virtio
        case nvme
        case usb
    }

    public enum Format: String, Codable, Sendable, Hashable {
        /// Apple Sparse Image Format (DiskImageKit).
        case asif
        /// Raw image; kept sparse by APFS.
        case raw
    }

    public var id: UUID
    /// File name relative to the bundle directory.
    public var fileName: String
    /// Virtual size in bytes.
    public var capacity: UInt64
    public var bus: Bus
    public var format: Format
    public var readOnly: Bool

    public init(
        id: UUID = UUID(),
        fileName: String,
        capacity: UInt64,
        bus: Bus = .virtio,
        format: Format = .asif,
        readOnly: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.capacity = capacity
        self.bus = bus
        self.format = format
        self.readOnly = readOnly
    }
}

// MARK: - Display

public struct DisplayConfiguration: Codable, Sendable, Hashable {
    public var widthInPixels: Int
    public var heightInPixels: Int
    public var pixelsPerInch: Int
    /// Resize the guest display to follow the window.
    public var automaticallyResizes: Bool

    public init(widthInPixels: Int = 1920, heightInPixels: Int = 1200, pixelsPerInch: Int = 144, automaticallyResizes: Bool = true) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.pixelsPerInch = pixelsPerInch
        self.automaticallyResizes = automaticallyResizes
    }
}

// MARK: - Networking

public struct NetworkInterfaceConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Identifier of the app-managed network this interface attaches to.
    public var networkID: String
    /// Colon-separated MAC address, e.g. `02:1a:2b:3c:4d:5e`.
    public var macAddress: String
    /// IPv4 address reserved for this interface on its network, if any.
    public var ipv4Address: String?
    public var portForwards: [PortForward]
    /// Whether the virtual cable is plugged in when the machine starts.
    public var isConnected: Bool

    public init(
        id: UUID = UUID(),
        networkID: String = NetworkInterfaceConfiguration.defaultNetworkID,
        macAddress: String = MACAddress.random().description,
        ipv4Address: String? = nil,
        portForwards: [PortForward] = [],
        isConnected: Bool = true
    ) {
        self.id = id
        self.networkID = networkID
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
        self.portForwards = portForwards
        self.isConnected = isConnected
    }

    public static let defaultNetworkID = "default"
}

public struct PortForward: Codable, Sendable, Hashable, Identifiable {
    public enum TransportProtocol: String, Codable, Sendable, Hashable, CaseIterable {
        case tcp
        case udp
    }

    public var id: UUID
    public var transport: TransportProtocol
    public var hostPort: UInt16
    public var guestPort: UInt16

    public init(id: UUID = UUID(), transport: TransportProtocol = .tcp, hostPort: UInt16, guestPort: UInt16) {
        self.id = id
        self.transport = transport
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

// MARK: - Sharing

public struct SharedFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Name the folder appears under inside the guest.
    public var name: String
    /// Absolute host path.
    public var path: String
    public var readOnly: Bool

    public init(id: UUID = UUID(), name: String, path: String, readOnly: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.readOnly = readOnly
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

// MARK: - Devices

public struct AudioConfiguration: Codable, Sendable, Hashable {
    public var outputEnabled: Bool
    public var inputEnabled: Bool

    public init(outputEnabled: Bool = true, inputEnabled: Bool = false) {
        self.outputEnabled = outputEnabled
        self.inputEnabled = inputEnabled
    }
}

public struct USBConfiguration: Codable, Sendable, Hashable {
    public struct DeviceRule: Codable, Sendable, Hashable, Identifiable {
        public var vendorID: UInt16
        public var productID: UInt16
        public var name: String

        public var id: String { String(format: "%04x:%04x", vendorID, productID) }

        public init(vendorID: UInt16, productID: UInt16, name: String) {
            self.vendorID = vendorID
            self.productID = productID
            self.name = name
        }
    }

    /// Devices that attach to this machine automatically whenever they are available.
    public var autoConnect: [DeviceRule]

    public init(autoConnect: [DeviceRule] = []) {
        self.autoConnect = autoConnect
    }
}

public struct BootConfiguration: Codable, Sendable, Hashable {
    /// UEFI Secure Boot (Linux and Windows guests).
    public var secureBoot: Bool
    /// Expose Rosetta so x86-64 Linux binaries run in the guest.
    public var rosetta: Bool

    public init(secureBoot: Bool = false, rosetta: Bool = false) {
        self.secureBoot = secureBoot
        self.rosetta = rosetta
    }
}

public struct SSHConfiguration: Codable, Sendable, Hashable {
    /// Host alias written to the SSH config, e.g. `ubuntu-26-04`.
    public var alias: String
    public var user: String
    public var port: UInt16
    /// Private key path used for this host; `nil` lets ssh pick its defaults.
    public var identityFile: String?

    public init(alias: String = "", user: String = "", port: UInt16 = 22, identityFile: String? = nil) {
        self.alias = alias
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

public struct InstallationConfiguration: Codable, Sendable, Hashable {
    /// Absolute path of installer media (ISO) attached as a USB drive until ejected.
    public var installMediaPath: String?
    /// Attach `seed.iso` from the bundle (cloud-init / unattended setup data).
    public var attachesSeedImage: Bool
    /// The guest finished its first-boot setup.
    public var isProvisioned: Bool

    public init(installMediaPath: String? = nil, attachesSeedImage: Bool = false, isProvisioned: Bool = false) {
        self.installMediaPath = installMediaPath
        self.attachesSeedImage = attachesSeedImage
        self.isProvisioned = isProvisioned
    }
}

// MARK: - Decoding helpers

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue()
    }
}
