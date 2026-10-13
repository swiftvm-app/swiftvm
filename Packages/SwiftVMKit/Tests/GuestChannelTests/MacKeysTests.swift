import Foundation
import Testing
@testable import GuestChannel

@Suite struct MacKeysTests {
    @Test func typesWhatAUSKeyboardHasKeysFor() {
        #expect(MacKeys.press(typing: "a") == .init(key: 0, modifiers: []))
        // A capital letter, and the upper of a key's two signs, take Shift.
        #expect(MacKeys.press(typing: "A") == .init(key: 0, modifiers: [.shift]))
        #expect(MacKeys.press(typing: "?") == .init(key: 44, modifiers: [.shift]))
        #expect(MacKeys.press(typing: " ") == .init(key: 49, modifiers: []))
        #expect(MacKeys.press(typing: "\n") == .init(key: MacKeys.returnKey, modifiers: []))
        #expect(MacKeys.press(typing: "\t") == .init(key: MacKeys.tabKey, modifiers: []))
        // What no key has is somebody else's to type.
        #expect(MacKeys.press(typing: "ü") == nil)
        #expect(MacKeys.press(typing: "€") == nil)
    }

    @Test func readsAPressAsItIsWritten() throws {
        #expect(try MacKeys.press(for: "ctrl+shift+t") == .init(key: 17, modifiers: [.control, .shift]))
        #expect(try MacKeys.press(for: "cmd+?") == .init(key: 44, modifiers: [.command, .shift]))
        #expect(throws: MacKeys.NoSuchKey.self) { try MacKeys.press(for: "ctrl+banana") }
    }
}
