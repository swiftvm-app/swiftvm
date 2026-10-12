import AppKit
import ApplicationServices
import GuestChannel
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The desktop of the session the agent runs in: its screen, its mouse and its keyboard.
///
/// macOS asks whoever sits at the screen before a program may record it, and before one may use the
/// mouse and the keyboard or read what other programs show. Nothing can say yes for them. Until they
/// have, in System Settings, a job that takes it is answered with what to turn on, and macOS puts its
/// own question on the screen.
struct MacDesktop: AgentDesktop {
    init() {}

    // MARK: The screen

    /// The main display: how many pixels a screenshot of it has, and how many of them make one of the
    /// points that macOS itself counts places in.
    struct Screen {
        var display: CGDirectDisplayID
        var width: Int
        var height: Int
        var scale: Double
    }

    static func screen() throws -> Screen {
        let display = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0, mode.pixelWidth > 0 else {
            throw AgentFailure("This Mac has no display.")
        }
        return Screen(display: display, width: mode.pixelWidth, height: mode.pixelHeight, scale: Double(mode.pixelWidth) / Double(mode.width))
    }

    func screenshot() throws -> Data {
        let screen = try Self.screen()
        do {
            return try Self.waiting { try await Self.capture(screen) }
        } catch let failure as AgentFailure {
            throw failure
        } catch {
            guard CGPreflightScreenCaptureAccess() else {
                // Puts the system's own question on the screen, the first time.
                CGRequestScreenCaptureAccess()
                // A program that was running when it was allowed may not be let record until it has
                // started anew. launchd starts this half again at once.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exit(0) }
                throw AgentFailure("macOS hasn't let the guest tools record this Mac's screen yet. In the guest, turn on swiftvm-agent under System Settings › Privacy & Security › Screen & System Audio Recording, and try again in a moment.")
            }
            throw AgentFailure("The screen couldn't be recorded: \(error.localizedDescription)")
        }
    }

