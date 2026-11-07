import Testing
import VMControl
@testable import SwiftVMCLI

@Suite struct ControlArgumentsTests {
    @Test func stepsJoinedWithThenBecomeOneCall() throws {
        let request = try Control.parse(["click", "12", "--right", "--then", "type", "hello", "world", "--then", "key", "cmd+s", "Return", "--then", "look", "--changes"])
        #expect(request.call.steps == [
            ControlStep(.click, target: .number(12), button: .right),
            ControlStep(.type, text: "hello world"),
            ControlStep(.key, keys: ["cmd+s", "Return"]),
            ControlStep(.look, changes: true),
        ])
    }

    @Test func aTargetIsANumberAPlaceOrAText() throws {
        #expect(try Control.parse(["click", "[7]"]).call.steps[0].target == .number(7))
        #expect(try Control.parse(["click", "640", "400"]).call.steps[0].target == .point(x: 640, y: 400))
        #expect(try Control.parse(["click", "Sign In"]).call.steps[0].target == .text("Sign In"))
        let drag = try Control.parse(["drag", "10", "20", "--to", "Trash"]).call.steps[0]
        #expect(drag.target == .point(x: 10, y: 20))
        #expect(drag.to == .text("Trash"))
    }

    @Test func identifiersWorkWhereverATargetDoes() throws {
        for action in ["click", "move", "focus"] {
            #expect(try Control.parse([action, "#Save"]).call.steps[0].target == .id("Save"))
        }
        let drag = try Control.parse(["drag", "#source", "--to", "#destination"]).call.steps[0]
        #expect(drag.target == .id("source") && drag.to == .id("destination"))
        #expect(try Control.parse(["click", "#row", "--right"]).call.steps[0] == ControlStep(.click, target: .id("row"), button: .right))
        #expect(try Control.parse(["scroll", "#list", "down"]).call.steps[0].target == .id("list"))
        #expect(try Control.parse(["set", "#search", "100"]).call.steps[0] == ControlStep(.set, target: .id("search"), text: "100"))
        #expect(try Control.parse(["click", "#12"]).call.steps[0].target == .id("12"))
        #expect(throws: Control.ParseError.self) { try Control.parse(["click", "#"]) }
    }

    @Test func identifierWaitsTakeOneConditionAndPreserveTheId() throws {
        #expect(try Control.parse(["wait", "--id", "Save", "--timeout", "2"]).call.steps[0] == ControlStep(.wait, timeout: 2, id: "Save"))
        #expect(try Control.parse(["wait", "--id-gone", "Save"]).call.steps[0] == ControlStep(.wait, idGone: "Save"))
        for first in ["--text", "--gone", "--id", "--id-gone"] {
            for second in ["--text", "--gone", "--id", "--id-gone"] where first != second {
                #expect(throws: Control.ParseError.self) { try Control.parse(["wait", first, "a", second, "b"]) }
            }
        }
        for option in ["--id", "--id-gone"] {
            #expect(throws: Control.ParseError.self) { try Control.parse(["wait", option]) }
            #expect(throws: Control.ParseError.self) { try Control.parse(["wait", option, ""]) }
        }
    }

    @Test func setTakesOneWordForWhatAndAllTheRestIsTheText() throws {
        #expect(try Control.parse(["set", "5", "100"]).call.steps[0] == ControlStep(.set, target: .number(5), text: "100"))
        #expect(try Control.parse(["set", "Search", "two", "words"]).call.steps[0] == ControlStep(.set, target: .text("Search"), text: "two words"))
        // Emptying a field is said out loud, and forgetting the text isn't taken for that.
        #expect(try Control.parse(["set", "5", ""]).call.steps[0] == ControlStep(.set, target: .number(5), text: ""))
        #expect(throws: Control.ParseError.self) { try Control.parse(["set", "5"]) }
    }

    @Test func jsonIsAskedForAtTheVeryEndAndAnywhereElseIsText() throws {
        #expect(try Control.parse(["look", "--json"]).printsJSON)
        let typed = try Control.parse(["type", "--json", "x"])
        #expect(!typed.printsJSON)
        #expect(typed.call.steps[0].text == "--json x")
    }

    @Test func scrollTakesATargetOrNot() throws {
        #expect(try Control.parse(["scroll", "down", "5"]).call.steps[0] == ControlStep(.scroll, direction: .down, amount: 5))
        #expect(try Control.parse(["scroll", "9", "up"]).call.steps[0] == ControlStep(.scroll, target: .number(9), direction: .up))
    }

    @Test func aLooksImageGoesWhereItIsToldOrSomewhereOfItsOwn() throws {
        let saved = try Control.parse(["look", "--image=/tmp/s.jpg", "--then", "screenshot", "-"])
        #expect(saved.call.steps[0].image == true)
        #expect(saved.imageFiles == [0: "/tmp/s.jpg", 1: "-"])
        let region = try Control.parse(["look", "--region", "1", "2", "3", "4"]).call.steps[0]
        #expect(region.region == [1, 2, 3, 4])
        #expect(region.image == true)
    }

    @Test func whatMakesNoSenseIsSaidAndNothingIsDone() {
        for arguments in [["clack", "1"], ["click"], ["look", "extra"], ["click", "1", "--then"], ["scroll", "12"], ["wait", "--text", "a", "--gone", "b"], ["drag", "1"]] {
            #expect(throws: Control.ParseError.self) { try Control.parse(arguments) }
        }
    }
}
