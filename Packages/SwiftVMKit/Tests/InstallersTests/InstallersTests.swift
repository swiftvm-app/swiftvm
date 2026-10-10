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

/// A minimal HTTP server for one file that hangs up partway through the first request, the way a
/// connection drops in the middle of a download. Later requests are answered in full, honoring `Range`.
private final class FlakyFileServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var ranges: [String?] = []

    /// The `Range` header of every request received so far (`nil` for a request without one).
    var requestedRanges: [String?] { lock.withLock { ranges } }

    init(payload: Data, droppingFirstResponseAfter cutoff: Int) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && listen(descriptor, 4) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard descriptor >= 0, bound else { throw CocoaError(.fileNoSuchFile) }
        self.descriptor = descriptor
        port = UInt16(bigEndian: address.sin_port)

        let thread = Thread { [self] in
            while true {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { return }
                serve(connection, payload: payload, cutoff: cutoff)
                close(connection)
            }
        }
        thread.start()
    }

    func stop() {
        close(descriptor)
    }

    private func serve(_ connection: Int32, payload: Data, cutoff: Int) {
        var noSignal: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var request = Data()
        var byte: UInt8 = 0
        while !request.suffix(4).elementsEqual("\r\n\r\n".utf8), read(connection, &byte, 1) == 1 {
            request.append(byte)
        }
        let range = String(decoding: request, as: UTF8.self)
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        let isFirstRequest = lock.withLock {
            ranges.append(range)
            return ranges.count == 1
        }

        let common = "Accept-Ranges: bytes\r\nETag: \"v1\"\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n"
        var response: Data
        if let range, let start = Int(range.dropFirst("bytes=".count).prefix { $0 != "-" }), start < payload.count {
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(payload.count - 1)/\(payload.count)\r\nContent-Length: \(payload.count - start)\r\n"
            response = Data((header + common + "\r\n").utf8) + payload.dropFirst(start)
        } else {
            response = Data(("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\n" + common + "\r\n").utf8)
            // The first answer promises the whole file and stops short of it.
            response += isFirstRequest ? payload.prefix(cutoff) : payload
        }
        response.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(connection, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}

@Suite struct ImageDownloaderResumeTests {
    @Test func carriesOnAfterTheConnectionDrops() async throws {
        // Every 64 KB block has its own byte value, so a file stitched together at the wrong offset shows.
        var payload = Data()
        for block in 0..<96 {
            payload.append(Data(repeating: UInt8(block), count: 64 << 10))
        }
        let server = try FlakyFileServer(payload: payload, droppingFirstResponseAfter: 2 << 20)
        defer { server.stop() }
        let cache = FileManager.default.temporaryDirectory.appending(path: "swiftvm-downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }

        var downloader = ImageDownloader(cacheDirectory: cache)
        downloader.resumeDelay = .milliseconds(20)
        let image = RemoteImage(url: URL(string: "http://127.0.0.1:\(server.port)/image.img")!)
        let file = try await downloader.fetch(image) { _ in }

        #expect(try Data(contentsOf: file) == payload)
        let ranges = server.requestedRanges
        #expect(ranges.count == 2)
        #expect(ranges.first == .some(nil))
        // The second request asks for the rest only.
        #expect(ranges.last??.hasPrefix("bytes=") == true)
        #expect(ranges.last != .some("bytes=0-"))
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
