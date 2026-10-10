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
    }
}
