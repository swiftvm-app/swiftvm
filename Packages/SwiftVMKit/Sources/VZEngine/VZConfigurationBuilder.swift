import DiskImageKit
import Foundation
import VMCore
import Virtualization

/// Translates a ``VMConfiguration`` into a `VZVirtualMachineConfiguration`.
@MainActor
public struct VZConfigurationBuilder {
    public enum BuildError: Error, LocalizedError {
        case unsupportedGuest(GuestFamily)
        case missingFile(String)
        case unsupportedHardwareModel
        case invalidMACAddress(String)
        case rosettaNotInstalled

        public var errorDescription: String? {
            switch self {
            case .unsupportedGuest(let family):
                "\(family.displayName) guests can't run on the Virtualization engine."
            case .missingFile(let name):
                "The virtual machine is missing “\(name)”."
            case .unsupportedHardwareModel:
                "This Mac can't run the macOS version installed in this virtual machine."
            case .invalidMACAddress(let address):
                "“\(address)” isn't a valid MAC address."
            case .rosettaNotInstalled:
                "Rosetta isn't installed on this Mac."
            }
        }
    }

    public var bundle: VMBundle
    public var configuration: VMConfiguration
    /// Attachments for connected interfaces, keyed by interface ID. Interfaces without an entry start unplugged.
    public var networkAttachments: [UUID: VZNetworkDeviceAttachment]

    public init(bundle: VMBundle, configuration: VMConfiguration, networkAttachments: [UUID: VZNetworkDeviceAttachment] = [:]) {
        self.bundle = bundle
        self.configuration = configuration
        self.networkAttachments = networkAttachments
    }

    public func build() throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = Self.clampedCPUCount(configuration.cpuCount)
        vz.memorySize = Self.clampedMemorySize(configuration.memorySize)
        vz.label = Self.label(from: configuration.name)

        switch configuration.os.family {
        case .linux:
            try configureLinuxPlatform(vz)
        case .macOS:
            try configureMacPlatform(vz)
        case .windows:
            throw BuildError.unsupportedGuest(.windows)
        }

        vz.storageDevices = try makeStorageDevices()
        vz.usbControllers = [VZXHCIControllerConfiguration()]
        vz.networkDevices = try makeNetworkDevices()
        vz.directorySharingDevices = try makeDirectorySharingDevices()
        vz.audioDevices = makeAudioDevices()
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vz.serialPorts = try makeSerialPorts()
        if configuration.os.family == .linux {
            vz.consoleDevices = [Self.makeClipboardConsole()]
        }

