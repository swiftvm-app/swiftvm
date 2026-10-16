import DiskTools
import Foundation
import VMCore

/// What QEMU is told about a machine when it starts: everything in a ``VMConfiguration`` that QEMU
/// has a say in, as its command line.
///
/// Devices go as JSON, which QEMU reads for them as it does for its machine protocol. A path then
/// needs no escaping, and a drive that is plugged in while the machine runs is described the same way
/// as one it starts with.
///
/// The lines to the app are open descriptors that QEMU is handed when it starts, numbered from 3:
/// its machine protocol, the serial console, the guest's agent, and one per network card.
public struct QEMUCommandLine: Sendable {
    /// What shows the machine's display.
    public enum Display: Sendable, Hashable {
        /// A plain framebuffer that the firmware sets up and every system can draw on, at one size.
        case framebuffer
        /// A virtio GPU, whose size a driver in the guest can change to fit the window.
        case virtioGPU
        case virtioGPU3D
    }

    /// Where QEMU reads and writes a disk.
    public enum DiskSource: Sendable, Hashable {
        /// A raw image.
        case file(URL)
        /// A server of the app's, for a compressed disk.
        case nbd(socketPath: String)
    }

    public var configuration: VMConfiguration
    public var bundle: VMBundle
    public var installation: QEMUInstallation
    /// Where each of the machine's disks is, by its identifier.
    public var diskSources: [UUID: DiskSource]
    public var display: Display
    /// Start from the saved state, which the app hands QEMU once it is up.
    public var restoresSavedState: Bool
    /// The USB ports that drives and disks on USB were in when the machine was saved, by their
    /// identifier. The others get free ones.
    public var usbPorts: [UUID: Int]
    public var spiceSocket: URL?

    public init(
        configuration: VMConfiguration, bundle: VMBundle, installation: QEMUInstallation, diskSources: [UUID: DiskSource],
        display: Display, restoresSavedState: Bool = false, usbPorts: [UUID: Int] = [:], spiceSocket: URL? = nil
    ) {
        self.configuration = configuration
        self.bundle = bundle
        self.installation = installation
        self.diskSources = diskSources
        self.display = display
        self.restoresSavedState = restoresSavedState
        self.usbPorts = usbPorts
        self.spiceSocket = spiceSocket
    }

    /// The machine type, by its version. A machine saved by one QEMU only resumes on a QEMU that builds
    /// the same hardware, and a later QEMU still builds this one when asked by name.
    public static let machineType = "virt-11.1"

    public static let monitorDescriptor: Int32 = 3
    public static let consoleDescriptor: Int32 = 4
    public static let agentDescriptor: Int32 = 5

    /// The descriptor of the network card at `index` among the machine's interfaces.
    public static func networkDescriptor(at index: Int) -> Int32 {
        6 + Int32(index)
    }

    /// The name the agent's serial port has in the guest, which is how the agent finds it.
    public static let agentPortName = "org.swiftvm.agent"

    // MARK: USB ports

    /// QEMU tells the USB devices of a saved machine apart by the port each is in, so a machine is
    /// restored with every device in the port it had. The keyboard, the tablet and the sound card have
    /// ports of their own. Drives get the first free one, and keep it.
    static let usbPortCount = 15
    static let keyboardPort = 1
    static let tabletPort = 2
    static let audioPort = 3
    static let firstDrivePort = 4

    /// The sound card, which is unplugged while the machine is saved: QEMU can't save it.
    public static let audioDeviceID = "audio"

    public static let audioDevice: [String: QMPValue] = [
        "driver": "usb-audio", "id": .string(audioDeviceID), "bus": "usb.0", "port": .string(String(audioPort)), "audiodev": "audio",
    ]

    /// The lowest port for a drive that none of `used` is in, if there is one.
    public static func freeUSBPort(besides used: some Sequence<Int>) -> Int? {
        let taken = Set(used)
        return (firstDrivePort...usbPortCount).first { !taken.contains($0) }
    }

    /// The drives the machine starts with: those plugged in, and the setup disc of a machine that sets
    /// itself up.
    var startingDrives: [RemovableImage] {
        var drives = configuration.removableImages
        // Linux has its setup disc as a disk of its own (``seedDisk``).
        if configuration.os.family != .linux, let seed = seedImage {
            drives.append(seed)
        }
        return drives
    }

    /// The setup disc, for a machine that sets itself up and has it.
    var seedImage: RemovableImage? {
        guard configuration.installation.attachesSeedImage, FileManager.default.fileExists(atPath: bundle.seedImageURL.path) else { return nil }
        return Self.seedImage(at: bundle.seedImageURL)
    }

