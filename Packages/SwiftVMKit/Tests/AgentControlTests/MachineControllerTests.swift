import CoreGraphics
import Foundation
import GuestChannel
import Testing
import VMControl
import VMCore
@testable import AgentControl

/// A machine with a screen of the given size and what its guest tools say is on it.
@MainActor
private final class FakeMachine: ControlledMachine {
    var controlName = "desk"
    var systemName: String? = "Test OS"
    var guestFamily = GuestFamily.linux
    var width = 2560
    var height = 1600
    var tree: String?
    var isDisplayOff = false
    var pointers: [GuestPointer] = []
    var keys: [GuestJob.Keys] = []
    var acted: [GuestJob.Element] = []
    var ran: [[String]] = []
    /// What each frame's pixels are, so that a test can have the screen change.
    var pixel: UInt8 = 0
    var changesEveryFrame = false
    var treeReads = 0

    /// A picture to show instead of one colour.
    var picture: ScreenFrame?
    /// Keeps a key from waking the display, as a guest that is restarting.
    var staysOff = false

    func frame() async throws -> ScreenFrame {
        if isDisplayOff { throw MachineDeskError.nothingShown }
        if let picture { return picture }
        if changesEveryFrame { pixel &+= 1 }
        return ScreenFrame(width: width, height: height, bytesPerRow: width * 4, pixels: Data(repeating: pixel, count: width * height * 4))
    }

    func pointer(_ request: GuestPointer) async throws {
        pointers.append(request)
    }

    func press(_ keys: GuestJob.Keys) async throws {
        self.keys.append(keys)
        if keys.keys == ["shift"], !staysOff { isDisplayOff = false }
    }

    func screenTree(_ request: GuestJob.Tree) async throws -> Data {
        treeReads += 1
        guard let tree else { throw GuestJobError.noAgent(name: controlName) }
        return Data(tree.utf8)
    }

    func act(on element: GuestJob.Element) async throws {
        acted.append(element)
    }

    func runInSession(_ arguments: [String], input: Data?) async throws -> Data {
        ran.append(arguments)
        return Data()
    }
}

