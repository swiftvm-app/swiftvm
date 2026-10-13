import AppKit
import ApplicationServices
import GuestChannel
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The desktop of the session the agent runs in: its screen, its mouse and its keyboard.
///
/// macOS asks whoever sits at the screen before a program may record it, and before one may use the
/// mouse and the keyboard or read what other programs show. Nothing in this system can say yes for
/// them. The app on the Mac can: it has the machine's own mouse and keyboard, and gives the answer in
/// System Settings as they would, while this half tells it where on the screen that is
/// (``permission(_:)``). Until then a job that takes it is answered with what to do.
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
            throw AgentFailure("macOS hasn't let the guest tools read what is on this Mac's screen yet, or act on it. `swiftvm allow-accessibility <machine> --password <password>`, on the Mac that runs this virtual machine, has it allowed. Or turn on swiftvm-agent in the guest, under System Settings › Privacy & Security › Device Control and Data Access, which earlier versions of macOS call Accessibility.")
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

    // MARK: Being let

    /// The system's settings, where its answer is given.
    private static let settingsIdentifier = "com.apple.systempreferences"
    /// The question the system puts on the screen by itself when it is asked.
    private static let questionIdentifier = "com.apple.accessibility.universalAccessAuthWarn"
    /// The page of the settings that lists who may read the screen and use the mouse and the keyboard.
    private static let settingsPage = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    /// The settings were opened by this half, and are its to close again.
    private static let hasOpenedSettings = Flag()

    func permission(_ request: GuestJob.Permission) throws -> Data {
        // The system's question leads to the settings and nowhere else, and lies over them.
        Self.dismissQuestion()
        switch request.action {
        case .check:
            break
        case .ask:
            try Self.ask()
        case .finish:
            Self.putAway()
        }
        return try JSONEncoder().encode(Self.permissionState())
    }

    private static func ask() throws {
        guard !AXIsProcessTrusted() else { return }
        // Asking is what puts this program on the settings' list.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        dismissQuestion(patience: 3)
        let wasOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: settingsIdentifier).isEmpty
        guard let page = URL(string: settingsPage), NSWorkspace.shared.open(page) else {
            throw AgentFailure("System Settings couldn't be opened in the guest.")
        }
        if !wasOpen {
            hasOpenedSettings.value = true
        }
        let deadline = Date().addingTimeInterval(20)
        while settingsWindows().isEmpty {
            guard Date() < deadline else { throw AgentFailure("System Settings didn't open in the guest.") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // A window is there before what is in it.
        Thread.sleep(forTimeInterval: 1.5)
    }

    private static func putAway() {
        guard hasOpenedSettings.value else { return }
        hasOpenedSettings.value = false
        let settings = NSRunningApplication.runningApplications(withBundleIdentifier: settingsIdentifier)
        settings.forEach { $0.terminate() }
        // It doesn't quit while it still has a question of its own in front of its window. Whether it
        // has gone is asked of the system: nothing here is told when a program ends.
        func isRunning(_ application: NSRunningApplication) -> Bool { kill(application.processIdentifier, 0) == 0 }
        let deadline = Date().addingTimeInterval(3)
        while settings.contains(where: isRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        settings.filter(isRunning).forEach { $0.forceTerminate() }
    }

    /// Takes the system's own question off the screen, waiting for it to come up for as long as `patience`.
    private static func dismissQuestion(patience: TimeInterval = 0) {
        let deadline = Date().addingTimeInterval(patience)
        while true {
            let questions = NSRunningApplication.runningApplications(withBundleIdentifier: questionIdentifier)
            questions.forEach { $0.forceTerminate() }
            guard questions.isEmpty, Date() < deadline else { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func permissionState() -> GuestPermissionState {
        let scale = (try? screen().scale) ?? 1
        var state = GuestPermissionState(isAllowed: AXIsProcessTrusted(), scale: scale)
        let windows = settingsWindows()
        func pixels(_ window: CGRect) -> [Int] {
            [window.minX, window.minY, window.width, window.height].map { Int(($0 * scale).rounded()) }
        }
        if let window = windows.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            state.settings = pixels(window)
            // What the settings put in front of their window is smaller, and comes before it.
            if let front = windows.first, front != window {
                state.sheet = pixels(front)
            }
        }
        return state
    }

    /// The windows of the system's settings that are on the screen, from the front to the back. Where
    /// windows are is no secret to a program that isn't let see what is in them.
    private static func settingsWindows() -> [CGRect] {
        let processes = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsIdentifier).map(\.processIdentifier))
        guard !processes.isEmpty else { return [] }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0, let process = window[kCGWindowOwnerPID as String] as? pid_t,
                  processes.contains(process), let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
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

/// Something that is so or isn't, for the jobs' threads to agree on.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        get { lock.withLock { isSet } }
        set { lock.withLock { isSet = newValue } }
    }
}

// MARK: - The keyboard

/// How the keys of a Mac's keyboard (``MacKeys``) are pressed in this session.
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

    static let returnKey: CGKeyCode = MacKeys.returnKey
    static let tabKey: CGKeyCode = MacKeys.tabKey

    private static func modifier(_ modifier: MacKeys.Modifier) -> Modifier {
        let flag: CGEventFlags = switch modifier {
        case .command: .maskCommand
        case .shift: .maskShift
        case .option: .maskAlternate
        case .control: .maskControl
        }
        return Modifier(key: modifier.key, flag: flag.rawValue)
    }

    /// Reads a press as it is written: `Return`, `cmd+space`, `ctrl+shift+t`.
    static func press(for text: String) throws -> Press {
        do {
            let press = try MacKeys.press(for: text)
            return Press(key: press.key, modifiers: press.modifiers.map(modifier))
        } catch let problem as MacKeys.NoSuchKey {
            throw AgentFailure(problem.message)
        }
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
