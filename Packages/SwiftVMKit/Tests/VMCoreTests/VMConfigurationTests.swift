import Foundation
import Testing
@testable import VMCore

@Suite struct VMConfigurationTests {
    private func sample() -> VMConfiguration {
        VMConfiguration(
            name: "Ubuntu 26.04",
            os: GuestOS(family: .linux, distribution: "ubuntu", productName: "Ubuntu 26.04.1 LTS"),
            cpuCount: 4,
            memorySize: 8 * HostResources.gibibyte,
            disks: [DiskConfiguration(fileName: "disk.img", capacity: 64 * HostResources.gibibyte, format: .raw)],
            networkInterfaces: [NetworkInterfaceConfiguration(macAddress: "02:11:22:33:44:55", ipv4Address: "192.168.230.10")],
            sharedFolders: [SharedFolder(name: "Projects", path: "/Users/me/Projects")],
            ssh: SSHConfiguration(alias: "ubuntu-26-04", user: "me")
        )
    }

    @Test func roundTripsThroughBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = sample()
        let bundle = try VMBundle.create(at: directory.appending(path: "Test.swiftvm"), configuration: configuration)
        let loaded = try bundle.loadConfiguration()
        // Dates are stored with second precision.
        #expect(loaded.id == configuration.id)
        #expect(loaded.name == configuration.name)
        #expect(loaded.disks == configuration.disks)
        #expect(loaded.networkInterfaces == configuration.networkInterfaces)
        #expect(loaded.sharedFolders == configuration.sharedFolders)
        #expect(loaded.ssh == configuration.ssh)
        #expect(loaded.engine == .virtualization)
    }

    @Test func decodesMinimalDocumentWithDefaults() throws {
        let json = """
        {"id":"7B0C8D56-3A8E-4B43-9C0E-0C5E7B2B8A11","name":"Mini","os":{"family":"windows"},"cpuCount":2,"memorySize":4294967296}
        """
        let configuration = try JSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))
        #expect(configuration.schemaVersion == 1)
        #expect(configuration.engine == .qemu)
        #expect(configuration.disks.isEmpty)
        #expect(configuration.audio.outputEnabled)
        #expect(!configuration.boot.secureBoot)
    }

    @Test func rejectsNewerSchema() {
        let json = """
        {"schemaVersion":99,"id":"7B0C8D56-3A8E-4B43-9C0E-0C5E7B2B8A11","name":"Future","os":{"family":"linux"},"cpuCount":2,"memorySize":4294967296}
        """
        #expect(throws: VMConfigurationError.unsupportedSchemaVersion(99)) {
            try JSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))
        }
    }

    @Test func knowsWhichGuestsMountSharedFoldersThemselves() {
        var linux = sample()
        #expect(!linux.mountsSharedFoldersAutomatically)
        linux.installation.attachesSeedImage = true
        #expect(linux.mountsSharedFoldersAutomatically)
        var mac = sample()
        mac.os = GuestOS(family: .macOS)
        #expect(mac.mountsSharedFoldersAutomatically)
        #expect(GuestIntegration.linuxMountCommand == "sudo mkdir -p /mnt/shared && sudo mount -t virtiofs swiftvm /mnt/shared")
        #expect(GuestIntegration.linuxPersistentMountCommand == "echo 'swiftvm /mnt/shared virtiofs rw,nofail 0 0' | sudo tee -a /etc/fstab")
    }

    @Test func summarizesGuestOS() {
        #expect(GuestOS(family: .macOS, productName: "macOS 27.0.1", build: "26A434").summary == "macOS 27.0.1 (26A434)")
        #expect(GuestOS(family: .linux).summary == "Linux")
    }

    @Test func bundleFileNamesAreSafe() {
        #expect(VMLibrary.fileName(from: "Dev/Test: VM") == "Dev-Test- VM")
        #expect(VMLibrary.fileName(from: "..hidden") == "hidden")
        #expect(VMLibrary.fileName(from: "  ") == "Virtual Machine")
    }
}

@Suite struct MACAddressTests {
    @Test func parsesAndFormats() {
        #expect(MACAddress("02:1a:2b:3c:4d:5e")?.description == "02:1a:2b:3c:4d:5e")
        // Lease files strip leading zeros.
        #expect(MACAddress("2:1a:2b:3:4d:5e")?.description == "02:1a:2b:03:4d:5e")
        #expect(MACAddress("02:1a:2b:3c:4d") == nil)
        #expect(MACAddress("zz:1a:2b:3c:4d:5e") == nil)
    }

    @Test func randomAddressesAreLocalUnicast() {
        for _ in 0..<50 {
            let address = MACAddress.random()
            #expect(address.octets[0] & 0x02 == 0x02)
            #expect(address.octets[0] & 0x01 == 0)
        }
    }
}

@MainActor @Suite struct VMLibraryTests {
    @Test func createsListsAndRemovesMachines() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VMLibrary(rootDirectory: root)
        library.load()
        #expect(library.machines.isEmpty)

        let configuration = VMConfiguration(name: "Web Server", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [])
        let url = library.availableBundleURL(forName: configuration.name)
        #expect(url.lastPathComponent == "Web Server.swiftvm")
        let machine = try library.add(VMBundle.create(at: url, configuration: configuration))
        #expect(machine.state == .stopped)
        #expect(library.availableBundleURL(forName: "Web Server").lastPathComponent == "Web Server 2.swiftvm")

        // A fresh library instance finds the machine again through the index.
        let reloaded = VMLibrary(rootDirectory: root)
        reloaded.load()
        #expect(reloaded.machines.map(\.id) == [configuration.id])

        try machine.updateConfiguration { $0.cpuCount = 6 }
        #expect(try machine.bundle.loadConfiguration().cpuCount == 6)

        try library.remove(machine, movingToTrash: false)
        #expect(library.machines.isEmpty)
    }

    @Test func suspendedStateIsDetectedFromBundle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = VMConfiguration(name: "Saved", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30, disks: [])
        let bundle = try VMBundle.create(at: root.appending(path: "Saved.swiftvm"), configuration: configuration)
        try Data([1, 2, 3]).write(to: bundle.savedStateURL)
        let machine = try VirtualMachine(bundle: bundle)
        #expect(machine.state == .suspended)
        machine.discardSavedState()
        #expect(machine.state == .stopped)
        #expect(!bundle.hasSavedState)
    }
}
