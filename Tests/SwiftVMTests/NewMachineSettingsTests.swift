import Foundation
import Testing
import VMCore
@testable import SwiftVM
@testable import VZEngine

@MainActor
@Suite struct NewMachineSettingsTests {
    @Test func macCreationKeepsEditsAndMeetsTheChosenImagesRequirements() {
        var settings = MacMachineSettings()
        settings.cpuCount = 6
        settings.memoryGigabytes = 12
        settings.diskGigabytes = 256
        settings.userName = "builder"
        settings.fullName = "Build Account"
        settings.password = "build-password"
        settings.logsInAutomatically = false
        settings.installsSSHKey = false
        settings.location = URL(fileURLWithPath: "/tmp/custom-machines")
        let image = MacRestoreImage(
            url: URL(fileURLWithPath: "/tmp/install.ipsw"), majorVersion: 27, minorVersion: 0,
            patchVersion: 0, buildVersion: "test",
            requirements: .init(hardwareModel: Data(), minimumCPUCount: 8, minimumMemorySize: 16 << 30)
        )

        let request = settings.request(name: "Build Mac", image: image)
        #expect(request.cpuCount >= 8)
        #expect(request.memorySize >= 16 << 30)
        #expect(request.diskCapacity == 256 << 30)
        #expect(request.location == settings.location)
        #expect(request.account?.password == "build-password")
        #expect(request.account?.userName == "builder")
        #expect(request.account?.fullName == "Build Account")
        #expect(request.account?.logsInAutomatically == false)
        #expect(!request.installsSSHKey)
        #expect(request.image == image)
    }

    @Test(arguments: ["root", "Jane.Doe", "123", ""])
    func macAccountStartsWithAUsableNameWhenTheHostNameIsNotUsable(hostName: String) {
        var settings = MacMachineSettings(hostUserName: hostName, hostFullName: "")
        settings.password = "keep-this-password"
        let account = settings.account
        #expect(GuestProvisioning.problem(withUserName: account.userName) == nil)
        #expect(!account.fullName.isEmpty)
        #expect(account.password == "keep-this-password")
    }

    @Test func olderMacImagesStillUseTheGuestSetupAssistant() {
        let image = MacRestoreImage(
            url: URL(fileURLWithPath: "/tmp/older.ipsw"), majorVersion: 26, minorVersion: 0,
            patchVersion: 0, buildVersion: "test", requirements: nil
        )
        let request = MacMachineSettings().request(name: "Older Mac", image: image)
        #expect(request.image == image)
        #expect(request.account == nil)
        #expect(!request.installsSSHKey)
    }

    @Test func templateCreationKeepsExactHardwareUntilItIsEdited() {
        let configuration = VMConfiguration(
            name: "Base", os: GuestOS(family: .linux), cpuCount: 3,
            memorySize: (4 << 30) + 512,
            disks: [DiskConfiguration(fileName: "disk.img", capacity: (64 << 30) + 512, format: .raw)]
        )
        let template = VMTemplate(name: "Base", configuration: configuration)
        var settings = TemplateMachineSettings(template: template)
        // Whole-GB controls must not round the template's existing hardware on creation.
        let untouched = settings.request(name: "Copy", template: template)
        #expect(untouched.memorySize == nil)
        #expect(untouched.diskCapacity == nil)

        settings.cpuCount = 6
        settings.memoryGigabytes = 12
        settings.diskGigabytes = 128
        settings.location = URL(fileURLWithPath: "/tmp/custom-machines")
        let advanced = settings.request(name: "Copy", template: template)
        #expect(advanced.cpuCount == 6)
        #expect(advanced.memorySize == 12 << 30)
        #expect(advanced.diskCapacity == 128 << 30)
        #expect(advanced.location == settings.location)
    }
}
