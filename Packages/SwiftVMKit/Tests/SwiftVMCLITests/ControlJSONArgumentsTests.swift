import Testing
@testable import SwiftVMCLI

@Suite struct ControlJSONArgumentsTests {
    @Test func trailingJSONLeavesTheCommandsOwnArguments() throws {
        for (command, arguments) in [
            ("list", [String]()), ("ls", []), ("start", ["Box"]),
            ("wait", ["Box", "--timeout", "2"]), ("network", ["Box", "shared"]),
        ] {
            let withJSON = arguments + ["--json"]
            #expect(ControlJSONArguments.isRequested(command: command, arguments: withJSON))
            #expect(try ControlJSONArguments.parse(command: command, arguments: withJSON) == arguments)
        }
    }

    @Test(arguments: [["Box", "--json", "--json"], ["--json", "Box"], ["Box", "--json=true"], ["Box", "--json", "extra"]])
    func duplicatesValuesAndMisplacedOptionsAreRefused(_ arguments: [String]) {
        #expect(ControlJSONArguments.isRequested(command: "start", arguments: arguments))
        #expect(throws: ControlJSONArguments.ParseError.self) { try ControlJSONArguments.parse(command: "start", arguments: arguments) }
    }

    @Test func unsupportedCommandsAndWrongArityAreRefused() {
        for (command, arguments) in [
            ("list", ["extra", "--json"]), ("info", ["--json"]), ("stop", ["Box", "extra", "--json"]),
            ("clone", ["Box", "--json"]), ("snapshot", ["Box", "--json=true"]),
        ] {
            #expect(throws: ControlJSONArguments.ParseError.self) { try ControlJSONArguments.parse(command: command, arguments: arguments) }
        }
    }

    @Test func guestPayloadAndOtherCommandsKeepTheirOwnOptions() throws {
        for (command, arguments) in [
            ("exec", ["Box", "--", "echo", "--json", "--json=true"]), ("cp", ["--json", "Box:/file"]),
            ("ssh", ["Box", "--", "--json"]), ("control", ["Box", "type", "--json", "x"]),
            ("create", ["macos", "--password", "--json"]),
        ] {
            #expect(!ControlJSONArguments.isRequested(command: command, arguments: arguments))
            #expect(try ControlJSONArguments.parse(command: command, arguments: arguments) == arguments)
        }
    }
}
