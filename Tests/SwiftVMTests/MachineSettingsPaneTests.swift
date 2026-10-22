import Testing
import VMCore
@testable import SwiftVM

@Suite struct MachineSettingsPaneTests {
    private func configuration(_ os: GuestOS, engine: VMEngineKind? = nil, usb: USBConfiguration = .init()) -> VMConfiguration {
        VMConfiguration(
            name: "Test", os: os, engine: engine, cpuCount: 2, memorySize: 4 * HostResources.gibibyte, disks: [], usb: usb
        )
    }

    private let linux = GuestOS(family: .linux, distribution: "ubuntu", productName: "Ubuntu 26.04")

    @Test func startupIsOnlyForLinuxOnTheVirtualizationFramework() {
        #expect(MachineSettingsPane.panes(for: configuration(linux, engine: .virtualization), usb: .available).contains(.startup))
        #expect(!MachineSettingsPane.panes(for: configuration(linux, engine: .qemu), usb: .available).contains(.startup))
        #expect(!MachineSettingsPane.panes(for: configuration(GuestOS(family: .macOS)), usb: .available).contains(.startup))
    }

    @Test func usbIsOfferedOnlyWhereDevicesCanBeGivenOrTakenBack() {
        let rule = USBConfiguration.DeviceRule(vendorID: 1, productID: 2, name: "Key")
        #expect(MachineSettingsPane.panes(for: configuration(linux, engine: .virtualization), usb: .available).contains(.usb))
        #expect(!MachineSettingsPane.panes(for: configuration(linux, engine: .qemu), usb: .available).contains(.usb))
        #expect(!MachineSettingsPane.panes(for: configuration(linux, engine: .virtualization), usb: .notSigned).contains(.usb))
        // A machine that takes devices by itself keeps the pane, so that they can be taken back.
        let withRule = configuration(linux, engine: .virtualization, usb: USBConfiguration(autoConnect: [rule]))
        #expect(MachineSettingsPane.panes(for: withRule, usb: .notSigned).contains(.usb))
    }
}