    private static func capture(_ screen: Screen) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.display }) ?? content.displays.first else {
            throw AgentFailure("This Mac has no display.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = screen.width
        configuration.height = screen.height
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration
        )
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentFailure("The picture of the screen couldn't be written down.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentFailure("The picture of the screen couldn't be written down.") }
        return data as Data
    }

    /// Runs what has to be waited for, from a thread that has the time.
    private static func waiting<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) throws -> Value {
        let outcome = Outcome<Value>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                outcome.result = .success(try await work())
            } catch {
                outcome.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        guard let result = outcome.result else { throw AgentFailure("The screen didn't answer.") }
        return try result.get()
    }

    // MARK: The mouse and the keyboard

    /// Using the mouse and the keyboard, and reading what programs show, is one permission to macOS.
    private static func requireAccess() throws {
        guard AXIsProcessTrusted() else {
            // Puts the system's own question on the screen, the first time.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            throw AgentFailure("macOS hasn't let the guest tools use this Mac's mouse and keyboard yet, or read what is on its screen. In the guest, turn on swiftvm-agent under System Settings › Privacy & Security › Accessibility, and try again.")
        }
    }

    private static let pause: TimeInterval = 0.06

    func pointer(_ request: GuestJob.Pointer) throws {
        try Self.requireAccess()
        let screen = try Self.screen()
        func place(_ x: Int, _ y: Int) throws -> CGPoint {
            guard (0..<screen.width).contains(x), (0..<screen.height).contains(y) else {
                throw AgentFailure("(\(x), \(y)) isn't on the screen, which is \(screen.width) by \(screen.height).")
            }
            return CGPoint(x: Double(x) / screen.scale, y: Double(y) / screen.scale)
        }
        let start = try place(request.x, request.y)
        let (down, up, dragged, button): (CGEventType, CGEventType, CGEventType, CGMouseButton) = switch request.button ?? .left {
        case .left: (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        }
        func post(_ kind: CGEventType, at place: CGPoint, click: Int = 0) {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: place, mouseButton: button) else { return }
            if click > 0 {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            }
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: Self.pause)
        }

        switch request.action {
        case .move:
            post(.mouseMoved, at: start)
        case .click:
            let count = request.count ?? 1
            guard (1...3).contains(count) else { throw AgentFailure("A click is one, two or three clicks.") }
            post(.mouseMoved, at: start)
            // The second click of a double click says that it is the second.
            for click in 1...count {
                post(down, at: start, click: click)
                post(up, at: start, click: click)
            }
        case .drag:
            guard let toX = request.toX, let toY = request.toY else { throw AgentFailure("The request doesn't say where the drag ends.") }
            let end = try place(toX, toY)
            post(.mouseMoved, at: start)
            post(down, at: start, click: 1)
            // Whatever is dragged follows a pointer that moves, not one that jumps.
            let steps = 12
            for step in 1...steps {
                let part = Double(step) / Double(steps)
                post(dragged, at: CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part))
            }
            post(up, at: end, click: 1)
        case .scroll:
            let (deltaX, deltaY) = (request.deltaX ?? 0, request.deltaY ?? 0)
            guard abs(deltaX) <= 100, abs(deltaY) <= 100 else { throw AgentFailure("That is further than the wheel is turned in one go.") }
            post(.mouseMoved, at: start)
            // A notch of a wheel is three lines. The wheel counts up for scrolling up, and to the left.
            let wheel = CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(-deltaY * 3), wheel2: Int32(-deltaX * 3), wheel3: 0
            )
            wheel?.post(tap: .cghidEventTap)
        }
    }

    func keys(_ request: GuestJob.Keys) throws {
        try Self.requireAccess()
        let text = request.text ?? ""
        // Everything is looked up before anything is typed: half of it is worse than none.
        let presses = try (request.keys ?? []).map(MacKeyboard.press(for:))
        guard !text.isEmpty || !presses.isEmpty else { throw AgentFailure("The request has neither text to type nor keys to press.") }
        for character in text {
            switch character {
            case "\n", "\r\n": MacKeyboard.tap(MacKeyboard.returnKey)
            case "\t": MacKeyboard.tap(MacKeyboard.tabKey)
            default: MacKeyboard.type(character)
            }
        }
        for press in presses {
            MacKeyboard.press(press)
        }
    }

    // MARK: What is on the screen, as a tree

    func tree(_ request: GuestJob.Tree) throws -> Data {
        try Self.requireAccess()
        var reader = ScreenReader(scale: try Self.screen().scale, everything: request.all == true)
        var applications: [ScreenPart] = []
        for (process, name) in Self.applications() {
            if let wanted = request.application, !name.localizedCaseInsensitiveContains(wanted) { continue }
            applications += reader.describe(application: process, named: name, depth: max(request.depth ?? ScreenReader.defaultDepth, 1))
        }
        return try JSONEncoder().encode(ScreenTree(applications: applications, truncated: reader.isTruncated))
    }

    func act(on request: GuestJob.Element) throws -> Data {
        try Self.requireAccess()
        return try JSONEncoder().encode(try ScreenReader.act(on: request))
    }

    /// The applications that have a window on the screen, the one in front first, and the Dock.
    private static func applications() -> [(process: pid_t, name: String)] {
        var found: [(process: pid_t, name: String)] = []
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Layer zero is where applications' own windows are. The menu bar's extras and the like are above.
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let process = window[kCGWindowOwnerPID as String] as? pid_t, !found.contains(where: { $0.process == process }) else { continue }
            found.append((process, window[kCGWindowOwnerName as String] as? String ?? ""))
        }
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            found.append((dock.processIdentifier, "Dock"))
        }
        return found
    }
}

/// What came of something that was waited for, handed from where it happened to where it is wanted.
private final class Outcome<Value: Sendable>: @unchecked Sendable {
    var result: Result<Value, any Error>?
}