    /// The port of every drive and disk on USB the machine starts with, by its identifier: the one it
    /// had when the machine was saved, otherwise the first free one.
    public func startingUSBPorts() throws -> [UUID: Int] {
        let ids = configuration.disks.filter { $0.bus == .usb }.map(\.id) + startingDrives.map(\.id)
        var ports: [UUID: Int] = [:]
        for id in ids {
            ports[id] = usbPorts[id]
        }
        for id in ids where ports[id] == nil {
            guard let port = Self.freeUSBPort(besides: ports.values) else {
                throw QEMUError.didNotStart("“\(configuration.name)” has more drives than USB ports for them.")
            }
            ports[id] = port
        }
        return ports
    }

    public func arguments() throws -> [String] {
        let accelerated = display == .virtioGPU3D
        guard !accelerated || (installation.acceleratesGraphics && spiceSocket != nil && !restoresSavedState) else {
            throw QEMUError.didNotStart("Graphics acceleration needs QEMU with OpenGL and the app's display, and can't resume saved memory.")
        }
        let memory = configuration.memorySize >> 20
        var arguments = [
            "-nodefaults", "-no-user-config",
            // An option list, where a comma or `=` in the name would be read as more options.
            "-name", "guest=" + Self.escaped(configuration.name),
            "-machine", Self.machineType,
            // Windows' Direct3D driver places GPU memory at 4K offsets, which guest memory mapped in
            // the Mac's 16K pages can't follow.
            "-accel", accelerated && configuration.os.family == .windows ? "hvf,ipa-granule-size=4096" : "hvf",
            "-cpu", "host",
            "-smp", String(max(configuration.cpuCount, 1)),
            "-m", "\(max(memory, 512))M",
            // The machine's identity in its firmware's tables, which Windows ties its activation to.
            "-uuid", configuration.id.uuidString.lowercased(),
            "-L", installation.dataDirectory.path,
            "-bios", installation.firmware.path,
            "-drive", "if=pflash,unit=1,format=raw,file=\(Self.escaped(bundle.efiVariableStoreURL.path))",
            // Windows keeps its clock in local time, Linux in UTC.
            "-rtc", configuration.os.family == .windows ? "base=localtime" : "base=utc",
            "-display", "none",
            // Nothing runs until the app has its lines in place and says so.
            "-S",
            // A guest that restarts ends QEMU instead, and the app starts it anew with the machine as
            // it is configured by then: a display driver that setup installed is used from there on.
            "-no-reboot",
            "-chardev", "socket,id=monitor,fd=\(Self.monitorDescriptor)",
            "-chardev", "socket,id=console,fd=\(Self.consoleDescriptor)",
        ]
        // Linux writes to a virtio console (hvc0), as it does on Apple's virtualization; Windows to
        // the serial port.
        if configuration.os.family != .linux {
            arguments += ["-serial", "chardev:console"]
        }
        arguments += ["-object", Self.json(["qom-type": "monitor-qmp", "id": "monitor", "chardev": "monitor"])]
        if accelerated, let spiceSocket {
            arguments += ["-spice", "unix=on,addr=\(Self.escaped(spiceSocket.path)),disable-ticketing=on,gl=on,streaming-video=off,agent-mouse=off,disable-copy-paste=on,disable-agent-file-xfer=on"]
        } else {
            // The VNC server listens nowhere: the app hands it the one client it has.
            arguments += ["-vnc", "none"]
        }
        if restoresSavedState {
            arguments += ["-incoming", "defer"]
        }

        let ports = try startingUSBPorts()
        var devices: [[String: QMPValue]] = []
        // As many ports as there can be, so that nothing ends up behind a hub, which QEMU would make a
        // slow one. Each takes USB 2 and USB 3 devices.
        let portCount = QMPValue.number(Double(Self.usbPortCount))
        devices.append(["driver": "qemu-xhci", "id": "usb", "p2": portCount, "p3": portCount])
        devices.append(["driver": "usb-kbd", "bus": "usb.0", "port": .string(String(Self.keyboardPort))])
        // Absolute positions, so the pointer is where the Mac's is.
        devices.append(["driver": "usb-tablet", "bus": "usb.0", "port": .string(String(Self.tabletPort))])
        switch display {
        case .framebuffer:
            devices.append(["driver": "ramfb"])
        case .virtioGPU:
            devices.append([
                "driver": "virtio-gpu-pci", "id": "gpu",
                "xres": .number(Double(configuration.display.widthInPixels)),
                "yres": .number(Double(configuration.display.heightInPixels)),
            ])
        case .virtioGPU3D where configuration.os.family == .linux:
            // Linux draws with OpenGL, which virglrenderer replays on the Mac's GPU. Its size follows
            // the window through the guest's own display settings.
            devices.append([
                "driver": "virtio-gpu-gl-pci", "id": "gpu",
                "xres": .number(Double(configuration.display.widthInPixels)),
                "yres": .number(Double(configuration.display.heightInPixels)),
            ])
        case .virtioGPU3D:
            devices.append([
                "driver": "virtio-ramfb-gl", "id": "gpu", "hostmem": .number(Double(8 << 30)),
                "blob": true, "neptune": true,
                "xres": .number(Double(configuration.display.widthInPixels)),
                "yres": .number(Double(configuration.display.heightInPixels)),
            ])
        }

        for (index, disk) in configuration.disks.enumerated() {
            guard let source = diskSources[disk.id] else { throw QEMUError.didNotStart("The disk “\(disk.fileName)” isn't there.") }
            arguments += ["-blockdev", Self.json(Self.diskNode(id: Self.diskNodeName(index), source: source, readOnly: disk.readOnly))]
            devices.append(Self.diskDevice(node: Self.diskNodeName(index), bus: disk.bus, serial: "swiftvm\(index)", port: ports[disk.id]))
        }

        for image in startingDrives {
            arguments += ["-blockdev", Self.json(Self.imageNode(for: image))]
            devices += Self.imageDevices(for: image, port: ports[image.id] ?? Self.firstDrivePort)
        }
        // cloud-init looks for its setup disc early in the start, before the system has looked for
        // drives on USB. A virtio disk is there from the beginning.
        if configuration.os.family == .linux, let seed = seedImage {
            arguments += ["-blockdev", Self.json(Self.imageNode(for: seed))]
            devices.append(["driver": "virtio-blk-pci", "drive": .string(Self.imageNodeName(for: seed.id)), "serial": "swiftvm-seed"])
        }

        // A Linux guest's shared folders, a 9p device each, by the tags its agent mounts them by. They
        // are those the machine starts with: QEMU adds no device of the kind while it runs.
        if configuration.os.family == .linux {
            // QEMU doesn't start with a folder that isn't there, on a disk that was ejected for one.
            // The guest goes without it this time.
            let present = configuration.sharedFolders.filter { folder in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            for (index, folder) in present.enumerated() {
                var options = "local,id=share\(index),path=\(Self.escaped(folder.path)),security_model=none"
                if folder.readOnly {
                    options += ",readonly=on"
                }
                arguments += ["-fsdev", options]
                devices.append([
                    "driver": "virtio-9p-pci", "fsdev": .string("share\(index)"),
                    "mount_tag": .string(GuestIntegration.folderDeviceTag(for: folder)),
                ])
            }
        }

        for (index, interface) in configuration.networkInterfaces.enumerated() {
            arguments += ["-netdev", Self.json([
                "type": "dgram", "id": .string("net\(index)"),
                "local": ["type": "fd", "str": .string(String(Self.networkDescriptor(at: index)))],
            ])]
            // The firmware has a driver of its own for the card: the one QEMU would load from a file
            // that isn't there is no use.
            devices.append([
                "driver": "virtio-net-pci", "id": .string(Self.networkDeviceID(at: index)), "netdev": .string("net\(index)"),
                "mac": .string(interface.macAddress), "romfile": "",
            ])
        }

        // The agent's line, a serial port of its own that only the app is at the other end of.
        devices.append(["driver": "virtio-serial-pci", "id": "serial"])
        arguments += ["-chardev", "socket,id=agent,fd=\(Self.agentDescriptor)"]
        devices.append(["driver": "virtserialport", "bus": "serial.0", "chardev": "agent", "name": .string(Self.agentPortName)])
        if configuration.os.family == .linux {
            devices.append(["driver": "virtconsole", "bus": "serial.0", "chardev": "console"])
        }
        if accelerated {
            // SPICE negotiates monitor sizes with the guest tools. Input stays on the USB tablet;
            // this port implements display configuration, not SPICE clipboard, files, or mouse input.
            arguments += ["-chardev", "spicevmc,id=display-agent,name=vdagent"]
            devices.append(["driver": "virtserialport", "bus": "serial.0", "chardev": "display-agent", "name": "com.redhat.spice.0"])
        }

        devices.append(["driver": "virtio-rng-pci"])
        if configuration.audio.outputEnabled {
            arguments += ["-audiodev", "coreaudio,id=audio"]
            // A restored machine was saved without it, and has it plugged in once it is back.
            if !restoresSavedState {
                devices.append(Self.audioDevice)
            }
        }

        for device in devices {
            arguments += ["-device", Self.json(device)]
        }
        return arguments
    }

    // MARK: Disks and drives

    static func diskNodeName(_ index: Int) -> String {
        "disk\(index)"
    }

    static func diskNode(id: String, source: DiskSource, readOnly: Bool) -> [String: QMPValue] {
        let file: QMPValue = switch source {
        case .file(let url): ["driver": "file", "filename": .string(url.path)]
        case .nbd(let socketPath):
            ["driver": "nbd", "server": ["type": "unix", "path": .string(socketPath)], "export": .string(CompressedDiskExport.exportName)]
        }
        // What the guest frees is given back to the Mac: the image stays as small as what is in it.
        return ["driver": "raw", "node-name": .string(id), "read-only": .bool(readOnly), "discard": "unmap", "file": file]
    }

    /// No device is given a place in the order the firmware starts from. Given one, the firmware looks
    /// at nothing else: not at an installer disc. Without, it goes by its own order, which Windows
    /// Setup puts Windows at the top of.
    static func diskDevice(node: String, bus: DiskConfiguration.Bus, serial: String, port: Int?) -> [String: QMPValue] {
        switch bus {
        case .nvme:
            ["driver": "nvme", "drive": .string(node), "serial": .string(serial)]
        case .virtio:
            ["driver": "virtio-blk-pci", "drive": .string(node), "serial": .string(serial)]
        case .usb:
            ["driver": "usb-storage", "bus": "usb.0", "port": .string(String(port ?? firstDrivePort)), "drive": .string(node), "serial": .string(serial)]
        }
    }

    /// The setup disc of a machine that sets itself up on its first start, as a drive like any other.
    static func seedImage(at url: URL) -> RemovableImage {
        // Its identifier is made up, but always the same, so that it is the same drive every time.
        RemovableImage(id: UUID(uuidString: "5E1D0000-0000-4000-8000-000000000000")!, path: url.path, readOnly: true)
    }

    /// The name of the block node that holds a drive's image. QEMU takes 31 characters at most.
    public static func imageNodeName(for id: UUID) -> String {
        "image-" + shortName(of: id)
    }

    /// The device QEMU knows a drive by, which unplugging it names.
    public static func imageDeviceID(for image: RemovableImage) -> String {
        (isDisc(image) ? "disc-" : "drive-") + shortName(of: image.id)
    }

    /// A drive's identifier, short enough for QEMU's names: half of it, which tells a machine's few
    /// drives apart.
    static func shortName(of id: UUID) -> String {
        String(id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
    }

    /// Discs are CD drives: Windows reads the file system of a disc image only from a drive for discs.
    static func isDisc(_ image: RemovableImage) -> Bool {
        RemovableImage.isDiscImage(image.url)
    }

    public static func imageNode(for image: RemovableImage) -> [String: QMPValue] {
        [
            "driver": "raw", "node-name": .string(imageNodeName(for: image.id)), "read-only": .bool(image.readOnly),
            "file": ["driver": "file", "filename": .string(image.path), "read-only": .bool(image.readOnly)],
        ]
    }

    /// The devices a drive is, in USB port `port`: a USB drive for a disk image, and for a disc a USB
    /// drive for discs, which in QEMU is a bare USB storage device with a CD drive on its bus.
    public static func imageDevices(for image: RemovableImage, port: Int) -> [[String: QMPValue]] {
        let id = imageDeviceID(for: image)
        let node = imageNodeName(for: image.id)
        let usbPort = QMPValue.string(String(port))
        guard isDisc(image) else {
            return [["driver": "usb-storage", "id": .string(id), "bus": "usb.0", "port": usbPort, "drive": .string(node), "removable": true]]
        }
        return [
            ["driver": "usb-bot", "id": .string(id), "bus": "usb.0", "port": usbPort],
            ["driver": "scsi-cd", "id": .string(id + "-cd"), "bus": .string(id + ".0"), "drive": .string(node)],
        ]
    }

    public static func networkDeviceID(at index: Int) -> String {
        "nic\(index)"
    }

    // MARK: Writing it down

    static func json(_ object: [String: QMPValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(QMPValue.object(object))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A value in QEMU's own option syntax, where a comma ends it unless it is doubled.
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }
}