        try vz.validate()
        return vz
    }

    // MARK: Limits

    static func clampedCPUCount(_ count: Int) -> Int {
        min(max(count, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    static func clampedMemorySize(_ size: UInt64) -> UInt64 {
        let mebibyte: UInt64 = 1 << 20
        let clamped = min(max(size, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        return clamped / mebibyte * mebibyte
    }

    /// The label must be non-empty and at most 64 characters.
    static func label(from name: String) -> String? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Platform

    private func configureLinuxPlatform(_ vz: VZVirtualMachineConfiguration) throws {
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try loadOrCreateGenericMachineIdentifier()
        vz.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try loadOrCreateEFIVariableStore()
        vz.bootLoader = bootLoader

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: configuration.display.widthInPixels,
                heightInPixels: configuration.display.heightInPixels
            ),
        ]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private func configureMacPlatform(_ vz: VZVirtualMachineConfiguration) throws {
        let fileManager = FileManager.default
        guard let hardwareModelData = try? Data(contentsOf: bundle.hardwareModelURL),
              let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData)
        else { throw BuildError.missingFile(bundle.hardwareModelURL.lastPathComponent) }
        guard hardwareModel.isSupported else { throw BuildError.unsupportedHardwareModel }
        guard let identifierData = try? Data(contentsOf: bundle.machineIdentifierURL),
              let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: identifierData)
        else { throw BuildError.missingFile(bundle.machineIdentifierURL.lastPathComponent) }
        guard fileManager.fileExists(atPath: bundle.auxiliaryStorageURL.path) else {
            throw BuildError.missingFile(bundle.auxiliaryStorageURL.lastPathComponent)
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: configuration.display.widthInPixels,
                heightInPixels: configuration.display.heightInPixels,
                pixelsPerInch: configuration.display.pixelsPerInch
            ),
        ]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZMacKeyboardConfiguration()]
        vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private func loadOrCreateGenericMachineIdentifier() throws -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: bundle.machineIdentifierURL),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: bundle.machineIdentifierURL, options: .atomic)
        return identifier
    }

    private func loadOrCreateEFIVariableStore() throws -> VZEFIVariableStore {
        let url = bundle.efiVariableStoreURL
        let store: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: url.path) {
            store = VZEFIVariableStore(url: url)
        } else {
            store = try VZEFIVariableStore(creatingVariableStoreAt: url)
        }

        let secureBootEnabled = try store.isSecureBootEnabled
        if configuration.boot.secureBoot, !secureBootEnabled {
            try store.enrollDefaultSecureBootSignatures()
            try store.enableSecureBootUsingDefaultPlatformKey()
        } else if !configuration.boot.secureBoot, secureBootEnabled {
            try store.disableSecureBoot()
        }
        return store
    }

    // MARK: Storage

    private func makeStorageDevices() throws -> [VZStorageDeviceConfiguration] {
        var devices: [VZStorageDeviceConfiguration] = []
        for disk in configuration.disks {
            let url = bundle.diskURL(for: disk)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw BuildError.missingFile(disk.fileName)
            }
            let attachment: VZDiskImageStorageDeviceAttachment
            switch disk.format {
            case .asif:
                let image = try DiskImage(opening: .open(url: url, mode: disk.readOnly ? .readOnly : .readWrite))
                attachment = try VZDiskImageStorageDeviceAttachment(diskImage: image)
            case .raw:
                attachment = try VZDiskImageStorageDeviceAttachment(
                    url: url, readOnly: disk.readOnly, cachingMode: .automatic, synchronizationMode: .full
                )
            }
            // macOS guests only boot from virtio block devices.
            let bus = configuration.os.family == .macOS ? .virtio : disk.bus
            switch bus {
            case .virtio:
                devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
            case .nvme:
                devices.append(VZNVMExpressControllerDeviceConfiguration(attachment: attachment))
            case .usb:
                devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            }
        }

        if configuration.installation.attachesSeedImage, FileManager.default.fileExists(atPath: bundle.seedImageURL.path) {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: bundle.seedImageURL, readOnly: true)
            devices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }

        if let mediaPath = configuration.installation.installMediaPath {
            guard FileManager.default.fileExists(atPath: mediaPath) else {
                throw BuildError.missingFile(URL(fileURLWithPath: mediaPath).lastPathComponent)
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: mediaPath), readOnly: true)
            devices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        return devices
    }

    // MARK: Network

    private func makeNetworkDevices() throws -> [VZNetworkDeviceConfiguration] {
        try configuration.networkInterfaces.map { interface in
            guard let macAddress = VZMACAddress(string: interface.macAddress) else {
                throw BuildError.invalidMACAddress(interface.macAddress)
            }
            let device = VZVirtioNetworkDeviceConfiguration()
            device.macAddress = macAddress
            device.attachment = networkAttachments[interface.id]
            return device
        }
    }

    // MARK: Sharing

    /// The virtio-fs tag that carries shared folders for this guest.
    public static func sharedFoldersTag(for family: GuestFamily) -> String {
        family == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : GuestIntegration.sharedFoldersTag
    }

    public static func makeShare(for folders: [SharedFolder]) -> VZMultipleDirectoryShare {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in folders {
            let name = uniqueShareName(folder.name, taken: Set(directories.keys))
            directories[name] = VZSharedDirectory(url: folder.url, readOnly: folder.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    private static func uniqueShareName(_ name: String, taken: Set<String>) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
        let base = cleaned.isEmpty ? "Shared" : cleaned
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    private func makeDirectorySharingDevices() throws -> [VZDirectorySharingDeviceConfiguration] {
        // Always present, even with no folders, so folders can be added while the guest runs.
        let shared = VZVirtioFileSystemDeviceConfiguration(tag: Self.sharedFoldersTag(for: configuration.os.family))
        shared.share = Self.makeShare(for: configuration.sharedFolders)
        var devices: [VZDirectorySharingDeviceConfiguration] = [shared]

        if configuration.os.family == .linux, configuration.boot.rosetta {
            guard VZLinuxRosettaDirectoryShare.availability == .installed else {
                throw BuildError.rosettaNotInstalled
            }
            let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: GuestIntegration.rosettaTag)
            rosetta.share = try VZLinuxRosettaDirectoryShare()
            devices.append(rosetta)
        }
        return devices
    }

    // MARK: Audio, console

    private func makeAudioDevices() -> [VZAudioDeviceConfiguration] {
        var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
        if configuration.audio.outputEnabled {
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            streams.append(output)
        }
        if configuration.audio.inputEnabled {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            streams.append(input)
        }
        guard !streams.isEmpty else { return [] }
        let device = VZVirtioSoundDeviceConfiguration()
        device.streams = streams
        return [device]
    }

    /// The guest's serial console is written to a log file in the bundle.
    private func makeSerialPorts() throws -> [VZSerialPortConfiguration] {
        try FileManager.default.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment = try VZFileSerialPortAttachment(url: bundle.consoleLogURL, append: false)
        return [port]
    }

    /// A SPICE agent channel so Linux guests running `spice-vdagent` share the clipboard with the host.
    private static func makeClipboardConsole() -> VZVirtioConsoleDeviceConfiguration {
        let agent = VZSpiceAgentPortAttachment()
        agent.sharesClipboard = true
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        port.attachment = agent
        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = port
        return console
    }
}
