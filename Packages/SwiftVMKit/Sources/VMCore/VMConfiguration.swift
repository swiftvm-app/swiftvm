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
    /// Disc and disk images plugged in as USB drives. They can be attached and ejected while the machine runs.
    public var removableImages: [RemovableImage]
    public var display: DisplayConfiguration
    public var keyboard: KeyboardConfiguration
    public var networkInterfaces: [NetworkInterfaceConfiguration]
    public var sharedFolders: [SharedFolder]
    public var clipboard: ClipboardConfiguration
    public var automation: AutomationConfiguration
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
        removableImages: [RemovableImage] = [],
        display: DisplayConfiguration = .init(),
        keyboard: KeyboardConfiguration = .init(),
        networkInterfaces: [NetworkInterfaceConfiguration] = [],
        sharedFolders: [SharedFolder] = [],
        clipboard: ClipboardConfiguration = .init(),
        automation: AutomationConfiguration = .init(),
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
        self.removableImages = removableImages
        self.display = display
        self.keyboard = keyboard
        self.networkInterfaces = networkInterfaces
        self.sharedFolders = sharedFolders
        self.clipboard = clipboard
        self.automation = automation
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
        keyboard = try c.decode(.keyboard, default: .init())
        networkInterfaces = try c.decode(.networkInterfaces, default: [])
        sharedFolders = try c.decode(.sharedFolders, default: [])
        clipboard = try c.decode(.clipboard, default: .init(isShared: os.family != .linux || engine != .qemu))
        // The old shared default never applied to accelerated Linux. Updating its guest tools must
        // not give it access to the Mac's clipboard without a choice made since support was added.
        if os.family == .linux && engine == .qemu && !clipboard.includesAcceleratedLinux {
            clipboard = .init(isShared: false)
        }
        automation = try c.decode(.automation, default: .init())
        audio = try c.decode(.audio, default: .init())
        boot = try c.decode(.boot, default: .init())
        usb = try c.decode(.usb, default: .init())
        ssh = try c.decode(.ssh, default: .init())
        installation = try c.decode(.installation, default: .init())
        createdAt = try c.decode(.createdAt, default: Date())
        if c.contains(.removableImages) {
            removableImages = try c.decode([RemovableImage].self, forKey: .removableImages)
        } else {
            // Before removable images existed, the one installer disc was part of the installation section.
            // It takes the machine's identifier so that it is the same drive every time this is read.
            let legacy = try c.decodeIfPresent(LegacyInstallation.self, forKey: .installation)
            if let path = legacy?.installMediaPath {
                removableImages = [RemovableImage(id: id, path: path, readOnly: true)]
            } else {
                removableImages = []
            }
        }
    }

    private struct LegacyInstallation: Decodable {
        var installMediaPath: String?
    }

    /// Whether the guest mounts shared folders by itself. macOS guests always do; Linux guests do when
    /// SwiftVM set them up on first boot.
    public var mountsSharedFoldersAutomatically: Bool {
        switch os.family {
        case .macOS: true
        // Through the virtio-fs device that their first-boot setup mounts. QEMU has a device per
        // folder instead, which the agent mounts.
        case .linux: installation.attachesSeedImage && engine == .virtualization
        case .windows: false
        }
    }

    /// Whether the guest answers the power button by asking the person at its screen. macOS puts up its
    /// "Are you sure you want to shut down?" dialog; other guests just shut down. A guest that is asked
    /// through its agent shuts down without a question either way.
    public var asksBeforeShuttingDown: Bool {
        os.family == .macOS
    }

    /// Whether the guest offers a login on its serial port. Linux systems with systemd do so on their own;
    /// macOS leaves its serial port unused.
    public var hasSerialConsole: Bool {
        os.family == .linux
    }

    /// The disk the guest boots from.
    public var systemDisk: DiskConfiguration? { disks.first }

    /// Whether the machine's disk can be kept compressed: that of a Linux machine, raw as Quick Create
    /// makes it, ASIF as an installer disc gets it, or compressed already, and that of a Windows machine,
    /// raw or compressed. A Mac's own files are stored compressed already, so its disk would hardly
    /// shrink for what writing to such a disk costs.
    public var supportsDiskCompression: Bool {
        guard let disk = systemDisk else { return false }
        switch os.family {
        case .linux: return [.raw, .asif, .compressed].contains(disk.format)
        case .windows: return [.raw, .compressed].contains(disk.format)
        case .macOS: return false
        }
    }

    /// The format a disk that stops being compressed is written out in: Apple's, which takes up only
    /// what it holds on any file system, or raw for QEMU, which doesn't read Apple's.
    public var uncompressedDiskFormat: DiskConfiguration.Format {
        engine == .qemu ? .raw : .asif
    }

    /// The configuration of a copy of this machine: the same hardware and disks under a new identity.
    ///
    /// The copy gets its own network card and no address yet. Forwarded ports stay with the original,
    /// since a port on the host can only lead to one machine, and so do drives that can be written to
    /// and the USB devices it takes by itself, which can only be with one guest.
    public func duplicated(name: String, sshAlias: String) -> VMConfiguration {
        var copy = self
        copy.id = UUID()
        copy.name = name
        copy.createdAt = Date()
        copy.ssh.alias = sshAlias
        copy.usb.autoConnect = []
        copy.removableImages = removableImages.filter(\.readOnly).map { RemovableImage(path: $0.path, readOnly: true) }
        copy.networkInterfaces = networkInterfaces.map { interface in
            NetworkInterfaceConfiguration(networkID: interface.networkID, isConnected: interface.isConnected)
        }
        return copy
    }

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
        /// SwiftVM's own: compressed, and handed to the machine by the app itself.
        case compressed
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

