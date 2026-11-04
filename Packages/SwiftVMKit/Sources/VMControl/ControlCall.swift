import Foundation

/// What `swiftvm control` and `swiftvm mcp` ask of a machine's desktop: one or more steps, done in order
/// by the app, which stops at the first that fails.
public struct ControlCall: Codable, Sendable, Equatable {
    public var steps: [ControlStep]

    public init(steps: [ControlStep]) {
        self.steps = steps
    }
}

/// What a step acts on: a number from the last look, what something on the screen says, or a place.
public enum ControlTarget: Codable, Sendable, Equatable {
    case number(Int)
    case text(String)
    case point(x: Int, y: Int)
}

public struct ControlStep: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        case look, click, move, drag, scroll, type, key, set, focus, wait, screenshot, open, clipboard
    }

    public enum Button: String, Codable, Sendable, CaseIterable {
        case left, right, middle
    }

    public enum Direction: String, Codable, Sendable, CaseIterable {
        case up, down, left, right
    }

    public var action: Action
    /// What to click, move to, scroll over, set or focus. For a drag, where it starts.
    public var target: ControlTarget?
    /// Where a drag ends.
    public var to: ControlTarget?
    /// What to type, what to set, what to open, what to put on the clipboard, or what to wait for.
    public var text: String?
    /// What to wait to go away.
    public var gone: String?
    public var keys: [String]?
    public var button: Button?
    public var count: Int?
    public var direction: Direction?
    /// Notches of the wheel.
    public var amount: Int?
    /// Seconds to wait.
    public var timeout: Double?
    /// A look also brings a picture of the screen, in which places are what the look says they are.
    public var image: Bool?
    /// Left, top, width and height of the part of the screen to show in the picture.
    public var region: [Int]?
    /// A look says what is in every application, not only the one in front.
    public var all: Bool?
    /// A look says what is in the application with this in its name.
    public var application: String?
    /// A look also reads the screen's pixels, for what the desktop's accessibility doesn't tell.
    public var ocr: Bool?
    /// A look says only what changed since the last one.
    public var changes: Bool?

    public init(
        _ action: Action, target: ControlTarget? = nil, to: ControlTarget? = nil, text: String? = nil, gone: String? = nil,
        keys: [String]? = nil, button: Button? = nil, count: Int? = nil, direction: Direction? = nil, amount: Int? = nil,
        timeout: Double? = nil, image: Bool? = nil, region: [Int]? = nil, all: Bool? = nil, application: String? = nil,
        ocr: Bool? = nil, changes: Bool? = nil
    ) {
        self.action = action
        self.target = target
        self.to = to
        self.text = text
        self.gone = gone
        self.keys = keys
        self.button = button
        self.count = count
        self.direction = direction
        self.amount = amount
        self.timeout = timeout
        self.image = image
        self.region = region
        self.all = all
        self.application = application
        self.ocr = ocr
        self.changes = changes
    }
}

/// How a call went. A step that failed is the last one.
public struct ControlOutcome: Codable, Sendable, Equatable {
    public var results: [ControlStepResult]

    public init(results: [ControlStepResult] = []) {
        self.results = results
    }

    /// The step that failed, if one did.
    public var failure: ControlStepResult? {
        results.first { $0.error != nil }
    }

