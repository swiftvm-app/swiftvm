import Foundation
import Testing
@testable import QEMUEngine
import VMCore

@Suite struct QEMUCommandLineTests {
    private let bundle = VMBundle(url: URL(fileURLWithPath: "/Machines/Windows.swiftvm"))
    private let installation = QEMUInstallation(
        program: URL(fileURLWithPath: "/App/Contents/Helpers/QEMU/bin/qemu-system-aarch64"),
        dataDirectory: URL(fileURLWithPath: "/App/Contents/Resources/QEMU/share")
    )
    private let disk = DiskConfiguration(fileName: "disk.img", capacity: 64 << 30, bus: .nvme, format: .raw)
    private let installer = RemovableImage(path: "/Downloads/Windows 11, Arm.iso", readOnly: true)
    private let stick = RemovableImage(path: "/Downloads/stick.img", readOnly: false)

    private func commandLine(
        display: QEMUCommandLine.Display = .framebuffer, restoring: Bool = false, source: QEMUCommandLine.DiskSource? = nil,
        drives: [RemovableImage]? = nil, usbPorts: [UUID: Int] = [:]
    ) -> QEMUCommandLine {
        let configuration = VMConfiguration(
            name: "Windows", os: GuestOS(family: .windows), cpuCount: 4, memorySize: 8 << 30, disks: [disk],
            removableImages: drives ?? [installer, stick],
            networkInterfaces: [
                NetworkInterfaceConfiguration(macAddress: "02:00:00:00:00:01"),
                NetworkInterfaceConfiguration(macAddress: "02:00:00:00:00:02", isConnected: false),
            ]
        )
        return QEMUCommandLine(
            configuration: configuration, bundle: bundle, installation: installation,
            diskSources: [disk.id: source ?? .file(bundle.diskURL(for: disk))], display: display, restoresSavedState: restoring,
            usbPorts: usbPorts
        )
    }

