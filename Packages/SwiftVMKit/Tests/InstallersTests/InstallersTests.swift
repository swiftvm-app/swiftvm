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

    @Test func sendsKernelMessagesToTheSerialConsole() {
        let text = seed.userData
        #expect(text.contains("write_files:\n  - path: \"/etc/default/grub.d/99-swiftvm-console.cfg\"\n    content: \""))
        // One line of YAML, with the display named after the serial console so that it stays the system console.
        #expect(text.contains(#"GRUB_CMDLINE_LINUX_DEFAULT=\"$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 console=tty1\"\n""#))
        #expect(text.contains("runcmd:\n  - \"command -v update-grub >/dev/null && update-grub || true\"\n"))

        var displayOnly = seed
        displayOnly.kernelMessagesOnSerialConsole = false
        #expect(!displayOnly.userData.contains("hvc0"))
        #expect(!displayOnly.userData.contains("update-grub"))
        // With nothing to write and nothing to run, neither list is there.
        displayOnly.guestAgentInstaller = nil
        #expect(!displayOnly.userData.contains("write_files"))
        #expect(!displayOnly.userData.contains("runcmd"))

        // With Rosetta there are two things to run, in one list.
        var withRosetta = seed
        withRosetta.rosettaTag = GuestIntegration.rosettaTag
        withRosetta.guestAgentInstaller = nil
        #expect(withRosetta.userData.components(separatedBy: "runcmd:").count == 2)
        #expect(withRosetta.userData.hasSuffix("  - \"command -v update-grub >/dev/null && update-grub || true\"\n"))
    }

    @Test func installsTheGuestAgentOnTheFirstBoot() throws {
        let text = seed.userData
        // Both files are in the one list of files to write, and the installer runs last.
        #expect(text.components(separatedBy: "write_files:").count == 2)
        #expect(text.components(separatedBy: "runcmd:").count == 2)
        #expect(text.hasSuffix("  - \"sh /usr/local/lib/swiftvm/install.sh || true\"\n"))

        let lines = text.components(separatedBy: "\n")
        let path = try #require(lines.firstIndex(of: "  - path: \"/usr/local/lib/swiftvm/install.sh\""))
        #expect(lines[path + 1] == "    encoding: b64")
        #expect(lines[path + 3] == "    permissions: \"0755\"")
        // What arrives in the guest is the installer, byte for byte.
        let content = lines[path + 2]
        #expect(content.hasPrefix("    content: \"") && content.hasSuffix("\""))
        let decoded = try #require(Data(base64Encoded: String(content.dropFirst("    content: \"".count).dropLast())))
        #expect(String(decoding: decoded, as: UTF8.self) == (try LinuxGuestAgent.installer()))

        var without = seed
        without.guestAgentInstaller = nil
        #expect(!without.userData.contains("install.sh"))
        #expect(without.userData.contains("update-grub"))
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

    @Test func aCopyOfTheMachineGetsASeedOfItsOwn() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-seed-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try seed.writeImage(to: url)
        #expect(try ISOImageBuilder.text(of: "user-data", in: url) == seed.userData)

        try CloudInitSeed.reissue(at: url, hostName: "ubuntu-copy", macAddress: "02:AA:BB:CC:DD:EE", instanceID: "new-456")
        // A new instance with the new name and network card…
        #expect(try ISOImageBuilder.text(of: "meta-data", in: url) == "instance-id: \"new-456\"\nlocal-hostname: \"ubuntu-copy\"\n")
        let network = try ISOImageBuilder.text(of: "network-config", in: url)
        #expect(network.contains("macaddress: \"02:aa:bb:cc:dd:ee\""))
        #expect(!network.contains("02:1a:2b:3c:4d:5e"))
        // …under its new name. The account isn't set up again: it is on the copied disk as it is now, and
        // the password of the day the original was made must not come back.
        let userData = try ISOImageBuilder.text(of: "user-data", in: url)
        #expect(userData.contains("hostname: \"ubuntu-copy\""))
        #expect(userData.contains("users: []"))
        #expect(!userData.contains("p@ss: word"))
        #expect(!userData.contains("saeed"))
        #expect(!userData.contains("chpasswd"))
        #expect(!userData.contains("ssh_pwauth"))
        #expect(!userData.contains("ssh-ed25519"))
        // Everything else is as it was.
        #expect(userData.contains("timezone: \"Europe/Berlin\""))
        #expect(userData.contains("growpart:\n  mode: auto\n  devices: [\"/\"]"))
        #expect(userData.contains("  - [\"swiftvm\", \"/mnt/shared\", virtiofs, \"rw,nofail\", \"0\", \"0\"]"))
        #expect(userData.contains("write_files:\n  - path: \"/etc/default/grub.d/99-swiftvm-console.cfg\""))
        #expect(userData.contains("update-grub"))
        // The copy installs the agent anew, which does no harm to the one on the copied disk.
        #expect(userData.contains("  - path: \"/usr/local/lib/swiftvm/install.sh\"\n    encoding: b64\n"))
        #expect(userData.hasSuffix("  - \"sh /usr/local/lib/swiftvm/install.sh || true\"\n"))
        #expect(userData.hasPrefix("#cloud-config\n"))
    }

    @Test func aCopyGetsThisBuildsGuestAgent() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-seed-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        // The original was made by a build with an older agent, and has since been given a newer one.
        var old = seed
        old.guestAgentInstaller = "#!/bin/sh\necho an agent of long ago\n"
        try old.writeImage(to: url)
        let longAgo = Data("#!/bin/sh\necho an agent of long ago\n".utf8).base64EncodedString()
        #expect(try ISOImageBuilder.text(of: "user-data", in: url).contains(longAgo))

        // The copy's first boot must not put the old one back.
        try CloudInitSeed.reissue(at: url, hostName: "ubuntu-copy", macAddress: nil)
        let userData = try ISOImageBuilder.text(of: "user-data", in: url)
        #expect(!userData.contains(longAgo))
        let current = Data(try LinuxGuestAgent.installer().utf8).base64EncodedString()
        #expect(userData.contains("  - path: \"/usr/local/lib/swiftvm/install.sh\"\n    encoding: b64\n    content: \"\(current)\"\n    permissions: \"0755\"\n"))
        #expect(userData.hasSuffix("  - \"sh /usr/local/lib/swiftvm/install.sh || true\"\n"))

        // A machine that was made without the agent doesn't get one by being copied.
        var without = seed
        without.guestAgentInstaller = nil
        try without.writeImage(to: url)
        try CloudInitSeed.reissue(at: url, hostName: "ubuntu-copy", macAddress: nil)
        #expect(!(try ISOImageBuilder.text(of: "user-data", in: url)).contains("install.sh"))
        #expect(CloudInitSeed.replacingGuestAgentInstaller(in: without.userData, with: "new") == without.userData)
    }

    @Test func accountSectionsAreRemovedWhole() {
        let document = """
        #cloud-config
        hostname: "a"
        users:
          - name: "me"
            ssh_authorized_keys:
              - "key"
        ssh_pwauth: true
        chpasswd:
          expire: false
          users:
            - name: "me"
              password: "secret"
        growpart:
          mode: auto
        runcmd:
          - "echo users: stay"

        """
        #expect(CloudInitSeed.removingAccountSetup(from: document) == """
        #cloud-config
        hostname: "a"
        users: []
        growpart:
          mode: auto
        runcmd:
          - "echo users: stay"

        """)
        // A document without an account section is left alone.
        #expect(CloudInitSeed.removingAccountSetup(from: "#cloud-config\nhostname: \"a\"\n") == "#cloud-config\nhostname: \"a\"\n")
    }

    @Test func onlyTheHostNameLineChanges() {
        let document = "#cloud-config\nhostname: \"old\"\nusers:\n  - name: \"hostname: tricky\"\n"
        #expect(CloudInitSeed.replacingHostName(in: document, with: "new")
            == "#cloud-config\nhostname: \"new\"\nusers:\n  - name: \"hostname: tricky\"\n")
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

/// A minimal HTTP server for one file that stops partway through the first request: it hangs up, the way
/// a connection drops in the middle of a download, or sends nothing more until the client goes away, the
/// way a download is cut short by the user. Later requests are answered in full, honoring `Range`.
private final class FlakyFileServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var ranges: [String?] = []

    /// The `Range` header of every request received so far (`nil` for a request without one).
    var requestedRanges: [String?] { lock.withLock { ranges } }

    /// - Parameter waitsForClient: After `cutoff` bytes of the first response, keep the connection open
    ///   until the client closes it instead of hanging up.
    init(payload: Data, droppingFirstResponseAfter cutoff: Int, waitsForClient: Bool = false) throws {
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
                let isCutShort = serve(connection, payload: payload, cutoff: cutoff)
                if isCutShort, waitsForClient {
                    var byte: UInt8 = 0
                    while read(connection, &byte, 1) > 0 {}
                }
                close(connection)
            }
        }
        thread.start()
    }

    func stop() {
        close(descriptor)
    }

    /// Answers one request. Returns whether the answer stopped short of the whole file.
    private func serve(_ connection: Int32, payload: Data, cutoff: Int) -> Bool {
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
        var isCutShort = false
        if let range, let start = Int(range.dropFirst("bytes=".count).prefix { $0 != "-" }), start < payload.count {
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(payload.count - 1)/\(payload.count)\r\nContent-Length: \(payload.count - start)\r\n"
            response = Data((header + common + "\r\n").utf8) + payload.dropFirst(start)
        } else {
            response = Data(("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\n" + common + "\r\n").utf8)
            // The first answer promises the whole file and stops short of it.
            response += isFirstRequest ? payload.prefix(cutoff) : payload
            isCutShort = isFirstRequest && cutoff < payload.count
        }
        response.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(connection, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
        return isCutShort
    }
}

/// Removes the system's temporary file that an unfinished download keeps its bytes in, for tests that end
/// with one. The file's name is in URLSession's resume data.
private func discardTemporaryFile(of unfinished: URL) {
    guard let data = try? Data(contentsOf: unfinished),
          let saved = try? PropertyListDecoder().decode(UnfinishedDownload.self, from: data),
          let archive = try? PropertyListSerialization.propertyList(from: saved.resumeData, format: nil) as? [String: Any],
          let objects = archive["$objects"] as? [Any]
    else { return }
    for case let name as String in objects where name.hasPrefix("CFNetworkDownload_") && name.hasSuffix(".tmp") {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: name))
    }
}

/// A file whose every 64 KB block has its own byte value, so that one stitched together at the wrong offset shows.
private func blockPatternedPayload() -> Data {
    var payload = Data()
    for block in 0..<96 {
        payload.append(Data(repeating: UInt8(block), count: 64 << 10))
    }
    return payload
}

@Suite struct ImageDownloaderResumeTests {
    @Test func carriesOnAfterTheConnectionDrops() async throws {
        let payload = blockPatternedPayload()
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
        // Nothing is left behind for a download that is complete.
        #expect(!FileManager.default.fileExists(atPath: downloader.unfinishedDownloadURL(for: image).path))
    }

    @Test func carriesOnAfterBeingCancelledAndTheAppOpenedAgain() async throws {
        let payload = blockPatternedPayload()
        let server = try FlakyFileServer(payload: payload, droppingFirstResponseAfter: 2 << 20, waitsForClient: true)
        defer { server.stop() }
        let cache = FileManager.default.temporaryDirectory.appending(path: "swiftvm-downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = RemoteImage(url: URL(string: "http://127.0.0.1:\(server.port)/image.img")!)

        let downloader = ImageDownloader(cacheDirectory: cache)
        let (arrivals, arrival) = AsyncStream<Void>.makeStream()
        let attempt = Task {
            try await downloader.fetch(image) { progress in
                if progress.bytesReceived >= 1 << 20 {
                    arrival.yield()
                }
            }
        }
        for await _ in arrivals { break }

        // What the app does on its way out: it cancels, and waits only until what has arrived is put away.
        attempt.cancel()
        #expect(downloader.waitForDownloadsToWindUp(timeout: 10))
        let unfinished = downloader.unfinishedDownloadURL(for: image)
        #expect(FileManager.default.fileExists(atPath: unfinished.path))
        await #expect(throws: URLError.self) { try await attempt.value }
        #expect(!downloader.isCached(image))

        // A downloader of its own, as the app has after it is opened again.
        let file = try await ImageDownloader(cacheDirectory: cache).fetch(image) { _ in }
        #expect(try Data(contentsOf: file) == payload)
        let ranges = server.requestedRanges
        #expect(ranges.count == 2)
        #expect(ranges.first == .some(nil))
        #expect(ranges.last??.hasPrefix("bytes=") == true)
        #expect(ranges.last != .some("bytes=0-"))
        #expect(!FileManager.default.fileExists(atPath: unfinished.path))
    }

    @Test func aDownloadThatIsCancelledBeforeItBeginsEndsAsWell() async throws {
        let payload = blockPatternedPayload()
        let server = try FlakyFileServer(payload: payload, droppingFirstResponseAfter: payload.count)
        defer { server.stop() }
        let cache = FileManager.default.temporaryDirectory.appending(path: "swiftvm-downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = RemoteImage(url: URL(string: "http://127.0.0.1:\(server.port)/image.img")!)
        let downloader = ImageDownloader(cacheDirectory: cache)

        for _ in 0..<20 {
            let (endings, ending) = AsyncStream<Void>.makeStream()
            let attempt = Task {
                defer { ending.yield() }
                return try await downloader.fetch(image) { _ in }
            }
            attempt.cancel()
            // Give up waiting after a while rather than hang with it.
            let watchdog = Task {
                try await Task.sleep(for: .seconds(5))
                ending.finish()
            }
            var didEnd = false
            for await _ in endings {
                didEnd = true
                break
            }
            watchdog.cancel()
            #expect(didEnd)
            guard didEnd else { return }
            // Whether it was cancelled in time or got through, nothing of it is under way any more.
            #expect(downloader.waitForDownloadsToWindUp(timeout: 5))
            try? FileManager.default.removeItem(at: downloader.cachedURL(for: image))
        }
        discardTemporaryFile(of: downloader.unfinishedDownloadURL(for: image))
    }

    @Test func startsOverWhenWhatWasLeftCanNotBeUsed() async throws {
        let payload = blockPatternedPayload()
        let server = try FlakyFileServer(payload: payload, droppingFirstResponseAfter: payload.count)
        defer { server.stop() }
        let cache = FileManager.default.temporaryDirectory.appending(path: "swiftvm-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = RemoteImage(url: URL(string: "http://127.0.0.1:\(server.port)/image.img")!)

        let downloader = ImageDownloader(cacheDirectory: cache)
        let unfinished = downloader.unfinishedDownloadURL(for: image)
        UnfinishedDownload(url: image.url, resumeData: Data("not resume data".utf8)).save(to: unfinished)

        let file = try await downloader.fetch(image) { _ in }
        #expect(try Data(contentsOf: file) == payload)
        #expect(server.requestedRanges == [nil])
        #expect(!FileManager.default.fileExists(atPath: unfinished.path))
    }

    @Test func keepsWhatWasLeftWhenTheServerCanNotBeReached() async throws {
        let payload = blockPatternedPayload()
        let server = try FlakyFileServer(payload: payload, droppingFirstResponseAfter: 2 << 20, waitsForClient: true)
        let cache = FileManager.default.temporaryDirectory.appending(path: "swiftvm-downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = RemoteImage(url: URL(string: "http://127.0.0.1:\(server.port)/image.img")!)

        var downloader = ImageDownloader(cacheDirectory: cache)
        downloader.resumeDelay = .milliseconds(5)
        let unfinished = downloader.unfinishedDownloadURL(for: image)
        let (arrivals, arrival) = AsyncStream<Void>.makeStream()
        let attempt = Task { [downloader] in
            try await downloader.fetch(image) { progress in
                if progress.bytesReceived >= 1 << 20 {
                    arrival.yield()
                }
            }
        }
        for await _ in arrivals { break }
        attempt.cancel()
        _ = await attempt.result
        #expect(FileManager.default.fileExists(atPath: unfinished.path))

        // The next attempt finds nobody at the address. What had arrived is still worth keeping.
        server.stop()
        await #expect(throws: URLError.self) { try await downloader.fetch(image) { _ in } }
        #expect(FileManager.default.fileExists(atPath: unfinished.path))
        discardTemporaryFile(of: unfinished)
    }

    @Test func whatCanNotBeUsedIsNotKeptAnyLonger() async throws {
        // Nobody listens at this address, so starting over fails as well.
        let server = try FlakyFileServer(payload: Data(), droppingFirstResponseAfter: 0)
        server.stop()
        let cache = FileManager.default.temporaryDirectory.appending(path: "swiftvm-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = RemoteImage(url: URL(string: "http://127.0.0.1:\(server.port)/image.img")!)

        let downloader = ImageDownloader(cacheDirectory: cache)
        let unfinished = downloader.unfinishedDownloadURL(for: image)
        UnfinishedDownload(url: image.url, resumeData: Data("not resume data".utf8)).save(to: unfinished)

        await #expect(throws: URLError.self) { try await downloader.fetch(image) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: unfinished.path))
    }

    @Test func whatWasLeftOfAnotherDownloadIsNotUsed() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "swiftvm-unfinished-\(UUID().uuidString).resume")
        defer { try? FileManager.default.removeItem(at: file) }
        let url = URL(string: "https://example.com/a/image.img")!
        let data = Data("resume data".utf8)

        UnfinishedDownload(url: url, resumeData: data).save(to: file)
        #expect(UnfinishedDownload.take(from: file, for: url) == data)
        // Taken means gone: a second download of the same image starts on its own.
        #expect(UnfinishedDownload.take(from: file, for: url) == nil)

        // The same file name at another address is another file.
        UnfinishedDownload(url: url, resumeData: data).save(to: file)
        #expect(UnfinishedDownload.take(from: file, for: URL(string: "https://example.org/b/image.img")!) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
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
