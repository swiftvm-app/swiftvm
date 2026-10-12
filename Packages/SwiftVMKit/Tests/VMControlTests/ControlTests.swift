import Foundation
import GuestChannel
import Testing
@testable import VMControl

@Suite struct ControlSocketTests {
    @Test func reportsWhenAppIsNotRunning() {
        let client = ControlClient(socketURL: URL(fileURLWithPath: "/tmp/swiftvm-missing-\(UUID().uuidString).sock"))
        #expect(throws: ControlSocketError.self) { try client.send(ControlRequest(command: .list)) }
    }

    @Test func readsCreateRequestsFromOlderTools() throws {
        // A tool built before macOS guests existed doesn't send `restoreImagePath`.
        let json = #"{"command":"create","create":{"distribution":"ubuntu-26.04","start":true}}"#
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(request.create == ControlRequest.CreateParameters(distribution: "ubuntu-26.04"))
        #expect(request.create?.restoreImagePath == nil)
    }

    @Test func commandsUseDashedNames() throws {
        let data = try JSONEncoder().encode(ControlRequest(command: .forceStop, machine: "vm"))
        #expect(String(decoding: data, as: UTF8.self).contains("\"force-stop\""))
        let snapshot = try JSONEncoder().encode(ControlRequest(command: .deleteSnapshot, machine: "vm", snapshot: "Before"))
        #expect(String(decoding: snapshot, as: UTF8.self).contains("\"delete-snapshot\""))
        let rename = try JSONEncoder().encode(ControlRequest(command: .renameSnapshot, machine: "vm", name: "After", snapshot: "Before"))
        #expect(String(decoding: rename, as: UTF8.self).contains("\"rename-snapshot\""))
    }