    /// The values of every `option`, with those written as JSON read back.
    private func values(of option: String, in arguments: [String]) -> [String] {
        arguments.indices.filter { arguments[$0] == option && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    }

    private func objects(_ option: String, in arguments: [String]) -> [[String: Any]] {
        values(of: option, in: arguments).compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// A Linux machine that draws with the Mac's GPU, set up by its first-boot disc, with two folders.
    @Test func aLinuxMachineHasItsOwnClockConsoleGPUSetupDiscAndFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 16 << 30, bus: .virtio, format: .raw)
        let projects = directory.appending(path: "Projects, old").path
        let music = directory.appending(path: "Music").path
        for path in [projects, music] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let folders = [
            SharedFolder(name: "Projects", path: projects),
            // On a disk that was ejected: QEMU wouldn't start with it, and the guest goes without.
            SharedFolder(name: "Away", path: "/Volumes/Gone/Away"),
            SharedFolder(name: "Music", path: music, readOnly: true),
        ]
        let configuration = VMConfiguration(
            name: "Arch", os: GuestOS(family: .linux), engine: .qemu, cpuCount: 4, memorySize: 8 << 30, disks: [disk],
            display: DisplayConfiguration(acceleratesGraphics: true), sharedFolders: folders,
            installation: InstallationConfiguration(attachesSeedImage: true)
        )
        let bundle = try VMBundle.create(at: directory.appending(path: "Arch.swiftvm"), configuration: configuration)
        FileManager.default.createFile(atPath: bundle.seedImageURL.path, contents: Data(count: 4096))
        var accelerated = installation
        accelerated.acceleratesGraphics = true
        var commandLine = QEMUCommandLine(
            configuration: configuration, bundle: bundle, installation: accelerated,
            diskSources: [disk.id: .file(bundle.diskURL(for: disk))], display: .virtioGPU3D,
            spiceSocket: URL(fileURLWithPath: "/tmp/display.sock")
        )
        let arguments = try commandLine.arguments()

        // Linux keeps its clock in UTC, and writes to hvc0 rather than a serial port.
        #expect(values(of: "-rtc", in: arguments) == ["base=utc"])
        // Its guest memory is mapped in the Mac's own pages: only Windows' Direct3D needs smaller ones.
        #expect(values(of: "-accel", in: arguments) == ["hvf"])
        #expect(!arguments.contains("-serial"))
        let devices = objects("-device", in: arguments)
        #expect(devices.contains { $0["driver"] as? String == "virtconsole" && $0["chardev"] as? String == "console" })
        // OpenGL, which virglrenderer passes on to the Mac's GPU.
        #expect(devices.first { $0["id"] as? String == "gpu" }?["driver"] as? String == "virtio-gpu-gl-pci")
        // The setup disc is a virtio disk, there before cloud-init looks for it, and on no USB port.
        let seed = try #require(devices.first { $0["serial"] as? String == "swiftvm-seed" })
        #expect(seed["driver"] as? String == "virtio-blk-pci")
        #expect(!devices.contains { $0["driver"] as? String == "usb-storage" || $0["driver"] as? String == "scsi-cd" })
        // A 9p device for each folder, by the tag its agent mounts it by.
        let fsdevs = values(of: "-fsdev", in: arguments)
        #expect(fsdevs == [
            "local,id=share0,path=\(projects.replacingOccurrences(of: ",", with: ",,")),security_model=none",
            "local,id=share1,path=\(music),security_model=none,readonly=on",
        ])
        let shares = devices.filter { $0["driver"] as? String == "virtio-9p-pci" }
        #expect(shares.compactMap { $0["mount_tag"] as? String } == [folders[0], folders[2]].map(GuestIntegration.folderDeviceTag(for:)))

        // VirGL's GPU state can't be restored, even when the rest of the machine has saved memory.
        commandLine.restoresSavedState = true
        #expect(throws: QEMUError.self) { try commandLine.arguments() }
    }

    @Test func handsTheLinesToTheAppOverAsDescriptors() throws {
        let arguments = try commandLine().arguments()
        let chardevs = values(of: "-chardev", in: arguments)
        #expect(chardevs.contains("socket,id=monitor,fd=3"))
        #expect(chardevs.contains("socket,id=console,fd=4"))
        #expect(chardevs.contains("socket,id=agent,fd=5"))
        // One network card for each interface, also the one whose cable is out, each on its own line.
        let netdevs = objects("-netdev", in: arguments)
        #expect(netdevs.compactMap { ($0["local"] as? [String: Any])?["str"] as? String } == ["6", "7"])
        let cards = objects("-device", in: arguments).filter { $0["driver"] as? String == "virtio-net-pci" }
        #expect(cards.compactMap { $0["mac"] as? String } == ["02:00:00:00:00:01", "02:00:00:00:00:02"])
        // Nothing listens anywhere: the app hands QEMU the display's one client itself.
        #expect(values(of: "-vnc", in: arguments) == ["none"])
    }

    @Test func discsAreDiscDrivesAndDiskImagesAreDisks() throws {
        let devices = objects("-device", in: try commandLine().arguments())
        // Windows reads the file system of a disc image only from a drive for discs.
        let disc = QEMUCommandLine.imageDeviceID(for: installer)
        #expect(devices.contains { $0["driver"] as? String == "usb-bot" && $0["id"] as? String == disc })
        #expect(devices.contains { $0["driver"] as? String == "scsi-cd" && $0["bus"] as? String == disc + ".0" })
        #expect(devices.contains { $0["driver"] as? String == "usb-storage" && $0["id"] as? String == QEMUCommandLine.imageDeviceID(for: stick) })
        // No device has a place in the boot order: given one, the firmware wouldn't look at the installer.
        #expect(!devices.contains { $0["bootindex"] != nil })
    }

    @Test func namesFitWithinWhatQEMUTakes() throws {
        let nodes = objects("-blockdev", in: try commandLine().arguments()).compactMap { $0["node-name"] as? String }
        #expect(nodes.count == 3)
        #expect(nodes.allSatisfy { $0.count <= 31 })
        #expect(Set(nodes).count == nodes.count)
    }

    @Test func aCompressedDiskComesFromTheAppsServer() throws {
        let nodes = objects("-blockdev", in: try commandLine(source: .nbd(socketPath: "/tmp/disk.sock")).arguments())
        let file = nodes.first { $0["node-name"] as? String == "disk0" }?["file"] as? [String: Any]
        #expect(file?["driver"] as? String == "nbd")
        #expect((file?["server"] as? [String: Any])?["path"] as? String == "/tmp/disk.sock")
    }

    @Test func aRestartEndsQEMUAndARestoreWaitsForTheSavedState() throws {
        #expect(try commandLine().arguments().contains("-no-reboot"))
        #expect(!(try commandLine().arguments().contains("-incoming")))
        #expect(values(of: "-incoming", in: try commandLine(restoring: true).arguments()) == ["defer"])
    }

    @Test func acceleratedBootUsesLocalGraphicsAndCannotConsumeLegacyMemory() throws {
        var line = commandLine(display: .virtioGPU3D)
        #expect(throws: QEMUError.self) { try line.arguments() }
        line.installation.acceleratesGraphics = true
        line.spiceSocket = URL(fileURLWithPath: "/tmp/private,display/display.sock")
        let arguments = try line.arguments()
        #expect(values(of: "-accel", in: arguments) == ["hvf,ipa-granule-size=4096"])
        #expect(!arguments.contains("-vnc"))
        let spice = try #require(values(of: "-spice", in: arguments).first)
        #expect(spice.contains("unix=on,addr=/tmp/private,,display/display.sock"))
        #expect(spice.contains("gl=on") && spice.contains("disable-copy-paste=on") && spice.contains("disable-agent-file-xfer=on"))
        #expect(spice.contains("agent-mouse=off"))
        #expect(objects("-device", in: arguments).contains { $0["name"] as? String == "com.redhat.spice.0" })
        let gpu = try #require(objects("-device", in: arguments).first { $0["id"] as? String == "gpu" })
        #expect(gpu["driver"] as? String == "virtio-ramfb-gl")
        #expect(gpu["neptune"] as? Bool == true && gpu["blob"] as? Bool == true)
        line.restoresSavedState = true
        #expect(throws: QEMUError.self) { try line.arguments() }
        #expect(values(of: "-machine", in: try commandLine(restoring: true).arguments()) == [QEMUCommandLine.machineType])
    }

    @Test func aRestoredMachineHasEachDriveInThePortItWasSavedIn() throws {
        // The stick went into the first free port before the installer, which was plugged in later.
        let saved = [stick.id: 4, installer.id: 6]
        let tool = RemovableImage(path: "/Downloads/tools.iso", readOnly: true)
        let restored = commandLine(restoring: true, drives: [installer, tool, stick], usbPorts: saved)
        let ports = try restored.startingUSBPorts()
        #expect(ports[stick.id] == 4 && ports[installer.id] == 6)
        // A drive that wasn't plugged in then takes a port nobody had.
        #expect(ports[tool.id] == 5)
        let devices = objects("-device", in: try restored.arguments())
        let port = { (image: RemovableImage) in devices.first { $0["id"] as? String == QEMUCommandLine.imageDeviceID(for: image) }?["port"] as? String }
        #expect(port(installer) == "6" && port(stick) == "4" && port(tool) == "5")
    }

    @Test func theSoundCardIsLeftOutOfARestoreAndPluggedInAfterwards() throws {
        let isSound = { (device: [String: Any]) in device["driver"] as? String == "usb-audio" }
        #expect(objects("-device", in: try commandLine().arguments()).contains(where: isSound))
        // QEMU can't save it, so the machine was saved without it.
        #expect(!objects("-device", in: try commandLine(restoring: true).arguments()).contains(where: isSound))
    }

    @Test func startsWithTheDisplayItIsGiven() throws {
        let framebuffer = objects("-device", in: try commandLine(display: .framebuffer).arguments())
        #expect(framebuffer.contains { $0["driver"] as? String == "ramfb" })
        #expect(!framebuffer.contains { $0["driver"] as? String == "virtio-gpu-pci" })
        let gpu = objects("-device", in: try commandLine(display: .virtioGPU).arguments())
        #expect(gpu.contains { $0["driver"] as? String == "virtio-gpu-pci" && $0["xres"] as? Int == 1920 })
        #expect(!gpu.contains { $0["driver"] as? String == "ramfb" })
    }

    @Test func aCommaInAPathOrNameStaysPartOfIt() throws {
        var configuration = commandLine().configuration
        configuration.name = "One, Two=2"
        let arguments = try QEMUCommandLine(
            configuration: configuration, bundle: VMBundle(url: URL(fileURLWithPath: "/Machines/One, Two.swiftvm")),
            installation: installation, diskSources: [disk.id: .file(URL(fileURLWithPath: "/a.img"))], display: .framebuffer
        ).arguments()
        #expect(values(of: "-drive", in: arguments) == ["if=pflash,unit=1,format=raw,file=/Machines/One,, Two.swiftvm/efi-vars.fd"])
        #expect(values(of: "-name", in: arguments) == ["guest=One,, Two=2"])
    }
}