/// A disc or disk image on the host that is plugged into the machine as a USB drive.
public struct RemovableImage: Codable, Sendable, Hashable, Identifiable {
    /// Also identifies the USB device to the guest, so a suspended machine finds its drives again.
    public var id: UUID
    /// Absolute host path of the image.
    public var path: String
    public var readOnly: Bool

    public init(id: UUID = UUID(), path: String, readOnly: Bool) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
    }

    /// Attaches the image at `url`. Disc images (ISO) can't be written to, whatever is asked for.
    public init(url: URL, readOnly: Bool = false) {
        self.init(path: url.standardizedFileURL.path, readOnly: readOnly || Self.isDiscImage(url))
    }

    public var url: URL { URL(fileURLWithPath: path) }
    /// The file name, which is how the image is shown.
    public var name: String { url.lastPathComponent }

    public static func isDiscImage(_ url: URL) -> Bool {
        ["iso", "cdr"].contains(url.pathExtension.lowercased())
    }
}

// MARK: - Display

/// What shows a machine's display, where its engine has a choice: QEMU does.
public enum DisplayAdapter: String, Codable, Sendable, Hashable {
    /// A framebuffer that the firmware sets up and every system draws on, at the one size it starts
    /// with. Windows Setup has nothing else to draw with.
    case framebuffer
    /// A virtio GPU, which a driver in the guest makes the size of the window.
    case virtioGPU
    /// A guest's 3D driver renders through the Mac's GPU.
    case virtioGPU3D
}

public struct DisplayConfiguration: Codable, Sendable, Hashable {
    public var widthInPixels: Int
    public var heightInPixels: Int
    public var pixelsPerInch: Int
    /// Resize the guest display to follow the window.
    public var automaticallyResizes: Bool
    /// The adapter the guest last started with, and so the one any memory saved of it expects. `nil`
    /// for an engine that has no choice.
    public var adapter: DisplayAdapter?
    /// A Linux guest draws with the Mac's GPU: on QEMU, whose virtio GPU passes OpenGL on to it.
    /// Apple's virtualization has no such GPU for Linux.
    public var acceleratesGraphics: Bool

    public init(
        widthInPixels: Int = 1920, heightInPixels: Int = 1200, pixelsPerInch: Int = 144, automaticallyResizes: Bool = true,
        adapter: DisplayAdapter? = nil, acceleratesGraphics: Bool = false
    ) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.pixelsPerInch = pixelsPerInch
        self.automaticallyResizes = automaticallyResizes
        self.adapter = adapter
        self.acceleratesGraphics = acceleratesGraphics
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widthInPixels = try c.decode(Int.self, forKey: .widthInPixels)
        heightInPixels = try c.decode(Int.self, forKey: .heightInPixels)
        pixelsPerInch = try c.decode(Int.self, forKey: .pixelsPerInch)
        automaticallyResizes = try c.decode(.automaticallyResizes, default: true)
        adapter = try c.decodeIfPresent(DisplayAdapter.self, forKey: .adapter)
        acceleratesGraphics = try c.decode(.acceleratesGraphics, default: false)
    }

    /// A Retina display the size of the default machine window, for macOS guests.
    public static let macOS = DisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 220)
}

public struct KeyboardConfiguration: Codable, Sendable, Hashable {
    /// Send shortcuts such as Command-Tab to the guest instead of the host while its window has focus.
    public var capturesSystemKeys: Bool

