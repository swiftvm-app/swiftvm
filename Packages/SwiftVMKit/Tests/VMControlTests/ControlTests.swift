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

    @Test func onlyTheConsoleRequestOpensAStream() {
        #expect(ControlRequest.Command.allCases.filter(\.opensStream) == [.console])
    }

    @Test func aStreamRequestTurnsTheConnectionIntoAPipe() async throws {
        let socketURL = URL(fileURLWithPath: "/tmp/swiftvm-test-\(UInt32.random(in: 0...UInt32.max)).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = try ControlServer(
            socketURL: socketURL,
            handler: { request in
                request.machine == "known" ? ControlResponse(ok: true) : .failure("No virtual machine named “\(request.machine ?? "")”.")
            },
            streamHandler: { _, connection in
                // Answers everything in upper case until the client hangs up.
                var buffer = [UInt8](repeating: 0, count: 256)
                while true {
                    let count = read(connection, &buffer, buffer.count)
                    guard count > 0 else { return }
                    let reply = Array(String(decoding: buffer[0..<count], as: UTF8.self).uppercased().utf8)
                    _ = write(connection, reply, reply.count)
                }
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

        // An ordinary request to the same server is still a question and an answer.
        let ordinary = try await Task.detached { try client.send(ControlRequest(command: .list, machine: "known")) }.value
        #expect(ordinary.ok)
    }
}
