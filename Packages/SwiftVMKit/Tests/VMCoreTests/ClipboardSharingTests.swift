import Foundation
import GuestChannel
import Testing
@testable import VMCore

@MainActor
@Suite struct ClipboardSharingTests {
    private final class TestClipboard: Clipboard {
        var changeCount = 0
        var contents = "synthetic host text"
        var reads = 0
        var text: String? {
            reads += 1
            return contents
        }
        func setText(_ text: String) {
            contents = text
            changeCount += 1
        }
    }

    @Test func olderAcceleratedLinuxGuestsNeedConsentBeforeSharing() throws {
        for (family, engine) in [("linux", "qemu"), ("linux", "virtualization"), ("windows", "qemu"), ("macOS", "virtualization")] {
            let json = """
            {"id":"7B0C8D56-3A8E-4B43-9C0E-0C5E7B2B8A11","name":"Before sharing",
             "os":{"family":"\(family)"},"engine":"\(engine)","cpuCount":2,"memorySize":2147483648,
             "clipboard":{"isShared":true}}
            """
            var configuration = try JSONDecoder().decode(VMConfiguration.self, from: Data(json.utf8))
            #expect(configuration.clipboard.isShared == (family != "linux" || engine != "qemu"))
            configuration.clipboard.isShared = true
            let saved = try JSONEncoder().encode(configuration)
            #expect(try JSONDecoder().decode(VMConfiguration.self, from: saved).clipboard.isShared)
        }
    }

    @Test func anAcceleratedLinuxGuestOnlySharesWhileEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-clipboard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = VMConfiguration(
            name: "Clipboard", os: GuestOS(family: .linux), engine: .qemu,
            cpuCount: 2, memorySize: 2 << 30, disks: [],
            clipboard: ClipboardConfiguration(isShared: false)
        )
        let machine = try VirtualMachine(bundle: VMBundle.create(at: directory, configuration: configuration))
        let clipboard = TestClipboard()
        let sharing = ClipboardSharing(clipboard: clipboard, lookInterval: .milliseconds(10))
        var descriptors: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let peer = descriptors[1]
        defer {
            machine.agent.stop()
            close(peer)
        }
        let hello = GuestMessageCoding.line(for: AgentMessage.hello(AgentHello(
            agent: "1.4", system: GuestSystem(id: "omarchy"), features: [GuestFeature.clipboard]
        )))
        _ = ByteRelay.writeAll(ArraySlice(hello), to: peer)
        let app = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        machine.agent.start { app }
        try #require(await machine.agent.waitUntilConnected(timeout: .seconds(5)))
        sharing.update(machine)
        sharing.guestWantsClipboard(machine)
        sharing.guest(machine, didCopy: "not opted in")
        #expect(!sharing.isWatching)
        #expect(clipboard.reads == 0)
        #expect(clipboard.contents == "synthetic host text")

        try machine.updateConfiguration { $0.clipboard.isShared = true }
        sharing.update(machine)
        #expect(sharing.isWatching)
        #expect(clipboard.reads > 0)
        sharing.guest(machine, didCopy: "synthetic guest text")
        #expect(clipboard.contents == "synthetic guest text")
        let changes = clipboard.changeCount
        sharing.guest(machine, didCopy: "synthetic guest text")
        #expect(clipboard.changeCount == changes)

        try machine.updateConfiguration { $0.clipboard.isShared = false }
        sharing.update(machine)
        let reads = clipboard.reads
        clipboard.setText("private after disabling")
        sharing.guestWantsClipboard(machine)
        sharing.guest(machine, didCopy: "late guest message")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!sharing.isWatching)
        #expect(clipboard.reads == reads)
        #expect(clipboard.contents == "private after disabling")
    }
}
