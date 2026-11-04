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