@Suite struct QEMULeftoverTests {
    private let machine = UUID()

    @Test func knowsTheQEMUOfTheMachineByItsIdentity() {
        let arguments = ["/Old App.app/Contents/Helpers/QEMU/bin/qemu-system-aarch64", "-name", "Windows", "-uuid", machine.uuidString.lowercased()]
        #expect(QEMUProcess.isQEMU(arguments, runningMachine: machine))
        // Another machine's QEMU, and a process that took over the number, are left alone.
        #expect(!QEMUProcess.isQEMU(arguments, runningMachine: UUID()))
        #expect(!QEMUProcess.isQEMU(["/bin/sleep", "-uuid", machine.uuidString], runningMachine: machine))
    }
}

@MainActor
@Suite struct WindowsDisplayAdapterTests {
    @Test func aWindowsMachineCanBootAfterItsDirect3DRuntimeIsRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var installation = QEMUInstallation(
            program: directory.appending(path: "bin/qemu-system-aarch64"),
            dataDirectory: directory.appending(path: "share"), acceleratesGraphics: true
        )
        let driver = InstallationConfiguration(hasDisplayDriver: true, hasAcceleratedDisplayDriver: true)
        let dxmt = installation.libraryDirectory.appending(path: "libdxmt-native.dylib")
        try FileManager.default.createDirectory(at: installation.libraryDirectory, withIntermediateDirectories: true)
        try Data().write(to: dxmt)
        #expect(QEMUBackendProvider.windowsDisplayAdapter(for: driver, installation: installation) == .virtioGPU3D)

