import CoreGraphics
import Foundation
import Testing
@testable import SwiftVM

@Suite struct GuestAccessTests {
    @Test func theSwitchIsAtTheEndOfTheLineThatNamesTheGuestTools() throws {
        // As a macOS 27 guest showed it, in the pixels of its screenshot: the window of System
        // Settings, and the line of its list that reads "swiftvm-agent".
        let window = CGRect(x: 774, y: 202, width: 1480, height: 1250)
        let line = CGRect(x: 1354, y: 494, width: 186, height: 26)
        let place = try #require(MacGuestTools.switchPlace(onLine: line, of: window, scale: 2))
        #expect(place.x == 2156)
        #expect(place.y == 507)
        // A screen that counts one pixel to the point has the switch half as far in.
        #expect(MacGuestTools.switchPlace(onLine: line, of: window, scale: 1)?.x == 2205)
    }

    @Test(arguments: [0.0, -1.0, .nan, .infinity, 1e308])
    func aGuestsScaleCannotTrapOrPutTheSwitchOutsideItsWindow(scale: Double) {
        let window = CGRect(x: 100, y: 100, width: 700, height: 600)
        let line = CGRect(x: 200, y: 250, width: 100, height: 20)
        #expect(MacGuestTools.switchPlace(onLine: line, of: window, scale: scale) == nil)
    }

    @Test func aGuestsWindowCannotOverflowASwitchCoordinate() {
        let edge = Double(Int.max)
        let window = CGRect(x: edge, y: 100, width: 4096, height: 600)
        let line = CGRect(x: edge, y: 250, width: 2048, height: 20)
        #expect(MacGuestTools.switchPlace(onLine: line, of: window, scale: 2) == nil)
        #expect(MacGuestTools.switchPlace(onLine: line, of: .infinite, scale: 2) == nil)
        #expect(MacGuestTools.switchPlace(onLine: line, of: .zero, scale: 2) == nil)
    }

    @Test func onlyOneCompleteNameCanBeAllowed() {
        let name = MacGuestTools.listedName
        #expect(ScreenText.matchingLine(name, among: ["swiftvm-agent-helper", "not-swiftvm-agent"]) == nil)
        #expect(ScreenText.matchingLine(name, among: ["swiftvm-agent-helper", "Swiftvm–Agent"]) == 1)
        #expect(ScreenText.matchingLine(name, among: ["swiftvm-agent", "Swiftvm—Agent"]) == nil)
    }

    @Test func theGuestToolsAreAddedWithTheFirstListsAddButton() {
        // As a macOS 27.2 guest gave the tree of its Screen & System Audio Recording page: two lists,
        // each with an Add button, and a menu with an item named alike.
        let tree = Data("""
            {"applications":[{"id":"1302","role":"application","name":"System Settings","children":[
              {"id":"1302/0","role":"window","name":"Screen & System Audio Recording","children":[
                {"id":"1302/0/0/0/3/0/0/2/0/0/0/0/0","role":"staticText","value":"No Items"},
                {"id":"1302/0/0/0/3/0/0/2/1","role":"button","name":"Add","actions":["press"]},
                {"id":"1302/0/0/0/3/0/0/2/2","role":"button","name":"Remove","actions":["press"]},
                {"id":"1302/0/0/0/3/0/0/5/1","role":"button","name":"Add","actions":["press"]}]},
              {"id":"1302/1/1","role":"menuItem","name":"Add","actions":["press"]}]}],
             "truncated":false}
            """.utf8)
        #expect(MacGuestTools.addButton(inTree: tree) == "1302/0/0/0/3/0/0/2/1")
        #expect(MacGuestTools.addButton(inTree: Data(#"{"applications":[],"truncated":false}"#.utf8)) == nil)
        #expect(MacGuestTools.addButton(inTree: Data("not a tree".utf8)) == nil)
    }

    @Test func aNameIsKnownByItsLettersHoweverItsDashWasRead() {
        #expect(ScreenText.letters(of: "swiftvm-agent") == "swiftvmagent")
        #expect(ScreenText.letters(of: "Swiftvm–Agent") == "swiftvmagent")
        #expect(ScreenText.letters(of: "⬛ swiftvm—agent ") == "swiftvmagent")
    }
}
