import Foundation
import Testing
@testable import VMControl

@Suite struct ControlSocketTests {
    @Test func requestsRoundTripThroughServer() async throws {
        // Unix socket paths are limited to ~100 bytes, so keep the test path short.
        let socketURL = URL(fileURLWithPath: "/tmp/swiftvm-test-\(UInt32.random(in: 0...UInt32.max)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = try ControlServer(socketURL: socketURL) { request in
            guard request.command == .start, let machine = request.machine else {
                return .failure("unexpected request")
            }
            return ControlResponse(ok: true, machines: [
                MachineSummary(
                    id: UUID(), name: machine, state: "running", system: "Linux", address: "192.168.230.10",
                    sshAlias: "web", cpuCount: 2, memorySize: 4 << 30, diskAllocated: 0, diskCapacity: 64 << 30
                ),
            ])
        }
        defer { server.invalidate() }

        let client = ControlClient(socketURL: socketURL)
        let response = try await Task.detached { try client.send(ControlRequest(command: .start, machine: "Web Server")) }.value
        #expect(response.ok)
        #expect(response.machines.first?.name == "Web Server")
        #expect(response.machines.first?.address == "192.168.230.10")

        let failure = try await Task.detached { try client.send(ControlRequest(command: .list)) }.value
        #expect(!failure.ok)
        #expect(failure.error == "unexpected request")
    }

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