// MARK: - The keyboard

/// The keys of a Mac's keyboard, by what is printed on them, and how they are pressed.
enum MacKeyboard {
    /// One press: a key, and the keys that are held down for it.
    struct Press: Equatable {
        var key: CGKeyCode?
        var modifiers: [Modifier]
    }

    struct Modifier: Equatable {
        var key: CGKeyCode
        var flag: UInt64
    }

    static let returnKey: CGKeyCode = 36
    static let tabKey: CGKeyCode = 48

    private static let command = Modifier(key: 55, flag: CGEventFlags.maskCommand.rawValue)
    private static let shift = Modifier(key: 56, flag: CGEventFlags.maskShift.rawValue)
    private static let option = Modifier(key: 58, flag: CGEventFlags.maskAlternate.rawValue)
    private static let control = Modifier(key: 59, flag: CGEventFlags.maskControl.rawValue)

    private static let modifiers: [String: Modifier] = [
        "cmd": command, "command": command, "super": command, "meta": command, "win": command,
        "shift": shift, "alt": option, "option": option, "ctrl": control, "control": control,
    ]

    private static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "escape": 53, "esc": 53, "tab": 48, "space": 49, "backspace": 51, "delete": 117, "del": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "up": 126, "down": 125, "left": 123, "right": 124,
        "capslock": 57, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Which key of a US keyboard has each character on it, and whether Shift is held for it.
    private static let characters: [Character: (key: CGKeyCode, shifted: Bool)] = {
        let plain: [(String, [CGKeyCode])] = [
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
        var keys: [Character: (key: CGKeyCode, shifted: Bool)] = [:]
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
    static func press(for text: String) throws -> Press {
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
                throw AgentFailure("“\(name.prefix(32))” isn't a key to hold down. Those are cmd, shift, option and ctrl.")
            } else if let key = named[lowered] {
                press.key = key
            } else if lowered.count == 1, let character = lowered.first, let key = characters[character] ?? characters[Character(name)] {
                // A letter in a shortcut is the key, whichever way it is written.
                press.key = key.key
                if characters[Character(name)]?.shifted == true, !press.modifiers.contains(shift) {
                    press.modifiers.append(shift)
                }
            } else {
                throw AgentFailure("There is no key called “\(name.prefix(32))”.")
            }
        }
        return press
    }

    static func press(_ press: Press) {
        // The keys to hold go down one after the other, each knowing of those before it, and come up
        // the other way round.
        var flags: UInt64 = 0
        for modifier in press.modifiers {
            flags |= modifier.flag
            post(modifier.key, isDown: true, flags: flags)
        }
        if let key = press.key {
            post(key, isDown: true, flags: flags)
            post(key, isDown: false, flags: flags)
        }
        for modifier in press.modifiers.reversed() {
            flags &= ~modifier.flag
            post(modifier.key, isDown: false, flags: flags)
        }
    }

    static func tap(_ key: CGKeyCode) {
        press(Press(key: key, modifiers: []))
    }

    /// Types one character as it is, whatever keyboard the system thinks it has.
    static func type(_ character: Character) {
        let units = Array(String(character).utf16)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else { continue }
            event.flags = []
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.006)
        }
    }

    private static func post(_ key: CGKeyCode, isDown: Bool, flags: UInt64) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: isDown) else { return }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
    }
}

// MARK: - The tree

/// What is on the screen, part by part, as it goes to the Mac.
struct ScreenTree: Encodable {
    var applications: [ScreenPart]
    /// There was more than is passed on.
    var truncated: Bool
}

/// One part of what is on the screen: an application, a window, a button.
struct ScreenPart: Encodable {
    /// What the part is asked for by: the application's process, and the way down from it.
    var id: String
    var role: String
    var name: String?
    var description: String?
    var value: Value?
    var states: [String]?
    var actions: [String]?
    /// Where it is on the screen, in the pixels of a screenshot: left, top, width, height.
    var bounds: [Int]?
    var children: [ScreenPart]?

