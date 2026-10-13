import Foundation

/// The keys of a Mac's keyboard, by what is printed on them: what ``GuestJob/Keys`` names a key by, and
/// which key has which character on it.
///
/// Both ends of a macOS guest go by it. The agent in the guest makes key presses of them there, and the
/// app presses the keys of the machine's own keyboard.
public enum MacKeys {
    /// A key that is held down for another.
    public enum Modifier: Sendable, Hashable, CaseIterable {
        case command, shift, option, control

        /// The number of the key, the one on the left of the keyboard.
        public var key: UInt16 {
            switch self {
            case .command: 55
            case .shift: 56
            case .option: 58
            case .control: 59
            }
        }
    }

    /// One press: a key, and the keys that are held down for it.
    public struct Press: Sendable, Hashable {
        public var key: UInt16?
        public var modifiers: [Modifier]

        public init(key: UInt16?, modifiers: [Modifier]) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    /// What was asked for is no key, in words for whoever asked.
    public struct NoSuchKey: Error, Sendable, Equatable {
        public var message: String
    }

    public static let returnKey: UInt16 = 36
    public static let tabKey: UInt16 = 48

    private static let modifiers: [String: Modifier] = [
        "cmd": .command, "command": .command, "super": .command, "meta": .command, "win": .command,
        "shift": .shift, "alt": .option, "option": .option, "ctrl": .control, "control": .control,
    ]

    private static let named: [String: UInt16] = [
        "return": 36, "enter": 36, "escape": 53, "esc": 53, "tab": 48, "space": 49, "backspace": 51, "delete": 117, "del": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "up": 126, "down": 125, "left": 123, "right": 124,
        "capslock": 57, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Which key of a US keyboard has each character on it, and whether Shift is held for it.
    private static let characters: [Character: (key: UInt16, shifted: Bool)] = {
        let plain: [(String, [UInt16])] = [
            ("asdfhgzxcv", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
            ("bqweryt", [11, 12, 13, 14, 15, 16, 17]),
            ("123465=97-80]ou[ip", [18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35]),
            ("lj'k;\\,/nm.", [37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47]),
            ("`", [50]),
        ]
        let shifted: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+",
            "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
        ]
        var keys: [Character: (key: UInt16, shifted: Bool)] = [:]
        for (row, codes) in plain {
            for (character, code) in zip(row, codes) {
                keys[character] = (code, false)
                if let other = shifted[character] {
                    keys[other] = (code, true)
                }
            }
        }
        return keys
    }()

    /// Reads a press as it is written: `Return`, `cmd+space`, `ctrl+shift+t`.
    public static func press(for text: String) throws -> Press {
        var names = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // The plus sign is a key too: alone, or as the last of several.
        if text == "+" {
            names = ["+"]
        } else if names.count > 2, names.suffix(2) == ["", ""] {
            names = names.dropLast(2) + ["+"]
        }
        var press = Press(key: nil, modifiers: [])
        for (position, name) in names.enumerated() {
            let lowered = name.lowercased()
            if let modifier = modifiers[lowered] {
                if !press.modifiers.contains(modifier) {
                    press.modifiers.append(modifier)
                }
            } else if position < names.count - 1 {
                throw NoSuchKey(message: "“\(name.prefix(32))” isn't a key to hold down. Those are cmd, shift, option and ctrl.")
            } else if let key = named[lowered] {
                press.key = key
            } else if lowered.count == 1, let character = lowered.first, let key = characters[character] ?? characters[Character(name)] {
                // A letter in a shortcut is the key, whichever way it is written.
                press.key = key.key
                if characters[Character(name)]?.shifted == true, !press.modifiers.contains(.shift) {
                    press.modifiers.append(.shift)
                }
            } else {
                throw NoSuchKey(message: "There is no key called “\(name.prefix(32))”.")
            }
        }
        return press
    }

    /// The press that types `character` on a US keyboard: its key, with Shift for a capital letter or
    /// the upper of a key's two signs. `nil` for a character that no key has.
    public static func press(typing character: Character) -> Press? {
        switch character {
        case "\n", "\r\n": return Press(key: returnKey, modifiers: [])
        case "\t": return Press(key: tabKey, modifiers: [])
        case " ": return Press(key: 49, modifiers: [])
        default: break
        }
        if let key = characters[character] {
            return Press(key: key.key, modifiers: key.shifted ? [.shift] : [])
        }
        // A capital letter is its key with Shift.
        let lowered = character.lowercased()
        guard character.isLetter, lowered.count == 1, lowered != String(character), let key = characters[Character(lowered)] else { return nil }
        return Press(key: key.key, modifiers: [.shift])
    }
}
