import Foundation
import Testing
import VMCore
@testable import VZEngine

@Suite struct MacRestoreImageTests {
    private func image(_ major: Int, _ minor: Int, _ patch: Int, url: String = "file:///tmp/Restore.ipsw", supported: Bool = true) -> MacRestoreImage {
        MacRestoreImage(
            url: URL(string: url)!,
            majorVersion: major, minorVersion: minor, patchVersion: patch,
            buildVersion: "26A434",
            requirements: supported ? .init(hardwareModel: Data([1, 2, 3]), minimumCPUCount: 2, minimumMemorySize: 4 << 30) : nil
        )
    }

    @Test func namesTheSystemLikeAboutThisMac() {
        #expect(image(27, 0, 1).productName == "macOS 27.0.1")
        #expect(image(27, 0, 0).productName == "macOS 27.0")
        #expect(image(27, 0, 1).guestOS.summary == "macOS 27.0.1 (26A434)")
        #expect(image(27, 0, 1).guestOS.family == .macOS)
    }

    @Test func onlyMacOS27AndLaterSetThemselvesUp() {
        #expect(image(27, 0, 0).supportsProvisioning)
        #expect(image(28, 1, 0).supportsProvisioning)
        #expect(!image(26, 4, 0).supportsProvisioning)
    }

    @Test func tellsDownloadsFromFiles() {
        #expect(!image(27, 0, 1).isRemote)
        #expect(image(27, 0, 1, url: "https://updates.cdn-apple.com/x/UniversalMac_27.0.1_26A434_Restore.ipsw").isRemote)
    }

    @Test func refusesToLoadWhatIsNotAFile() async {
        await #expect(throws: MacRestoreImage.ImageError.self) {
            try await MacRestoreImage.load(from: URL(string: "https://example.com/Restore.ipsw")!)
        }
        await #expect(throws: MacRestoreImage.ImageError.self) {
            try await MacRestoreImage.load(from: URL(fileURLWithPath: "/tmp/swiftvm-missing-\(UUID().uuidString).ipsw"))
        }
        await #expect(throws: MacRestoreImage.ImageError.self) {
            try await MacRestoreImage.load(from: FileManager.default.temporaryDirectory)
        }
    }

    @MainActor
    @Test func installRefusesImagesItCannotUse() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = VMConfiguration(name: "Mac", os: GuestOS(family: .macOS), cpuCount: 4, memorySize: 8 << 30, disks: [])
        let bundle = try VMBundle.create(at: directory.appending(path: "Mac.swiftvm"), configuration: configuration)

        await #expect(throws: MacOSInstaller.InstallError.self) {
            try await MacOSInstaller.install(image(27, 0, 1, supported: false), into: bundle, configuration: configuration) { _ in }
        }
        await #expect(throws: MacOSInstaller.InstallError.self) {
            try await MacOSInstaller.install(image(27, 0, 1, url: "https://example.com/Restore.ipsw"), into: bundle, configuration: configuration) { _ in }
        }
    }

    @Test func checksAccountsTheWayMacOSDoes() throws {
        try GuestProvisioning(fullName: "Test User", userName: "tester", password: "correct horse").validateForMacOS()
        #expect(throws: (any Error).self) {
            try GuestProvisioning(fullName: "Test User", userName: "", password: "correct horse").validateForMacOS()
        }
    }
}