    enum Value: Encodable {
        case text(String)
        case number(Double)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .number(let number): try container.encode(number)
            }
        }
    }

    /// Whether the part says anything of itself. Most of a tree is boxes that only hold other boxes.
    var isTelling: Bool {
        name != nil || description != nil || value != nil || actions != nil || states != nil
    }
}

/// Reads what is on the screen from the system's accessibility, which applications describe
/// themselves to for the benefit of screen readers.
struct ScreenReader {
    static let defaultDepth = 40
    static let nodeLimit = 3000
    static let childLimit = 500
    static let textLimit = 200
    /// How long an application gets to answer. One that hangs must not hold everything up.
    static let patience: Float = 2

    /// How many pixels make a point: the system counts places in points, a screenshot in pixels.
    var scale: Double
    /// Leave no box out, and none of a part's actions.
    var everything: Bool
    private(set) var isTruncated = false
    private var count = 0

    init(scale: Double, everything: Bool) {
        self.scale = scale
        self.everything = everything
    }

    /// What nearly every part can do, which says nothing about any one of them.
    private static let commonActions: Set<String> = ["showMenu", "scrollToVisible", "showDefaultUI", "showAlternateUI"]
    private static let attributes = [
        "AXRole", "AXTitle", "AXDescription", "AXValue", "AXEnabled", "AXFocused", "AXSelected", "AXExpanded", "AXPosition",
        "AXSize", "AXChildren",
    ]

    mutating func describe(application process: pid_t, named name: String, depth: Int) -> [ScreenPart] {
        let element = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(element, Self.patience)
        return describe(element, id: String(process), depth: depth, level: 0).compactMap { part in
            // One without a window has nothing to show.
            guard part.children != nil else { return nil }
            var part = part
            part.name = part.name ?? (name.isEmpty ? nil : name)
            return part
        }
    }

    /// What there is to show of `element`: the part itself with what is in it, or, for a box that says
    /// nothing of itself, only what is in it. An application is at level 0, its windows at 1.
    private mutating func describe(_ element: AXUIElement, id: String, depth: Int, level: Int) -> [ScreenPart] {
        guard count < Self.nodeLimit else {
            isTruncated = true
            return []
        }
        var fetched: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes as CFArray, [], &fetched) == .success,
              let values = fetched as? [Any], values.count == Self.attributes.count
        else { return [] }
        count += 1

        let role = (values[0] as? String) ?? "AXUnknown"
        var part = ScreenPart(id: id, role: Self.plain(role))
        let (title, description) = (Self.text(values[1]), Self.text(values[2]))
        part.name = title ?? description
        part.description = title == nil ? nil : description
        if let text = values[3] as? String {
            part.value = text.isEmpty || text == part.name ? nil : .text(String(text.prefix(Self.textLimit)))
        } else if let number = values[3] as? NSNumber {
            part.value = .number(number.doubleValue)
        }
        var states: [String] = []
        if values[4] as? Bool == false { states.append("disabled") }
        if values[5] as? Bool == true { states.append("focused") }
        if values[6] as? Bool == true { states.append("selected") }
        if values[7] as? Bool == true { states.append("expanded") }
        part.states = states.isEmpty ? nil : states
        let actions = Self.actions(of: element).map(Self.plain).filter { everything || !Self.commonActions.contains($0) }
        part.actions = actions.isEmpty ? nil : actions
        if let origin: CGPoint = Self.geometry(values[8], .cgPoint), let size: CGSize = Self.geometry(values[9], .cgSize), size.width > 0, size.height > 0 {
            part.bounds = [origin.x, origin.y, size.width, size.height].map { Int(($0 * scale).rounded()) }
        }

