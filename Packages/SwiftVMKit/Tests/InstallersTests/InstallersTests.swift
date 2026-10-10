import Foundation
import Testing
import DiskTools
import VMCore
@testable import Installers

@Suite struct CloudInitSeedTests {
    private let seed = CloudInitSeed(
        hostName: "ubuntu-26-04",
        instanceID: "abc-123",
        userName: "saeed",
        fullName: "Saeed \"The\" Tester",
        password: "p@ss: word",
        authorizedKeys: ["ssh-ed25519 AAAAC3Nza host@mac"],
        macAddress: "02:1A:2B:3C:4D:5E",
        timeZone: "Europe/Berlin"
    )

    @Test func rendersUserData() {
        let text = seed.userData
        #expect(text.hasPrefix("#cloud-config\n"))
        #expect(text.contains("hostname: \"ubuntu-26-04\""))
        #expect(text.contains("timezone: \"Europe/Berlin\""))
        #expect(text.contains("  - name: \"saeed\""))
        // Quotes inside values are escaped so the YAML stays valid.
        #expect(text.contains(#"gecos: "Saeed \"The\" Tester""#))
        #expect(text.contains("      - \"ssh-ed25519 AAAAC3Nza host@mac\""))
        #expect(text.contains("lock_passwd: false"))
        #expect(text.contains("ssh_pwauth: true"))
        #expect(text.contains("      password: \"p@ss: word\""))
        #expect(text.contains("  - [\"swiftvm\", \"/mnt/shared\", virtiofs, \"rw,nofail\", \"0\", \"0\"]"))
        #expect(!text.contains("rosetta"))
    }

    @Test func keyOnlyLoginLocksPassword() {
        var keyOnly = seed
        keyOnly.password = nil
        #expect(keyOnly.userData.contains("lock_passwd: true"))
        #expect(keyOnly.userData.contains("ssh_pwauth: false"))
        #expect(!keyOnly.userData.contains("chpasswd"))
    }

    @Test func rosettaAddsMountAndRegistration() {
        var withRosetta = seed
        withRosetta.rosettaTag = GuestIntegration.rosettaTag
        #expect(withRosetta.userData.contains("[\"rosetta\", \"/media/rosetta\", virtiofs"))
        #expect(withRosetta.userData.contains("update-binfmts --install rosetta /media/rosetta/rosetta"))
    }

    @Test func rendersMetaDataAndNetworkConfig() {
        #expect(seed.metaData == "instance-id: \"abc-123\"\nlocal-hostname: \"ubuntu-26-04\"\n")
        #expect(seed.networkConfig?.contains("macaddress: \"02:1a:2b:3c:4d:5e\"") == true)
        #expect(seed.networkConfig?.contains("dhcp-identifier: mac") == true)
        var noMAC = seed
        noMAC.macAddress = nil
        #expect(noMAC.networkConfig == nil)
    }

    @Test func writesSeedImage() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-seed-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try seed.writeImage(to: url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size > 32 * 1024)
    }
}

@Suite struct ImageDownloaderTests {
    @Test func findsDigestInChecksumListings() {
        let listing = """
        c2afd538d66fdd77 *ubuntu-26.04-desktop-arm64.iso
        d31e9b3d01ac0fa8  ubuntu-26.04-server-cloudimg-arm64.img
        """
        #expect(ImageDownloader.expectedDigest(for: "ubuntu-26.04-desktop-arm64.iso", in: listing) == "c2afd538d66fdd77")
        #expect(ImageDownloader.expectedDigest(for: "ubuntu-26.04-server-cloudimg-arm64.img", in: listing) == "d31e9b3d01ac0fa8")
        #expect(ImageDownloader.expectedDigest(for: "missing.img", in: listing) == nil)
    }

    @Test func computesDigests() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try ImageDownloader.digest(of: url, algorithm: .sha256) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try ImageDownloader.digest(of: url, algorithm: .sha512).hasPrefix("ddaf35a193617aba"))
    }
}

@Suite struct DistributionCatalogTests {
    @Test func bundledCatalogLoads() {
        #expect(!DistributionCatalog.builtIn.isEmpty)
        #expect(DistributionCatalog.quickCreate.contains { $0.id == "ubuntu-26.04" })
        for distribution in DistributionCatalog.builtIn {
            #expect(distribution.cloudImage != nil || !distribution.installers.isEmpty)
            #expect(distribution.cloudImage?.url.scheme == "https")
        }
    }
}

@Suite struct LinuxImageInstallerTests {
    @Test func installsRawImageAndGrowsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appending(path: "cloud.raw")
        let payload = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: image)

        let disk = directory.appending(path: "disk.img")
        try LinuxImageInstaller.install(image: image, to: disk, capacity: 1 << 20)
        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: payload.count) == payload)
        #expect(try DiskService.fileSize(of: disk) == 1 << 20)

        #expect(throws: LinuxImageInstaller.InstallError.self) {
            try LinuxImageInstaller.install(image: image, to: disk, capacity: 4096)
        }
    }
}