    @Test func theConsoleAndSocketRequestsOpenAStream() {
        #expect(ControlRequest.Command.allCases.filter(\.opensStream) == [.console, .vsock])
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

    @Test func aSocketRequestNamesItsPort() throws {
        let request = ControlRequest(command: .vsock, machine: "web", port: 22)
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("\"port\":22"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        // Requests from before ports existed have none.
        #expect(try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"command":"list"}"#.utf8)).port == nil)
    }

    @Test func aStreamRequestTurnsTheConnectionIntoAPipe() async throws {
        let socketURL = URL(fileURLWithPath: "/tmp/swiftvm-test-\(UInt32.random(in: 0...UInt32.max)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = try ControlServer(
            socketURL: socketURL,
            handler: { request in
                request.machine == "known" ? ControlResponse(ok: true) : .failure("No virtual machine named “\(request.machine ?? "")”.")
            },
            streamHandler: { request in
                guard request.machine == "known" else {
                    return (.failure("No virtual machine named “\(request.machine ?? "")”."), nil)
                }
                // What a stream needs is set up before the answer, and a failure to do so is the answer.
                guard request.command == .console else {
                    return (.failure("Nothing answers on port \(request.port ?? 0)."), nil)
                }
                return (ControlResponse(ok: true), { connection in
                    // Answers everything in upper case until the client hangs up.
                    var buffer = [UInt8](repeating: 0, count: 256)
                    while true {
                        let count = read(connection, &buffer, buffer.count)
                        guard count > 0 else { return }
                        let reply = Array(String(decoding: buffer[0..<count], as: UTF8.self).uppercased().utf8)
                        _ = write(connection, reply, reply.count)
                    }
                })
            }
        )
        defer { server.invalidate() }
        let client = ControlClient(socketURL: socketURL)

        let reply = try await Task.detached { () -> String in
            let (response, descriptor) = try client.openStream(ControlRequest(command: .console, machine: "known"))
            #expect(response.ok)
            let stream = try #require(descriptor)
            defer { close(stream) }
            var received = ""
            for word in ["hello", "console"] {
                _ = write(stream, word, word.utf8.count)
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = read(stream, &buffer, buffer.count)
                received += String(decoding: buffer[0..<max(count, 0)], as: UTF8.self) + " "
            }
            return received
        }.value
        #expect(reply == "HELLO CONSOLE ")

        // A refusal leaves nothing open, and says why.
        let refused = try await Task.detached { try client.openStream(ControlRequest(command: .console, machine: "missing")) }.value
        #expect(refused.descriptor == nil)
        #expect(refused.response.error == "No virtual machine named “missing”.")
        let unanswered = try await Task.detached { try client.openStream(ControlRequest(command: .vsock, machine: "known", port: 22)) }.value
        #expect(unanswered.descriptor == nil)
        #expect(unanswered.response.error == "Nothing answers on port 22.")

        // An ordinary request to the same server is still a question and an answer.
        let ordinary = try await Task.detached { try client.send(ControlRequest(command: .list, machine: "known")) }.value
        #expect(ordinary.ok)
    }

    @Test func aServerThatLeavesDoesNotTakeItsSuccessorsSocketAlong() async throws {
        let socketURL = URL(fileURLWithPath: "/tmp/swiftvm-test-\(UInt32.random(in: 0...UInt32.max)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }
        // The app is quit and opened again at once: the new copy listens before the old one is gone.
        var old: ControlServer? = try ControlServer(socketURL: socketURL) { _ in .failure("the old copy") }
        let new = try ControlServer(socketURL: socketURL) { _ in ControlResponse(ok: true) }
        old?.invalidate()
        old = nil

        let client = ControlClient(socketURL: socketURL)
        #expect(try await Task.detached { try client.send(ControlRequest(command: .list)) }.value.ok)

        // Its own socket it does remove, so that the tool can tell the app is gone.
        new.invalidate()
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
        new.invalidate()
    }

    @Test func aServerWithoutStreamsRefusesThem() async throws {
        let socketURL = URL(fileURLWithPath: "/tmp/swiftvm-test-\(UInt32.random(in: 0...UInt32.max)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }
        let server = try ControlServer(socketURL: socketURL) { _ in ControlResponse(ok: true) }
        defer { server.invalidate() }
        let client = ControlClient(socketURL: socketURL)
        let refused = try await Task.detached { try client.openStream(ControlRequest(command: .console, machine: "known")) }.value
        #expect(refused.descriptor == nil)
        #expect(refused.response.ok == false)
    }
}

@Suite struct ByteRelayTests {
    private static func socketPair() -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func readToEnd(_ descriptor: Int32) -> [UInt8] {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer[0..<count])
            } else if count == 0 || errno != EINTR {
                return received
            }
        }
    }

    /// A client and a service, each with a socket of its own, and the relay holding the two inner ends.
    private struct Line {
        let client: Int32
        let service: Int32
        let relay: Task<Void, Never>

        init() {
            let (client, clientSide) = ByteRelayTests.socketPair()
            let (serviceSide, service) = ByteRelayTests.socketPair()
            self.client = client
            self.service = service
            relay = Task.detached {
                await ByteRelay.run(between: clientSide, and: serviceSide)
                close(clientSide)
                close(serviceSide)
            }
        }
    }

    @Test func carriesAConversationBothWaysAndPassesOnItsEnd() async {
        let line = Line()
        defer {
            close(line.client)
            close(line.service)
        }
        // More than fits in any buffer on the way, so that both directions have to keep moving.
        let request = (0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let answer = (0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 17) }

        let service = Task.detached { () -> [UInt8] in
            // The service hears the client out to the end of what it says, and only then answers: the
            // end of one direction must not take the other one with it.
            let received = Self.readToEnd(line.service)
            _ = ByteRelay.writeAll(answer[...], to: line.service)
            shutdown(line.service, SHUT_WR)
            return received
        }
        let client = Task.detached { () -> [UInt8] in
            _ = ByteRelay.writeAll(request[...], to: line.client)
            shutdown(line.client, SHUT_WR)
            return Self.readToEnd(line.client)
        }
        #expect(await service.value == request)
        #expect(await client.value == answer)
        await line.relay.value
    }

    @Test func endsWhenBothSidesHaveGone() async {
        let line = Line()
        _ = ByteRelay.writeAll(Array("hello".utf8)[...], to: line.client)
        // The client is gone altogether, not just done talking.
        close(line.client)
        #expect(await Task.detached { Self.readToEnd(line.service) }.value == Array("hello".utf8))
        // The service has nobody left to talk to and hangs up as well, which ends the relay.
        close(line.service)
        await line.relay.value
    }

    @Test func aBrokenSideTakesTheOtherDirectionWithIt() async {
        let line = Line()
        defer { close(line.client) }
        // The service goes away with a megabyte of the client's words still on their way to it: they
        // can't be delivered any more, and the client's side must not be left waiting for an answer.
        close(line.service)
        _ = ByteRelay.writeAll([UInt8](repeating: 7, count: 1 << 20)[...], to: line.client)
        #expect(await Task.detached { Self.readToEnd(line.client) }.value.isEmpty)
        await line.relay.value
    }

    @Test func copiesUntilTheEndAndSaysSo() {
        let (source, sourceWriter) = Self.socketPair()
        let (destinationReader, destination) = Self.socketPair()
        defer { [source, destinationReader, destination] .forEach { close($0) } }
        _ = ByteRelay.writeAll(Array("one two".utf8)[...], to: sourceWriter)
        close(sourceWriter)
        #expect(ByteRelay.copy(from: source, to: destination))
        // The destination was told that nothing more is coming.
        #expect(Self.readToEnd(destinationReader) == Array("one two".utf8))
    }

    @Test func copyingToSomethingThatIsNotASocketWorksToo() throws {
        let (source, sourceWriter) = Self.socketPair()
        defer { close(source) }
        let pipe = Pipe()
        _ = ByteRelay.writeAll(Array("to a pipe".utf8)[...], to: sourceWriter)
        close(sourceWriter)
        #expect(ByteRelay.copy(from: source, to: pipe.fileHandleForWriting.fileDescriptor))
        try pipe.fileHandleForWriting.close()
        #expect(Self.readToEnd(pipe.fileHandleForReading.fileDescriptor) == Array("to a pipe".utf8))
    }

    @Test func reportsADestinationThatHasGone() {
        let (source, sourceWriter) = Self.socketPair()
        let (destinationReader, destination) = Self.socketPair()
        defer { [source, sourceWriter, destination].forEach { close($0) } }
        close(destinationReader)
        _ = ByteRelay.writeAll(Array("into the void".utf8)[...], to: sourceWriter)
        #expect(ByteRelay.copy(from: source, to: destination) == false)
    }
}