    /// Everything said, the way a person or a model reads it.
    public var text: String {
        results.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public struct ControlStepResult: Codable, Sendable, Equatable {
    public var action: ControlStep.Action
    /// Why it didn't work.
    public var error: String?
    /// A wait that ran out of time, rather than a step that failed some other way.
    public var timedOut: Bool?
    /// What the step has to say for itself: how it was done, or what was asked for.
    public var note: String?
    public var look: ControlLook?
    /// What was asked to be shown: a JPEG for a look, a PNG for a screenshot.
    public var image: Data?
    public var milliseconds: Int?

    public init(
        action: ControlStep.Action, error: String? = nil, timedOut: Bool? = nil, note: String? = nil, look: ControlLook? = nil,
        image: Data? = nil, milliseconds: Int? = nil
    ) {
        self.action = action
        self.error = error
        self.timedOut = timedOut
        self.note = note
        self.look = look
        self.image = image
        self.milliseconds = milliseconds
    }

    public var text: String {
        var lines: [String] = []
        if let error { lines.append("\(action.rawValue) failed: \(error)") }
        if let note { lines.append(note) }
        if let look { lines.append(look.text) }
        return lines.joined(separator: "\n")
    }
}

/// What is on a machine's screen. Everything in it counts in one space: the screen's `width` and
/// `height`, which are also the pixels of the picture a look brings and what a click takes.
public struct ControlLook: Codable, Sendable, Equatable {
    public var machine: String
    public var system: String?
    public var width: Int
    public var height: Int
    /// How many of the display's own pixels make one of these. A Retina display has 2.
    public var scale: Double
    /// The how-manieth look at this machine.
    public var sequence: Int
    /// The applications on the screen, the one in front first.
    public var applications: [String]
    /// The application `elements` are of, if they are of one.
    public var front: String?
    public var elements: [ControlElement]
    /// Only set for a look that asked for what changed: what the last look had and this one hasn't.
    public var removed: [ControlElement]?
    /// Numbers of elements in `elements` that the last look had in another state.
    public var changed: [Int]?
    /// Elements that were left out to keep this short.
    public var omitted: Int?
    /// What is unusual about this look, such as why accessibility wasn't available.
    public var notes: [String]?

    public init(
        machine: String, system: String? = nil, width: Int, height: Int, scale: Double = 1, sequence: Int = 1, applications: [String] = [],
        front: String? = nil, elements: [ControlElement] = [], removed: [ControlElement]? = nil, changed: [Int]? = nil, omitted: Int? = nil,
        notes: [String]? = nil
    ) {
        self.machine = machine
        self.system = system
        self.width = width
        self.height = height
        self.scale = scale
        self.sequence = sequence
        self.applications = applications
        self.front = front
        self.elements = elements
        self.removed = removed
        self.changed = changed
        self.omitted = omitted
        self.notes = notes
    }

    /// One line about the screen, one about its applications, and one for each element, indented as
    /// they are held by each other.
    public var text: String {
        var lines = ["\(machine)\(system.map { " · \($0)" } ?? "") · screen \(width)x\(height)\(scale > 1 ? " (\(scale == scale.rounded() ? String(Int(scale)) : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), scale))x)" : "") · look \(sequence)"]
        if !applications.isEmpty {
            lines.append("apps: " + applications.enumerated().map { $0.element == front ? "\($0.element)*" : $0.element }.joined(separator: ", "))
        }
        lines += (notes ?? []).map { "note: \($0)" }
        if let removed {
            let changedNumbers = Set(changed ?? [])
            lines += elements.map { (changedNumbers.contains($0.number) ? "~ " : "+ ") + $0.line(indented: false) }
            lines += removed.map { "- " + $0.line(indented: false) }
            if elements.isEmpty, removed.isEmpty { lines.append("no changes") }
        } else {
            lines += elements.map { $0.line(indented: true) }
            if elements.isEmpty { lines.append("nothing to read: add --image to see the screen") }
        }
        if let omitted, omitted > 0 { lines.append("… \(omitted) more: narrow it with --app, or see them with --all") }
        return lines.joined(separator: "\n")
    }
}

public struct ControlElement: Codable, Sendable, Equatable {
    /// What a step calls it by. It stays with the element from look to look.
    public var number: Int
    /// `button`, `textfield`, `text`, `link`, and the like, the same on every system. `ocr` for what was
    /// read off the screen's pixels and isn't known to be anything but text.
    public var role: String
    public var name: String?
    public var value: String?
    /// `focused`, `selected`, `checked`, `disabled`, `expanded`.
    public var states: [String]?
    /// Left, top, width and height. Some Wayland applications aren't told where they are, and have none.
    public var frame: [Int]?
    public var depth: Int

    public init(number: Int, role: String, name: String? = nil, value: String? = nil, states: [String]? = nil, frame: [Int]? = nil, depth: Int = 0) {
        self.number = number
        self.role = role
        self.name = name
        self.value = value
        self.states = states
        self.frame = frame
        self.depth = depth
    }

    public func line(indented: Bool) -> String {
        var line = (indented ? String(repeating: " ", count: min(depth, 8)) : "") + "[\(number)] \(role)"
        if let name, !name.isEmpty { line += " \"\(name)\"" }
        if let value, !value.isEmpty { line += " =\"\(value)\"" }
        if let states, !states.isEmpty { line += " " + states.joined(separator: " ") }
        if let frame, frame.count == 4 { line += " \(frame[0]),\(frame[1]) \(frame[2])x\(frame[3])" }
        return line
    }
}

/// What the tool exits with: the same whether a call came from a script or from an agent.
public enum ControlExit {
    public static let failed: Int32 = 1
    public static let timedOut: Int32 = 124
    public static let couldNotRun: Int32 = 125

    public static func status(of outcome: ControlOutcome) -> Int32 {
        guard let failure = outcome.failure else { return 0 }
        return failure.timedOut == true ? timedOut : failed
    }
}

/// Carries a call's outcome to the tool as JSON in ``JobFrame``s, which may be megabytes for a screenshot.
public enum ControlOutcomeCoding {
    public static func data(for outcome: ControlOutcome) -> Data {
        (try? JSONEncoder().encode(outcome)) ?? Data("{\"results\":[]}".utf8)
    }

    public static func outcome(from data: Data) -> ControlOutcome? {
        try? JSONDecoder().decode(ControlOutcome.self, from: data)
    }
}
