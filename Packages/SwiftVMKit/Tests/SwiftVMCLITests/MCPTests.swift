import Foundation
import Testing
import VMControl
@testable import SwiftVMCLI

@Suite struct MCPTests {
    private func reply(_ server: MCP.Server, _ line: String) throws -> [String: Any] {
        let text = try #require(server.handle(line))
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func itTakesTheProtocolVersionItIsOfferedIfItKnowsIt() throws {
        let server = MCP.Server(client: ControlClient(socketURL: URL(fileURLWithPath: "/nonexistent/control.sock")))
        let answer = try reply(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(((result["capabilities"] as? [String: Any])?["tools"]) != nil)
        let later = try reply(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect((later["result"] as? [String: Any])?["protocolVersion"] as? String == MCP.protocolVersions[0])
    }

    @Test func aNotificationGetsNoAnswerAndWhatIsUnknownGetsAnError() throws {
        let server = MCP.Server(client: ControlClient(socketURL: URL(fileURLWithPath: "/nonexistent/control.sock")))
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try reply(server, #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)["error"] != nil)
    }

    @Test func everyToolSaysWhatItTakes() throws {
        let server = MCP.Server(client: ControlClient(socketURL: URL(fileURLWithPath: "/nonexistent/control.sock")))
        let answer = try reply(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        let tools = try #require((answer["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.contains { $0["name"] as? String == "vm_look" })
        for tool in tools {
            #expect((tool["description"] as? String)?.isEmpty == false)
            #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
    }

    @Test func aToolThatCantBeDoneIsAToolErrorAndNotAProtocolError() throws {
        let server = MCP.Server(client: ControlClient(socketURL: URL(fileURLWithPath: "/nonexistent/control.sock")))
        let answer = try reply(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"vm_look","arguments":{"machine":"desk"}}}"#)
        #expect(answer["error"] == nil)
        #expect((answer["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func aStepIsReadFromATools() throws {
        let step = try MCP.Tools.step(.click, ["target": 12, "count": 2, "button": "right"])
        #expect(step == ControlStep(.click, target: .number(12), button: .right, count: 2))
        #expect(try MCP.Tools.step(.click, ["target": [10, 20]]).target == .point(x: 10, y: 20))
        #expect(try MCP.Tools.step(.click, ["target": "Sign In"]).target == .text("Sign In"))
        #expect(try MCP.Tools.step(.open, ["what": "Safari"]).text == "Safari")
    }
}
