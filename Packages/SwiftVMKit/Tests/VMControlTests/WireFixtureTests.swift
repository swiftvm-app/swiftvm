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
}