    public init(capturesSystemKeys: Bool = true) {
        self.capturesSystemKeys = capturesSystemKeys
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
    /// The port on this Mac.
    public var hostPort: UInt16
    /// The port in the guest that it leads to.
    public var guestPort: UInt16
    /// Accept connections from other devices on the network, not only from this Mac.
    public var allowsOtherDevices: Bool

    public init(
        id: UUID = UUID(), transport: TransportProtocol = .tcp, hostPort: UInt16, guestPort: UInt16,
        allowsOtherDevices: Bool = false
    ) {
        self.id = id
        self.transport = transport
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.allowsOtherDevices = allowsOtherDevices
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, default: UUID())
        transport = try c.decode(.transport, default: .tcp)
        hostPort = try c.decode(UInt16.self, forKey: .hostPort)
        guestPort = try c.decode(UInt16.self, forKey: .guestPort)
        allowsOtherDevices = try c.decode(.allowsOtherDevices, default: false)
    }

    /// `8080 → 80`, or `8080 → 80 (UDP)`.
    public var summary: String {
        "\(hostPort) → \(guestPort)" + (transport == .udp ? " (UDP)" : "")
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

/// What is copied on the Mac can be pasted in the guest and the other way round: through the guest's
/// agent, or `spice-vdagent` in Linux guests on Apple's backend.
public struct ClipboardConfiguration: Codable, Sendable, Hashable {
    public var isShared: Bool
    fileprivate var includesAcceleratedLinux: Bool

    public init(isShared: Bool = true) {
        self.isShared = isShared
        self.includesAcceleratedLinux = true
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isShared = try c.decode(Bool.self, forKey: .isShared)
        includesAcceleratedLinux = try c.decode(.includesAcceleratedLinux, default: false)
    }
}

/// Whether the guest can be driven from this Mac's command line, through its agent: commands run in it,
/// its screen looked at, its mouse and keyboard used. Something to turn off for a machine that nothing
/// but a person is to touch.
public struct AutomationConfiguration: Codable, Sendable, Hashable {
    public var isAllowed: Bool

    public init(isAllowed: Bool = true) {
        self.isAllowed = isAllowed
    }
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
    /// Attach `seed.iso` from the bundle (cloud-init / unattended setup data).
    public var attachesSeedImage: Bool
    /// The guest finished its first-boot setup.
    public var isProvisioned: Bool
    /// The guest has been given this Mac's time zone. That happens once: whoever sets another one in
    /// the guest afterwards keeps it.
    public var hasHostTimeZone: Bool
    /// The user has been told that the guest's setup script failed. That is news once: until the
    /// script is seen at work or finished again, a guest that says so again is not.
    public var hasReportedSetupFailure: Bool
    /// The guest has a driver for a display that can change its size, as its agent said. It starts with
    /// one from then on, where its engine has a choice (``DisplayAdapter``).
    public var hasDisplayDriver: Bool
    public var hasAcceleratedDisplayDriver: Bool
    /// The drives that were plugged in to install the system, by their identifiers: a Windows machine's
    /// installer and drivers. They come out when the guest's setup has finished.
    public var setupMedia: [UUID]

    public init(
        attachesSeedImage: Bool = false, isProvisioned: Bool = false, hasHostTimeZone: Bool = false,
        hasReportedSetupFailure: Bool = false, hasDisplayDriver: Bool = false, hasAcceleratedDisplayDriver: Bool = false, setupMedia: [UUID] = []
    ) {
        self.attachesSeedImage = attachesSeedImage
        self.isProvisioned = isProvisioned
        self.hasHostTimeZone = hasHostTimeZone
        self.hasReportedSetupFailure = hasReportedSetupFailure
        self.hasDisplayDriver = hasDisplayDriver
        self.hasAcceleratedDisplayDriver = hasAcceleratedDisplayDriver
        self.setupMedia = setupMedia
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attachesSeedImage = try c.decode(.attachesSeedImage, default: false)
        isProvisioned = try c.decode(.isProvisioned, default: false)
        hasHostTimeZone = try c.decode(.hasHostTimeZone, default: false)
        hasReportedSetupFailure = try c.decode(.hasReportedSetupFailure, default: false)
        hasDisplayDriver = try c.decode(.hasDisplayDriver, default: false)
        hasAcceleratedDisplayDriver = try c.decode(.hasAcceleratedDisplayDriver, default: false)
        setupMedia = try c.decode(.setupMedia, default: [])
    }
}

// MARK: - Decoding helpers

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue()
    }
}