/// Three rows of a list that each say the same, as a list of files with a Delete button in each.
private func rows(at places: [Int]) -> String {
    let parts = places.enumerated().map { #"{"id":"1/\#($0.offset)","role":"button","name":"Delete","bounds":[100,\#($0.element),80,40]}"# }.joined(separator: ",")
    return #"{"applications":[{"id":"1","role":"application","name":"Files","states":["active"],"children":[\#(parts)]}]}"#
}

/// An editor in front, with a closed menu, a hidden helper button, and what only a Dock would say.
private let editor = #"""
{"applications":[
 {"id":"1","role":"application","name":"Editor","states":["active"],"children":[
  {"id":"1/0","role":"window","name":"Notes","bounds":[100,100,1000,800],"children":[
   {"id":"1/0/0","role":"button","name":"Save","actions":["press"],"bounds":[120,120,100,40]},
   {"id":"1/0/1","role":"button","name":"Save","actions":["press"],"bounds":[240,120,100,40]},
   {"id":"1/0/2","role":"button","name":"Actions for Save","actions":["press"],"bounds":[120,120,2,2]},
   {"id":"1/0/3","role":"textField","value":"draft","states":["focused"],"bounds":[120,200,800,400]},
   {"id":"1/0/4","role":"group","bounds":[120,700,800,40],"children":[
    {"id":"1/0/4/0","role":"staticText","name":"Ready","bounds":[130,705,60,20]}]},
   {"id":"1/0/5","role":"scrollBar","bounds":[1090,100,10,800],"children":[
    {"id":"1/0/5/0","role":"button","name":"Up","bounds":[1090,100,10,10]}]}]},
  {"id":"1/1","role":"menuBar","bounds":[0,0,2560,60],"children":[
   {"id":"1/1/0","role":"menuBarItem","name":"File","bounds":[20,0,60,60],"children":[
    {"id":"1/1/0/0","role":"menu","children":[
     {"id":"1/1/0/0/0","role":"menuItem","name":"Open"}]}]}]}]},
 {"id":"2","role":"application","name":"Dock","children":[
  {"id":"2/0","role":"list","bounds":[0,1500,2560,100],"children":[
   {"id":"2/0/0","role":"dockItem","name":"Trash","bounds":[2400,1500,100,100]}]}]}
],"truncated":false}
"""#

@MainActor
@Suite struct MachineControllerTests {
    private func look(_ controller: MachineController, _ step: ControlStep = ControlStep(.look)) async throws -> ControlLook {
        let outcome = await controller.perform(ControlCall(steps: [step]))
        return try #require(outcome.results.first?.look, "\(outcome.text)")
    }

    private func number(of name: String, in look: ControlLook) throws -> Int {
        try #require(look.elements.first { $0.name == name }?.number)
    }

    @Test func aLookIsAShortListOfWhatIsInFrontInOneSpace() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let found = try await look(MachineController(machine: machine))
        #expect(found.width == 1280 && found.height == 800 && found.scale == 2)
        #expect(found.applications == ["Editor", "Dock"])
        #expect(found.front == "Editor")
        let names = found.elements.compactMap(\.name)
        // Neither a closed menu's items, a button too small to be one, nor a scroll bar's parts, nor the Dock.
        #expect(names == ["Notes", "Save", "Save", "Ready", "File"])
        #expect(found.elements.contains { $0.role == "textfield" && $0.value == "draft" && $0.states == ["focused"] && $0.frame == [60, 100, 400, 200] })
    }

    @Test func aClickOnANumberGoesToTheMiddleOfItOnTheDisplay() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let target = try await look(controller).elements.first { $0.role == "textfield" }
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(try #require(target?.number)))]))
        #expect(outcome.failure == nil)
        #expect(machine.pointers.map(\.x) == [520])
        #expect(machine.pointers.map(\.y) == [400])
    }

    @Test func aPlaceIsInTheSameSpaceAsTheList() async throws {
        let machine = FakeMachine()
        let controller = MachineController(machine: machine)
        _ = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .point(x: 100, y: 50))]))
        #expect(machine.pointers.first?.x == 201)
        #expect(machine.pointers.first?.y == 101)
        let outside = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .point(x: 5000, y: 50))]))
        #expect(outside.failure != nil)
        #expect(machine.pointers.count == 1)
    }

    @Test func anElementThatHasGoneIsAnErrorAndNotAClickSomewhereElse() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let target = try number(of: "Ready", in: try await look(controller))
        _ = await controller.perform(ControlCall(steps: [ControlStep(.key, keys: ["Return"])]))
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"Editor","states":["active"],"children":[{"id":"1/0","role":"window","name":"Notes","bounds":[100,100,1000,800]}]}]}"#
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(target))]))
        #expect(outcome.failure?.error?.contains("isn't on the screen any more") == true)
        #expect(machine.pointers.isEmpty)
    }

    @Test func anElementThatMovedIsClickedWhereItIsNow() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let target = try number(of: "Ready", in: try await look(controller))
        _ = await controller.perform(ControlCall(steps: [ControlStep(.key, keys: ["Return"])]))
        machine.tree = editor.replacingOccurrences(of: "[130,705,60,20]", with: "[530,805,60,20]")
        _ = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(target))]))
        #expect(machine.pointers.first?.x == 560)
        #expect(machine.pointers.first?.y == 815)
    }

    @Test func textThatSeveralThingsSayIsLeftToWhoeverAsked() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let ambiguous = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .text("save"))]))
        #expect(ambiguous.failure?.error?.contains("Several things say") == true)
        #expect(machine.pointers.isEmpty)
        let unique = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .text("ready"))]))
        #expect(unique.failure == nil)
        #expect(machine.pointers.count == 1)
    }

    @Test func numbersStayFromLookToLookAndChangesSayOnlyWhatChanged() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let first = try await look(controller)
        let again = try await look(controller, ControlStep(.look, changes: true))
        #expect(again.elements.isEmpty && again.removed == [])
        #expect(again.text.contains("no changes"))

        machine.tree = editor.replacingOccurrences(of: "\"draft\"", with: "\"draft 2\"").replacingOccurrences(of: "\"Ready\"", with: "\"Saved\"")
        let changed = try await look(controller, ControlStep(.look, changes: true))
        let field = try #require(first.elements.first { $0.role == "textfield" })
        #expect(changed.changed == [field.number])
        #expect(changed.elements.first { $0.number == field.number }?.value == "draft 2")
        #expect(changed.elements.contains { $0.name == "Saved" })
        #expect(changed.removed?.map(\.name) == ["Ready"])
    }

    @Test func setTypesAsAPersonDoesWhereThatIsPossible() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let field = try #require(try await look(controller).elements.first { $0.role == "textfield" })
        _ = await controller.perform(ControlCall(steps: [ControlStep(.set, target: .number(field.number), text: "new")]))
        #expect(machine.pointers.count == 1)
        #expect(machine.keys == [.init(keys: ["ctrl+a"]), .init(text: "new")])
        #expect(machine.acted.isEmpty)
        // What the machine's keyboard has no keys for is left to the guest tools.
        _ = await controller.perform(ControlCall(steps: [ControlStep(.set, target: .number(field.number), text: "grüße")]))
        #expect(machine.acted.map(\.text) == ["grüße"])
    }

    @Test func aBoxAndTheFieldInsideItAreOneThingToWhoeverNamesThem() async throws {
        let machine = FakeMachine()
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"Notepad","states":["active"],"children":[{"id":"a","role":"ComboBox","name":"File name:","bounds":[0,0,500,40],"children":[{"id":"b","role":"Edit","name":"File name:","bounds":[2,2,400,36]}]}]}]}"#
        let controller = MachineController(machine: machine)
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .text("File name:"))]))
        #expect(outcome.failure == nil)
        #expect(machine.pointers.first?.x == 202)
    }

    @Test func whatIsToldTwiceIsListedOnce() async throws {
        let machine = FakeMachine()
        // As Windows tells a dialog: by itself, and in the window it belongs to.
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"Notepad","states":["active"],"children":[{"id":"a","role":"window","name":"Notepad","bounds":[0,0,900,900],"children":[{"id":"b","role":"Button","name":"Save","bounds":[10,10,90,30]}]},{"id":"c","role":"window","name":"Save as","bounds":[50,50,400,400],"children":[{"id":"d","role":"Button","name":"Save","bounds":[10,10,90,30]}]}]}]}"#
        let controller = MachineController(machine: machine)
        let found = try await look(controller)
        #expect(found.elements.filter { $0.name == "Save" }.count == 1)
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .text("save"))]))
        #expect(outcome.failure == nil)
    }

    @Test func aPartWithoutAPlaceIsPressedByTheGuestTools() async throws {
        let machine = FakeMachine()
        // As Wayland has it: an application isn't told where it is.
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"Editor","states":["active"],"children":[{"id":"1/0","role":"frame","name":"Notes","children":[{"id":"1/0/0","role":"push button","name":"Open"}]}]}]}"#
        let controller = MachineController(machine: machine)
        let target = try number(of: "Open", in: try await look(controller))
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(target))]))
        #expect(outcome.failure == nil)
        #expect(machine.pointers.isEmpty)
        #expect(machine.acted == [.init(action: .press, element: "1/0/0")])
    }

    @Test func aDisplayThatIsOffIsWokenWithAKey() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        machine.isDisplayOff = true
        let found = try await look(MachineController(machine: machine))
        #expect(machine.keys.first?.keys == ["shift"])
        #expect(!found.elements.isEmpty)
    }

    @Test func withoutGuestToolsALookSaysSoInsteadOfFailing() async throws {
        let machine = FakeMachine()
        let found = try await look(MachineController(machine: machine))
        #expect(found.notes?.first?.contains("pixels only") == true)
    }

    @Test func aFailedStepEndsTheCallAndAWaitThatRanOutSaysSo() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let outcome = await controller.perform(ControlCall(steps: [
            ControlStep(.wait, text: "Never shown", timeout: 0.2), ControlStep(.key, keys: ["Return"]),
        ]))
        #expect(outcome.results.count == 1)
        #expect(outcome.failure?.timedOut == true)
        #expect(ControlExit.status(of: outcome) == ControlExit.timedOut)
        #expect(machine.keys.isEmpty)
    }

    @Test func waitFindsTextAsSoonAsItIsThere() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.wait, text: "ready", timeout: 5)]))
        #expect(outcome.failure == nil)
    }

    @Test func theGuestIsNotAskedWhatIsOnAScreenThatIsMoving() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        machine.width = 64
        machine.height = 64
        machine.changesEveryFrame = true
        let outcome = await MachineController(machine: machine).perform(ControlCall(steps: [ControlStep(.wait, text: "ready", timeout: 0.5)]))
        #expect(outcome.failure?.timedOut == true)
        #expect(machine.treeReads == 0)
    }

    @Test func aScreenThatNeverSettlesIsNoFailure() async throws {
        let machine = FakeMachine()
        machine.width = 64
        machine.height = 64
        machine.changesEveryFrame = true
        let outcome = await MachineController(machine: machine).perform(ControlCall(steps: [ControlStep(.wait, timeout: 0.3), ControlStep(.key, keys: ["Return"])]))
        #expect(outcome.failure == nil)
        #expect(machine.keys.count == 1)
    }

    @Test func absurdPlacesFromAGuestDontBringTheAppDown() async throws {
        let machine = FakeMachine()
        machine.width = 1280
        machine.height = 800
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"A","states":["active"],"children":[{"id":"1/0","role":"button","name":"Big","bounds":[0,0,9223372036854775807,9223372036854775807]},{"id":"1/1","role":"button","name":"Fine","bounds":[1,1,50,50]}]}]}"#
        let found = try await look(MachineController(machine: machine))
        #expect(found.elements.contains { $0.name == "Fine" })
        #expect(found.elements.first { $0.name == "Big" }?.frame == nil)
    }

    @Test func aGuestsNamesCantForgeLinesOrReachTheTerminalRaw() async throws {
        let machine = FakeMachine()
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"App\u001b]52;c;x\u0007\n[1] button \"Fake\"","states":["active"],"children":[{"id":"1/0","role":"button","name":"OK","bounds":[1,1,50,50]}]}]}"#
        let text = try await look(MachineController(machine: machine)).text
        #expect(!text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        #expect(text.split(separator: "\n").filter { $0.hasPrefix("[1]") }.count == 1)
    }

    /// What reads pixels here, which doesn't depend on what this Mac can do: a machine without a neural
    /// engine, such as a virtual one, may read nothing at all.
    private func reader(_ said: @escaping @Sendable () throws -> String) -> @Sendable (CGImage) async throws -> [ScreenText.Line] {
        { _ in [ScreenText.Line(text: try said(), frame: CGRect(x: 10, y: 10, width: 200, height: 40))] }
    }

    private final class Words: @unchecked Sendable {
        var text = ""
    }

    private struct CantRead: Error {}

    @Test func goneIsOnlySaidOfWhatThePixelsNoLongerShow() async throws {
        let machine = FakeMachine()
        machine.width = 64
        machine.height = 64
        machine.tree = #"{"applications":[]}"#
        let words = Words()
        words.text = "Loading"
        let controller = MachineController(machine: machine, readText: reader { words.text })
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.wait, gone: "Loading", timeout: 1)]))
        #expect(outcome.failure?.timedOut == true)
        // And when they have stopped showing it, it is said.
        words.text = "Finished"
        let later = await controller.perform(ControlCall(steps: [ControlStep(.wait, gone: "Loading", timeout: 3)]))
        #expect(later.failure == nil)
    }

    @Test func pixelsThatCantBeReadAreNoProofThatSomethingHasGone() async throws {
        let machine = FakeMachine()
        machine.width = 64
        machine.height = 64
        let controller = MachineController(machine: machine, readText: reader { throw CantRead() })
        // No guest tools either: nothing can be told.
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.wait, gone: "Loading", timeout: 1)]))
        #expect(outcome.failure?.timedOut == true)
        // The guest tools alone can tell.
        machine.tree = #"{"applications":[]}"#
        let told = await controller.perform(ControlCall(steps: [ControlStep(.wait, gone: "Loading", timeout: 3)]))
        #expect(told.failure == nil)
    }

    @Test func aLookSaysSoWhenThePixelsCantBeRead() async throws {
        let machine = FakeMachine()
        machine.width = 64
        machine.height = 64
        let found = try await look(MachineController(machine: machine, readText: reader { throw CantRead() }))
        #expect(found.notes?.contains { $0.contains("couldn't be read on this Mac") } == true)
    }

    @Test func goneIsOnlySaidOfWhatTheGuestToolsNoLongerTell() async throws {
        let machine = FakeMachine()
        machine.width = 1280
        machine.height = 800
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let waiting = Task { await controller.perform(ControlCall(steps: [ControlStep(.wait, gone: "Ready", timeout: 1.5)])) }
        // A pixel or two changing makes both be read again, one after the other.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(200))
            machine.pixel &+= 1
        }
        #expect(await waiting.value.failure?.timedOut == true)
    }

    @Test func aRowTakenFromAListIsNeverAClickOnTheRowThatMovedUp() async throws {
        let machine = FakeMachine()
        machine.width = 1280
        machine.height = 800
        machine.tree = rows(at: [100, 200, 300])
        let controller = MachineController(machine: machine)
        let numbers = try await look(controller).elements.map(\.number)
        #expect(numbers.count == 3)
        machine.tree = rows(at: [100, 200])
        for number in numbers {
            let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(number))]))
            #expect(outcome.failure?.error?.contains("Look again") == true)
        }
        #expect(machine.pointers.isEmpty)
    }

    @Test func rowsThatAreStillWhereTheyWereCanBeClickedByNumber() async throws {
        let machine = FakeMachine()
        machine.width = 1280
        machine.height = 800
        machine.tree = rows(at: [100, 200, 300])
        let controller = MachineController(machine: machine)
        let numbers = try await look(controller).elements.map(\.number)
        _ = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(numbers[1]))]))
        #expect(machine.pointers.first?.y == 220)
    }

    @Test func aRowsButtonIsKnownByTheRowItIsIn() async throws {
        let machine = FakeMachine()
        machine.width = 1280
        machine.height = 800
        func row(_ name: String, _ y: Int) -> String {
            #"{"id":"\#(name)","role":"row","name":"\#(name)","bounds":[0,\#(y),600,40],"children":[{"id":"\#(name)/0","role":"button","name":"Delete","bounds":[500,\#(y),80,40]}]}"#
        }
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"Files","states":["active"],"children":[\#(row("a.txt", 100)),\#(row("b.txt", 200))]}]}"#
        let controller = MachineController(machine: machine)
        let found = try await look(controller)
        let second = try #require(found.elements.filter { $0.name == "Delete" }.last?.number)
        machine.tree = #"{"applications":[{"id":"1","role":"application","name":"Files","states":["active"],"children":[\#(row("b.txt", 100))]}]}"#
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(second))]))
        #expect(outcome.failure == nil)
        // b.txt's own button, where it has moved to.
        #expect(machine.pointers.first?.y == 120)
    }

    @Test func whatChangedByItselfSinceTheLookIsNoticed() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let target = try number(of: "Ready", in: try await look(controller))
        // No action of this controller's: something in the guest did it.
        machine.tree = editor.replacingOccurrences(of: "\"Ready\"", with: "\"Format Disk\"")
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(target))]))
        #expect(outcome.failure != nil)
        #expect(machine.pointers.isEmpty)
    }

    @Test func aNumberThatCantBeCheckedIsNotClicked() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let target = try number(of: "Ready", in: try await look(controller))
        machine.tree = nil
        let outcome = await controller.perform(ControlCall(steps: [ControlStep(.click, target: .number(target))]))
        #expect(outcome.failure?.error?.contains("can't be told") == true)
        #expect(machine.pointers.isEmpty)
    }

    @Test func aWaitLastsThroughADisplayThatStaysOff() async throws {
        let machine = FakeMachine()
        machine.isDisplayOff = true
        machine.staysOff = true
        let start = ContinuousClock.now
        let outcome = await MachineController(machine: machine).perform(ControlCall(steps: [ControlStep(.wait, text: "Login", timeout: 5)]))
        #expect(outcome.failure?.timedOut == true)
        #expect(ContinuousClock.now - start >= .seconds(5))
        #expect(machine.keys.count == 1)
    }

    @Test func aCallThatIsCalledOffHoldsNothingUp() async throws {
        let machine = FakeMachine()
        machine.width = 64
        machine.height = 64
        machine.tree = editor
        let controller = MachineController(machine: machine)
        let waiting = Task {
            await controller.perform(ControlCall(steps: [ControlStep(.wait, text: "Never", timeout: 60), ControlStep(.key, keys: ["Return"])]))
        }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        _ = await waiting.value
        #expect(machine.keys.isEmpty)
        let start = ContinuousClock.now
        _ = await controller.perform(ControlCall(steps: [ControlStep(.key, keys: ["Escape"])]))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(machine.keys.map(\.keys) == [["Escape"]])
    }

    @Test func aPictureIsInTheSpaceOfTheList() async throws {
        let machine = FakeMachine()
        machine.tree = editor
        let outcome = await MachineController(machine: machine).perform(ControlCall(steps: [ControlStep(.look, image: true)]))
        let data = try #require(outcome.results.first?.image)
        let frame = try #require(ScreenFrame(png: data))
        #expect(frame.width == 1280 && frame.height == 800)
    }

    @Test func aRetinaDisplayCountsInItsPointsAndLargeOnesFitWhatAModelIsShown() {
        #expect(MachineController.scale(width: 1280, height: 800) == 1)
        #expect(MachineController.scale(width: 2560, height: 1600) == 2)
        #expect(MachineController.scale(width: 3840, height: 2160) == 3)
        let exact = MachineController.scale(width: 1920, height: 1200)
        #expect(Double(1920) / exact <= 1568.5)
    }
}

@Suite struct GuestCommandsTests {
    @Test func windowsIsNotToTakeAURLForSeveralCommands() {
        #expect(GuestCommands.windowsWord("https://x/?a=1&b=2") == "https://x/?a=1^&b=2")
        #expect(GuestCommands.windowsWord("notepad") == "notepad")
        // With a space it is quoted on its way, where nothing of this is special.
        #expect(GuestCommands.windowsWord("C:\\a b\\c&d.txt") == "C:\\a b\\c&d.txt")
    }
}

@Suite struct ScreenTextMergeTests {
    private func line(_ text: String, _ x: Double, _ y: Double) -> ScreenText.Line {
        ScreenText.Line(text: text, frame: CGRect(x: x, y: y, width: 50, height: 10))
    }

    @Test func whatOnlyThePixelsKnowIsAddedAndWhatIsKnownIsNot() {
        let known = DeskEntry(application: "A", role: "button", name: "Save", frame: CGRect(x: 0, y: 0, width: 100, height: 100), elementID: "1")
        let merged = DeskOCR.merged([line("Save", 10, 10), line("Sign In", 300, 300)], into: [known])
        #expect(merged.map(\.role) == ["button", "ocr"])
        #expect(merged[1].name == "Sign In")
    }

    @Test func whatHasNoPlaceGetsTheOneThePixelsShow() {
        let placeless = DeskEntry(application: "A", role: "button", name: "Open", elementID: "1")
        let merged = DeskOCR.merged([line("Open", 10, 20)], into: [placeless])
        #expect(merged.count == 1)
        #expect(merged[0].frame?.minX == 10)
        #expect(merged[0].elementID == "1")
    }
}