        var children: [ScreenPart] = []
        if depth > 0, let elements = values[10] as? [AXUIElement] {
            if elements.count > Self.childLimit {
                isTruncated = true
            }
            for (index, child) in elements.prefix(Self.childLimit).enumerated() {
                children += describe(child, id: "\(id)/\(index)", depth: depth - 1, level: level + 1)
            }
        }
        part.children = children.isEmpty ? nil : children
        return everything || level < 2 || part.isTelling ? [part] : children
    }

    // MARK: Acting on a part

    /// What was acted on, for whoever asked to see.
    struct Acted: Encodable {
        var id: String
        var role: String
        var name: String
    }

    static func act(on request: GuestJob.Element) throws -> Acted {
        let gone = AgentFailure("Nothing on the screen has the id “\(request.element.prefix(64))” any more. Read the tree again.")
        let steps = request.element.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = steps.first, let process = pid_t(first), process > 0 else { throw gone }
        var element = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(element, patience)
        for step in steps.dropFirst() {
            guard let index = Int(step), let children: [AXUIElement] = attribute("AXChildren", of: element), children.indices.contains(index) else {
                throw gone
            }
            element = children[index]
        }
        guard let role: String = attribute("AXRole", of: element) else { throw gone }
        let name = (attribute("AXTitle", of: element) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? attribute("AXDescription", of: element) ?? ""
        let what = "The \(plain(role)) “\(name.prefix(64))”"

        switch request.action {
        case .press:
            let names = actions(of: element)
            let chosen: String?
            if let wanted = request.actionName {
                // One of the part's actions, asked for by name, with the system's prefix or without.
                chosen = names.first { $0 == wanted || plain($0) == wanted }
            } else {
                chosen = names.first { $0 == "AXPress" } ?? names.first { $0 == "AXPick" } ?? (names.count == 1 ? names[0] : nil)
            }
            guard let chosen else {
                let missing = request.actionName.map { "has no action called “\($0.prefix(64))”" } ?? "has nothing to press"
                let has = names.isEmpty ? "It has no actions." : "Its actions: \(names.prefix(24).map(plain).joined(separator: ", "))."
                throw AgentFailure("\(what) \(missing). \(has)")
            }
            guard AXUIElementPerformAction(element, chosen as CFString) == .success else { throw AgentFailure("\(what) didn't take the press.") }
        case .set:
            guard let text = request.text else { throw AgentFailure("The request has no text.") }
            var isSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &isSettable) == .success, isSettable.boolValue else {
                throw AgentFailure("\(what) doesn't take text this way. If it is a text field, give it the keyboard with `swiftvm ui <machine> focus`, and type.")
            }
            guard AXUIElementSetAttributeValue(element, "AXValue" as CFString, text as CFString) == .success else {
                throw AgentFailure("\(what) didn't take the text.")
            }
        case .focus:
            guard AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue) == .success else {
                throw AgentFailure("\(what) can't be given the keyboard this way. Click on it instead.")
            }
        }
        return Acted(id: request.element, role: plain(role), name: name)
    }

    // MARK: Private

    private static func attribute<Value>(_ name: String, of element: AXUIElement) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// A name as the system has it, without the prefix that all of them share: `AXButton` is a `button`.
    private static func plain(_ name: String) -> String {
        guard name.hasPrefix("AX"), name.count > 2 else { return name }
        let rest = name.dropFirst(2)
        return rest.prefix(1).lowercased() + rest.dropFirst()
    }

    private static func text(_ value: Any) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return String(text.prefix(textLimit))
    }

    /// A place or a size, which the system wraps up in a type of its own.
    private static func geometry<Value>(_ value: Any, _ kind: AXValueType) -> Value? {
        let object = value as AnyObject
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let wrapped = unsafeDowncast(object, to: AXValue.self)
        guard AXValueGetType(wrapped) == kind else { return nil }
        let result = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { result.deallocate() }
        return AXValueGetValue(wrapped, kind, result) ? result.pointee : nil
    }
}
