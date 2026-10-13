import CoreGraphics
import Testing
@testable import SwiftVM

@Suite struct GuestAccessTests {
    @Test func theSwitchIsAtTheEndOfTheLineThatNamesTheGuestTools() {
        // As a macOS 27 guest showed it, in the pixels of its screenshot: the window of System
        // Settings, and the line of its list that reads "swiftvm-agent".
        let window = CGRect(x: 774, y: 202, width: 1480, height: 1250)
        let line = CGRect(x: 1354, y: 494, width: 186, height: 26)
        let place = MacGuestTools.switchPlace(onLine: line, of: window, scale: 2)
        #expect(place.x == 2156)
        #expect(place.y == 507)
        // A screen that counts one pixel to the point has the switch half as far in.
        #expect(MacGuestTools.switchPlace(onLine: line, of: window, scale: 1).x == 2205)
    }

    @Test func aNameIsKnownByItsLettersHoweverItsDashWasRead() {
        #expect(ScreenText.letters(of: "swiftvm-agent") == "swiftvmagent")
        #expect(ScreenText.letters(of: "Swiftvm–Agent") == "swiftvmagent")
        #expect(ScreenText.letters(of: "⬛ swiftvm—agent ") == "swiftvmagent")
    }
}