    @Test func aPlainQuitSaysNothingAboutCreations() throws {
        // What an app from before the option existed is sent, and what it sends back.
        let plain = try JSONEncoder().encode(ControlRequest(command: .quit))
        #expect(String(decoding: plain, as: UTF8.self) == #"{"command":"quit"}"#)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: plain).cancelsCreations == nil)

        let insisting = ControlRequest(command: .quit, cancelsCreations: true)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(insisting)) == insisting)
    }

    @Test func newerRequestsAndAnswersRoundTrip() throws {
        let request = ControlRequest(
            command: .forward, machine: "web",
            forward: .init(hostPort: 8080, guestPort: 80, udp: true, allowsOtherDevices: true)
        )
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)

        let response = ControlResponse(ok: true, snapshots: [
            SnapshotSummary(id: UUID(), name: "Before upgrade", createdAt: Date(timeIntervalSince1970: 1_790_000_000), includesMemory: true),
        ])
        #expect(try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response)) == response)

        // An answer from an app that knows nothing of snapshots or details still reads.
        let older = #"{"ok":true,"machines":[{"id":"7B0C8D56-3A8E-4B43-9C0E-0C5E7B2B8A11","name":"Web","state":"running","system":"Linux","cpuCount":2,"memorySize":1,"diskAllocated":0,"diskCapacity":1}]}"#
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(older.utf8))
        #expect(decoded.snapshots == nil)
        #expect(decoded.machines.first?.details == nil)
    }

    @Test func theConsoleSocketAndJobRequestsOpenAStream() {
        #expect(ControlRequest.Command.allCases.filter(\.opensStream) == [.console, .vsock, .job])
    }

    @Test func aJobTravelsInItsRequest() throws {
        let job = GuestJob.exec(.init(arguments: ["make", "test"], user: "root", directory: "/src", environment: ["CI": "1"]))
        let request = ControlRequest(command: .job, machine: "web", job: job)
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains(#""command":"job""#))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        let click = ControlRequest(command: .job, machine: "web", job: .pointer(.init(action: .click, x: 3, y: 4, count: 2)))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(click)) == click)

        let wait = ControlRequest(command: .wait, machine: "web", timeout: 30)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(wait)) == wait)
        let off = ControlRequest(command: .automation, machine: "web", isOn: false)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(off)) == off)
        // An app says whether a machine can be given jobs; one from before there were any says nothing.
        var details = MachineDetails(
            location: "/x", macAddress: nil, drives: [], sharedFolders: [], snapshotCount: 0,
            automation: .init(isAllowed: true, features: ["exec", "screen"])
        )
        #expect(try JSONDecoder().decode(MachineDetails.self, from: JSONEncoder().encode(details)) == details)
        details.automation = nil
        #expect(try JSONDecoder().decode(MachineDetails.self, from: JSONEncoder().encode(details)).automation == nil)
    }

    @Test func aTimeToWaitIsOneTheAppCanCountTo() {
        // A tool can send any number. None of them may be the app's undoing: it runs the machines.
        func wait(_ timeout: Double?) -> Duration {
            ControlRequest(command: .wait, machine: "web", timeout: timeout).waitTimeout
        }
        #expect(wait(30) == .seconds(30))
        #expect(wait(.infinity) == .seconds(300))
        #expect(wait(.nan) == .seconds(300))
        #expect(wait(1e21) == .seconds(86_400))
        #expect(wait(-5) == .zero)
    }

    @Test func aColonNamesAPlaceInAGuest() {
        #expect(CopyEndpoint("web:/etc/hosts") == .guest(machine: "web", path: "/etc/hosts"))
        #expect(CopyEndpoint("Web Server:notes.txt") == .guest(machine: "Web Server", path: "notes.txt"))
        #expect(CopyEndpoint("web:") == .guest(machine: "web", path: ""))
        // Only the first colon counts: what follows is the path, colons and all.
        #expect(CopyEndpoint("web:/tmp/a:b") == .guest(machine: "web", path: "/tmp/a:b"))
        #expect(CopyEndpoint("notes.txt") == .local("notes.txt"))
        #expect(CopyEndpoint("/Users/me/notes.txt") == .local("/Users/me/notes.txt"))
        // A slash before the colon makes it a file here whose name has a colon in it.
        #expect(CopyEndpoint("./notes:old.txt") == .local("./notes:old.txt"))
        #expect(CopyEndpoint(":odd") == .local(":odd"))
    }

    @Test func guestToolsTravelWithAMachinesDetails() throws {
        let details = MachineDetails(
            location: "/Machines/Web.swiftvm", macAddress: "02:00:00:00:00:01", drives: [], sharedFolders: [], snapshotCount: 0,
            guestTools: .init(version: "1.0", kernel: "7.0.0-34-generic")
        )
        let machine = MachineSummary(
            id: UUID(), name: "Web", state: "running", system: "Ubuntu 26.04.1 LTS", address: nil, sshAlias: "web",
            cpuCount: 2, memorySize: 1, diskAllocated: 0, diskCapacity: 1, details: details
        )
        let response = ControlResponse(ok: true, machines: [machine], note: "Run this in the guest.")
        #expect(try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response)) == response)

        // An app from before the guest tools says nothing of them, and has nothing to add to its answers.
        let older = #"{"ok":true,"machines":[{"id":"7B0C8D56-3A8E-4B43-9C0E-0C5E7B2B8A11","name":"Web","state":"running","system":"Linux","cpuCount":2,"memorySize":1,"diskAllocated":0,"diskCapacity":1,"details":{"location":"/x","drives":[],"sharedFolders":[],"snapshotCount":0}}]}"#
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(older.utf8))
        #expect(decoded.machines.first?.details != nil)
        #expect(decoded.machines.first?.details?.guestTools == nil)
        #expect(decoded.note == nil)

        let request = ControlRequest(command: .installTools, machine: "web", usesDisc: true)
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"install-tools\""))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"command":"install-tools","machine":"web"}"#.utf8)).usesDisc == nil)

        // macOS guests want the account's password before anything is installed in them.
        let withPassword = ControlRequest(command: .installTools, machine: "mac", password: "se cret\"$1")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(withPassword)) == withPassword)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data).password == nil)
    }

    @Test func theClipboardIsTurnedOnAndOffByName() throws {
        let request = ControlRequest(command: .shareClipboard, machine: "mac", isOn: false)
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"share-clipboard\""))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        #expect(!ControlRequest.Command.shareClipboard.opensStream)

        // An app says whether it shares; one from before there was a choice says nothing.
        var details = MachineDetails(location: "/x", macAddress: nil, drives: [], sharedFolders: [], snapshotCount: 0, sharesClipboard: false)
        #expect(try JSONDecoder().decode(MachineDetails.self, from: JSONEncoder().encode(details)).sharesClipboard == false)
        details.sharesClipboard = nil
        #expect(try JSONDecoder().decode(MachineDetails.self, from: JSONEncoder().encode(details)).sharesClipboard == nil)
    }

    @Test func usbDevicesAreNamedInRequestsAndListedInAnswers() throws {
        let attach = ControlRequest(command: .usbAttach, machine: "web", usbDevice: "0781:5581")
        let data = try JSONEncoder().encode(attach)
        #expect(String(decoding: data, as: UTF8.self).contains("\"usb-attach\""))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == attach)
        let rule = ControlRequest(command: .usbAuto, machine: "web", isOn: true, usbDevice: "SanDisk Ultra")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(rule)) == rule)
        #expect(try JSONEncoder().encode(ControlRequest(command: .usbList)) == Data(#"{"command":"usb-list"}"#.utf8))
        #expect(ControlRequest.Command.allCases.filter { $0.rawValue.hasPrefix("usb-") } == [.usbList, .usbAttach, .usbDetach, .usbAuto])

        let stick = USBDeviceSummary(id: 4_302_399_248, name: "Ultra", identifier: "0781:5581", manufacturer: "SanDisk", serialNumber: "4C53", machine: "Web")
        let list = ControlResponse(ok: true, note: "Plug one in.", usbDevices: [stick, USBDeviceSummary(id: 7, name: "USB Device 05e3:0751", identifier: "05e3:0751")])
        #expect(try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(list)) == list)

        var details = MachineDetails(
            location: "/x", macAddress: nil, drives: [], sharedFolders: [], snapshotCount: 0,
            usbDevices: [stick], usbAutoConnect: ["Ultra (0781:5581)"]
        )
        #expect(try JSONDecoder().decode(MachineDetails.self, from: JSONEncoder().encode(details)) == details)
        // An app from before USB devices says nothing of them, in a machine's details or anywhere else.
        details.usbDevices = nil
        details.usbAutoConnect = nil
        let older = try JSONDecoder().decode(MachineDetails.self, from: JSONEncoder().encode(details))
        #expect(older.usbDevices == nil && older.usbAutoConnect == nil)
        #expect(try JSONDecoder().decode(ControlResponse.self, from: Data(#"{"ok":true,"machines":[]}"#.utf8)).usbDevices == nil)
    }

    @Test func aSocketRequestNamesItsPort() throws {
        let request = ControlRequest(command: .vsock, machine: "web", port: 22)
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"port\":22"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        // Requests from before ports existed have none.
        #expect(try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"command":"list"}"#.utf8)).port == nil)
    }

}
