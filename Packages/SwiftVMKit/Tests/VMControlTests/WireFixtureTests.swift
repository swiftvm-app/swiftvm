import Foundation
import Testing
import VMControl

/// The control socket's messages as the `swiftvm` tool, which is written in Rust, sends and reads them.
/// The fixtures are shared with crates/swiftvm-protocol/tests/wire.rs: a message that both sides take
/// back unchanged is one they agree on.
@Suite struct WireFixtureTests {
    /// Tests/VMControlTests, Tests, SwiftVMKit, Packages, and then the repository.
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "crates/swiftvm-protocol/tests/fixtures")

    private func expectRoundTrip<Message: Codable>(_ type: Message.Type, in file: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appending(path: file))
        let fixture = try JSONSerialization.jsonObject(with: data)
        for message in (fixture as? [Any]) ?? [fixture] {
            let sent = try JSONSerialization.data(withJSONObject: message)
            let decoded = try JSONDecoder().decode(Message.self, from: sent)
            let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
            #expect((message as AnyObject).isEqual(again), "\(String(decoding: sent, as: UTF8.self))")
        }
    }

    @Test func requestsFromTheToolAreReadAsSent() throws {
        try expectRoundTrip(ControlRequest.self, in: "requests.json")
    }

    @Test func responsesReachTheToolAsWritten() throws {
        try expectRoundTrip(ControlResponse.self, in: "responses.json")
    }

    @Test func outcomesReachTheToolAsWritten() throws {
        try expectRoundTrip(ControlOutcome.self, in: "outcome.json")
    }

    @Test func eventsReachTheServiceAsWritten() throws {
        try expectRoundTrip(ControlEvent.self, in: "events.json")
    }

    /// What the app says to `swiftvm serve` itself, in API v1.
    @Test func theServicesHelloAndClientsAreReadAsItWritesThem() throws {
        let data = try Data(contentsOf: Self.fixtures.appending(path: "api-v1/hello.json"))
        let hello = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        let request = try JSONDecoder().decode(ServiceRequest.self, from: JSONSerialization.data(withJSONObject: hello[0]))
        #expect(request == ServiceRequest(id: 0, command: "hello", protocol: 1, client: "swiftvm 0.1.0"))
        for answer in hello.dropFirst() {
            let sent = try JSONSerialization.data(withJSONObject: answer)
            let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONDecoder().decode(ServiceAnswer.self, from: sent)))
            #expect((answer as AnyObject).isEqual(again), "\(String(decoding: sent, as: UTF8.self))")
        }
        let answers = try Data(contentsOf: Self.fixtures.appending(path: "api-v1/answers.json"))
        let clients = try #require((try JSONSerialization.jsonObject(with: answers) as? [Any])?.last)
        let decoded = try JSONDecoder().decode(ServiceAnswer.self, from: JSONSerialization.data(withJSONObject: clients))
        #expect(decoded.clients?.map(\.name) == ["Notes Robot", "notes-robot"])
        #expect(decoded.clients?.last?.allowed == false)
    }

    /// The engine requests the app sends `swiftvm serve` for its QEMU machines, and what it reads back.
    @Test func theEngineRequestsAreWrittenAndItsAnswersReadAsTheServiceHasThem() throws {
        let data = try Data(contentsOf: Self.fixtures.appending(path: "api-v1/qemu.json"))
        let fixture = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for request in try #require(fixture["requests"] as? [Any]) {
            let sent = try JSONSerialization.data(withJSONObject: request)
            let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONDecoder().decode(QEMURequest.self, from: sent)))
            #expect((request as AnyObject).isEqual(again), "\(String(decoding: sent, as: UTF8.self))")
        }
        let answers = try (fixture["answers"] as? [Any] ?? []).map {
            try JSONDecoder().decode(QEMUAnswer.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        #expect(answers[0].qemu?.adapter == .virtioGPU3D && answers[0].qemu?.pid == 4242)
        #expect(answers[1].qemuMachines?.first?.canSaveState == true)
        #expect(answers[2].exit?.reason == "guest-reset")
        #expect(answers[3].frame?.bytesPerRow == 7680)
        #expect(answers[4].error?.code == "guest-tools")
        let events = try (fixture["events"] as? [Any] ?? []).map {
            try JSONDecoder().decode(QEMUEvent.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        #expect(events.map { $0.exit?.reason } == ["guest-shutdown", nil])
        #expect(events[1].exit?.message == "Could not open 'disk.img'")
    }
}