        // A copy without the graphics runtime must boot too, even if DXMT is still there.
        installation.acceleratesGraphics = false
        #expect(QEMUBackendProvider.windowsDisplayAdapter(for: driver, installation: installation) == .framebuffer)
        installation.acceleratesGraphics = true

        // Release builds have Linux graphics, but no Direct3D. The 3D installer removed the 2D driver,
        // although the guest reported both display capabilities, so only the framebuffer is safe.
        try FileManager.default.removeItem(at: dxmt)
        #expect(QEMUBackendProvider.windowsDisplayAdapter(for: driver, installation: installation) == .framebuffer)

        // Nothing about the guest's driver was forgotten: a Direct3D build can use it again.
        try Data().write(to: dxmt)
        #expect(QEMUBackendProvider.windowsDisplayAdapter(for: driver, installation: installation) == .virtioGPU3D)
    }
}

@MainActor
@Suite struct InstallerBootTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")

    private func bundle(writing bytes: Int, discs: [RemovableImage]) throws -> (VMConfiguration, VMBundle) {
        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 30, bus: .nvme, format: .raw)
        let configuration = VMConfiguration(name: "Windows", os: GuestOS(family: .windows), cpuCount: 2, memorySize: 4 << 30, disks: [disk], removableImages: discs)
        let bundle = try VMBundle.create(at: directory.appending(path: "\(UUID().uuidString).swiftvm"), configuration: configuration)
        FileManager.default.createFile(atPath: bundle.diskURL(for: disk).path, contents: Data(count: bytes))
        return (configuration, bundle)
    }

    @Test func pressesAKeyOnlyForAnInstallerThatHasAnEmptyDiskToInstallTo() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let disc = RemovableImage(path: "/Downloads/Windows.iso", readOnly: true)
        let (fresh, freshBundle) = try bundle(writing: 0, discs: [disc])
        #expect(QEMUBackendProvider.bootsInstaller(fresh, bundle: freshBundle))
        // Once the installer has written to the disk, a start carries on from there.
        let (installed, installedBundle) = try bundle(writing: 32 << 20, discs: [disc])
        #expect(!QEMUBackendProvider.bootsInstaller(installed, bundle: installedBundle))
        let (noDisc, noDiscBundle) = try bundle(writing: 0, discs: [])
        #expect(!QEMUBackendProvider.bootsInstaller(noDisc, bundle: noDiscBundle))
        // A key on a Linux disc would stop its boot menu's countdown.
        var linux = fresh
        linux.os = GuestOS(family: .linux)
        #expect(!QEMUBackendProvider.bootsInstaller(linux, bundle: freshBundle))
    }
}

@Suite struct SavedStateHeaderTests {
    @Test func theDrivesPortsComeBackFromTheSavedStateQEMUWroteAfterThem() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        // QEMU writes its part from the header's size on, and leaves what is before it empty.
        let stream = Data("QEVM".utf8) + Data(repeating: 7, count: 100)
        var file = Data(count: SavedStateHeader.size)
        file.append(stream)
        try file.write(to: url)

        let header = SavedStateHeader(usbPorts: [UUID(): 4, UUID(): 9])
        try header.write(into: url)
        #expect(try SavedStateHeader.read(from: url) == header)
        // QEMU's part is as it wrote it.
        #expect(try Data(contentsOf: url).dropFirst(SavedStateHeader.size) == stream)
    }

    @Test func aFileWithoutTheHeaderIsNoStateToResume() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: SavedStateHeader.size + 16).write(to: url)
        #expect(throws: QEMUError.self) { try SavedStateHeader.read(from: url) }
    }
}
