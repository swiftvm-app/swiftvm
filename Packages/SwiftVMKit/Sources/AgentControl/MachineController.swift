import CoreGraphics
import Foundation
import GuestChannel
import VMControl
import VMCore

/// What a ``MachineController`` needs of a machine. The screen, the mouse and the keyboard are the
/// machine's own and always there. What the guest tools add may not be.
@MainActor
public protocol ControlledMachine: AnyObject {
    var controlName: String { get }
    var systemName: String? { get }
    var guestFamily: GuestFamily { get }
    func frame() async throws -> ScreenFrame
    func pointer(_ request: GuestPointer) async throws
    func press(_ keys: GuestJob.Keys) async throws
    /// What is on the screen as a tree of its parts, in JSON. Fails where the guest tools can't tell.
    func screenTree(_ request: GuestJob.Tree) async throws -> Data
    func act(on element: GuestJob.Element) async throws
    /// Runs a command as whoever is logged in at the screen, and returns what it printed.
    func runInSession(_ arguments: [String], input: Data?) async throws -> Data
}

extension VirtualMachine: ControlledMachine {
    public var controlName: String { name }
    /// The guest's word for it, which goes to a terminal.
    public var systemName: String? { agent.hello?.system.displayName.map { ShownText.line($0, limit: 80) } }
    public var guestFamily: GuestFamily { configuration.os.family }

    public func screenTree(_ request: GuestJob.Tree) async throws -> Data {
        try await collect(.tree(request), patience: 20)
    }

    public func act(on element: GuestJob.Element) async throws {
        _ = try await collect(.element(element), patience: 20)
    }

    public func runInSession(_ arguments: [String], input: Data?) async throws -> Data {
        try await collect(.exec(.init(arguments: arguments)), input: input, patience: 20)
    }
}

/// Why a step couldn't be done, in words for whoever asked.
struct ControlFailure: Error {
    var message: String
    var timedOut = false

    init(_ message: String, timedOut: Bool = false) {
        self.message = message
        self.timedOut = timedOut
    }
}

/// Does what `swiftvm control` and `swiftvm mcp` ask of one machine's desktop.
///
/// It reads the screen itself and uses the machine's own mouse and keyboard, so all of it works on any
/// guest and at a login screen. It asks the guest tools what the screen's parts are where they can tell,
/// and reads the pixels where they can't: to whoever asks, it is one numbered list either way.
@MainActor
public final class MachineController {
    private let machine: any ControlledMachine
    /// What reads text off a picture.
    private let readText: @Sendable (CGImage) async throws -> [ScreenText.Line]
    private var numbering = DeskNumbering()
    /// What the last look showed, by number.
    private var table: [Int: DeskEntry] = [:]
    private var lastShown: [Int: DeskEntry] = [:]
    private var sequence = 0
    /// When the mouse or the keyboard was last used. What they did takes a moment to show.
    private var lastAction: ContinuousClock.Instant?
    /// Calls wait for each other: two at once would press each other's keys and renumber each other's list.
    private var turn = Task<Void, Never> {}
    private let clock = ContinuousClock()

    /// The longest side of what a model is shown, beyond which it would be made smaller anyway, and what
    /// it sees would no longer be where it clicks.
    private static let longestSide = 1568.0
    private static let longestList = 150
    private static let longestWait = 600.0
    /// A screen that didn't change for this long is taken to have settled.
    private static let quiet: Duration = .milliseconds(120)
    private static let settlePatience: Duration = .seconds(1)
    /// As many of the pixels compared as may change on a screen that is at rest: a caret, a clock.
    private static let restlessPixels = 40

    public init(
        machine: any ControlledMachine,
        readText: @escaping @Sendable (CGImage) async throws -> [ScreenText.Line] = { try await ScreenText.lines(in: $0) }
    ) {
        self.machine = machine
        self.readText = readText
    }

    /// Does the steps in order, and stops at the first that fails. Calling it off, as when whoever asked
    /// has gone, keeps what is left from happening, and from holding up the next call.
    public func perform(_ call: ControlCall) async -> ControlOutcome {
        let before = turn
        let mine = Task<ControlOutcome, Never> { @MainActor [self] in
            await before.value
            var outcome = ControlOutcome()
            for step in call.steps {
                if Task.isCancelled { break }
                let result = await perform(step)
                outcome.results.append(result)
                if result.error != nil { break }
            }
            return outcome
        }
        turn = Task { _ = await mine.value }
        return await withTaskCancellationHandler { await mine.value } onCancel: { mine.cancel() }
    }

    private func perform(_ step: ControlStep) async -> ControlStepResult {
        let start = clock.now
        var result: ControlStepResult
        do {
            result = try await carryOut(step)
        } catch let failure as ControlFailure {
            result = ControlStepResult(action: step.action, error: failure.message, timedOut: failure.timedOut ? true : nil)
        } catch {
            result = ControlStepResult(action: step.action, error: error.localizedDescription)
        }
        let elapsed = clock.now - start
        result.milliseconds = Int(elapsed / .milliseconds(1))
        return result
    }

    private func carryOut(_ step: ControlStep) async throws -> ControlStepResult {
        switch step.action {
        case .look:
            return try await look(step)
        case .click:
            return ControlStepResult(action: .click, note: try await click(step))
        case .move:
            let place = try await place(of: try require(step.target, "what to move to"))
            try await machine.pointer(.init(action: .move, x: place.x, y: place.y))
            acted()
        case .drag:
            let start = try await place(of: try require(step.target, "where the drag starts"))
            let end = try await place(of: try require(step.to, "where the drag ends"))
            try await machine.pointer(.init(action: .drag, x: start.x, y: start.y, button: step.button.map(pointerButton), toX: end.x, toY: end.y))
            acted()
        case .scroll:
            try await scroll(step)
        case .type:
            // A little at a time: long text takes a while, and whoever asked may have gone by then.
            var rest = try require(step.text, "what to type")[...]
            while !rest.isEmpty {
                try Task.checkCancellation()
                let piece = rest.prefix(24)
                try await machine.press(.init(text: String(piece)))
                rest = rest.dropFirst(piece.count)
            }
            acted()
        case .key:
            let keys = try require(step.keys, "which keys to press")
            guard !keys.isEmpty else { throw ControlFailure("Say which keys to press, such as Return or ctrl+c.") }
            try await machine.press(.init(keys: keys))
            acted()
        case .set:
            return ControlStepResult(action: .set, note: try await set(step))
        case .focus:
            try await focus(step)
        case .wait:
            return ControlStepResult(action: .wait, note: try await wait(step))
        case .screenshot:
            return try await screenshot(step)
        case .open:
            try await open(try require(step.text, "what to open"))
            acted()
        case .clipboard:
            return ControlStepResult(action: .clipboard, note: try await clipboard(step.text))
        }
        return ControlStepResult(action: step.action)
    }

    private func require<Value>(_ value: Value?, _ what: String) throws -> Value {
        guard let value else { throw ControlFailure("Say \(what).") }
        return value
    }

    private func pointerButton(_ button: ControlStep.Button) -> GuestPointer.Button {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        }
    }

    private func acted() {
        lastAction = clock.now
    }

    // MARK: Looking

    /// How many pixels of a display of this size make one of the places a look counts in: so many that
    /// its picture is one a model is shown as it is. Whole numbers where that is near enough, as text
    /// stays sharp at those.
    static func scale(width: Int, height: Int) -> Double {
        let longest = Double(max(width, height))
        guard longest > longestSide else { return 1 }
        let exact = longest / longestSide
        return exact <= 1.6 ? exact : exact.rounded(.up)
    }

    /// The display's picture, waking it first if the guest turned it off: any key does that.
    private func awakeFrame() async throws -> ScreenFrame {
        do {
            return try await machine.frame()
        } catch MachineDeskError.nothingShown {
            try await machine.press(.init(keys: ["shift"]))
            let deadline = clock.now + .seconds(4)
            while true {
                do {
                    return try await machine.frame()
                } catch MachineDeskError.nothingShown where clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    /// What was done a moment ago takes a moment to show. Waits until the picture stops changing, for a
    /// second at most: a caret that blinks never stops.
    private func settle() async throws -> ScreenFrame {
        var frame = try await awakeFrame()
        guard let lastAction, clock.now - lastAction < .seconds(2) else { return frame }
        let deadline = clock.now + Self.settlePatience
        var sample = frame.sample
        var quietSince = clock.now
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
            frame = try await awakeFrame()
            let now = frame.sample
            if ScreenFrame.difference(between: sample, and: now) > Self.restlessPixels {
                sample = now
                quietSince = clock.now
            } else if clock.now - quietSince >= Self.quiet {
                break
            }
        }
        return frame
    }

    private struct Reading {
        var frame: ScreenFrame
        var tree: DeskTree?
        /// Why there is no tree.
        var problem: String?
    }

    /// - Parameter front: The application in front is all that is wanted of the tree.
    private func read(frame: ScreenFrame, front: Bool = false) async throws -> Reading {
        do {
            let json = try await machine.screenTree(.init(front: front ? true : nil))
            guard let tree = DeskTree(json: json) else { return Reading(frame: frame, problem: "The guest tools' answer couldn't be read.") }
            return Reading(frame: frame, tree: tree)
        } catch {
            return Reading(frame: frame, problem: error.localizedDescription)
        }
    }

    /// What is written on the screen, or `nil` if that couldn't be read: which isn't the same as nothing
    /// being written there.
    private func ocrLines(of frame: ScreenFrame) async -> [ScreenText.Line]? {
        guard let image = frame.image else { return nil }
        return try? await readText(image)
    }

    private func look(_ step: ControlStep) async throws -> ControlStepResult {
        let frame = try await settle()
        let reading = try await read(frame: frame, front: step.all != true && step.application == nil)
        let scale = Self.scale(width: frame.width, height: frame.height)
        let screen = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        var entries = reading.tree?.entries(screen: screen, all: step.all == true, named: step.application) ?? []
        var notes: [String] = []
        if let problem = reading.problem {
            notes.append("read from the screen's pixels only: \(ShownText.line(problem, limit: 200))")
        }
        if reading.tree?.isTruncated == true { notes.append("the desktop has more than its guest tools tell") }
        // Too little to go by: a login screen, or an application that draws itself.
        let readable = entries.filter { $0.name != nil || $0.value != nil }.count
        if step.ocr == true || readable < 3 {
            if let lines = await ocrLines(of: frame) {
                entries = DeskOCR.merged(lines, into: entries)
            } else {
                notes.append("the screen's pixels couldn't be read on this Mac")
            }
        }
        let numbered = numbering.number(entries)
        var shown = numbered
        table = Dictionary(numbered.map { ($0.number, $0.entry) }, uniquingKeysWith: { first, _ in first })
        sequence += 1

        func element(_ number: Int, _ entry: DeskEntry) -> ControlElement {
            ControlElement(
                number: number, role: entry.role, name: entry.name, value: entry.value, states: entry.states.isEmpty ? nil : entry.states,
                frame: entry.frame.map { Self.places($0, scale: scale) }, depth: entry.depth
            )
        }
        var look = ControlLook(
            machine: machine.controlName, system: machine.systemName, width: Int((Double(frame.width) / scale).rounded()),
            height: Int((Double(frame.height) / scale).rounded()), scale: scale, sequence: sequence,
            applications: reading.tree?.applicationNames ?? [], front: step.all == true ? nil : (step.application == nil ? reading.tree?.frontName : nil),
            notes: notes.isEmpty ? nil : notes
        )
        if step.changes == true {
            let changed = numbered.filter { element in lastShown[element.number].map { !$0.looksLike(element.entry) } ?? false }
            let added = numbered.filter { lastShown[$0.number] == nil }
            let current = Set(numbered.map(\.number))
            look.removed = lastShown.filter { !current.contains($0.key) }.sorted { $0.key < $1.key }.map { element($0.key, $0.value) }
            look.changed = changed.map(\.number)
            shown = changed + added
        }
        if step.all != true, shown.count > Self.longestList {
            look.omitted = shown.count - Self.longestList
            shown = Array(shown.prefix(Self.longestList))
        }
        look.elements = shown.map { element($0.number, $0.entry) }
        lastShown = table

        var result = ControlStepResult(action: .look, look: look)
        if step.image == true {
            result.image = try await picture(of: frame, region: step.region, scale: scale)
            if step.region != nil {
                let notes = result.look?.notes ?? []
                result.look?.notes = notes + ["the picture of a region is as sharp as the display: its pixels aren't places to click, the list's are"]
            }
        }
        return result
    }

    /// A rectangle in the display's pixels, in the places a look counts in.
    private static func places(_ frame: CGRect, scale: Double) -> [Int] {
        [frame.minX, frame.minY, frame.width, frame.height].map { Int(($0 / scale).rounded()) }
    }

    private func picture(of frame: ScreenFrame, region: [Int]?, scale: Double) async throws -> Data {
        var area: CGRect?
        if let region {
            guard region.count == 4, region[2] > 0, region[3] > 0 else { throw ControlFailure("A region is its left, top, width and height.") }
            area = CGRect(
                x: Double(region[0]) * scale, y: Double(region[1]) * scale, width: Double(region[2]) * scale, height: Double(region[3]) * scale
            ).intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            guard area?.isEmpty == false else { throw ControlFailure("That region isn't on the screen.") }
        }
        // A part of the screen is shown as sharp as it is: looking closer is what it is for.
        let picture = await Task.detached(priority: .userInitiated) { frame.jpeg(region: area, divisor: area == nil ? scale : 1) }.value
        guard let picture else { throw ControlFailure("The picture of the screen couldn't be written down.") }
        return picture
    }

    private func screenshot(_ step: ControlStep) async throws -> ControlStepResult {
        let frame = try await settle()
        let png = await Task.detached(priority: .userInitiated) { frame.png() }.value
        guard let png else { throw ControlFailure("The picture of the screen couldn't be written down.") }
        return ControlStepResult(action: .screenshot, image: png)
    }

    // MARK: What a step means

    /// Finds what a target names in the display's pixels: its middle, or `nil` for an element that has
    /// no place on the screen. An element from an earlier look is looked up again if the screen may
    /// have changed since: it may have moved, or gone.
    private func locate(_ target: ControlTarget) async throws -> (place: CGPoint?, entry: DeskEntry?) {
        switch target {
        case .point(let x, let y):
            let frame = try await awakeFrame()
            let scale = Self.scale(width: frame.width, height: frame.height)
            let place = CGPoint(x: (Double(x) + 0.5) * scale, y: (Double(y) + 0.5) * scale)
            guard CGRect(x: 0, y: 0, width: frame.width, height: frame.height).contains(place) else {
                throw ControlFailure("(\(x), \(y)) isn't on the screen, which is \(Int(Double(frame.width) / scale)) by \(Int(Double(frame.height) / scale)).")
            }
            return (place, nil)
        case .number(let number):
            guard let known = table[number] else {
                throw ControlFailure("Nothing has the number \(number). Look first: its numbers are what to use.")
            }
            let entry = try await refreshed(known, number: number)
            return (entry.frame.map { CGPoint(x: $0.midX, y: $0.midY) }, entry)
        case .text(let text):
            let entry = try await find(text)
            return (entry.frame.map { CGPoint(x: $0.midX, y: $0.midY) }, entry)
        }
    }

    private func place(of target: ControlTarget) async throws -> (x: Int, y: Int) {
        let located = try await locate(target)
        if let place = located.place { return (Int(place.x), Int(place.y)) }
        // Wayland doesn't tell applications where they are. If it says something, the pixels know.
        if let name = located.entry?.name, let image = try await awakeFrame().image,
           let found = try await ScreenText.find(name, in: image, within: CGRect(x: 0, y: 0, width: image.width, height: image.height)) {
            return (Int(found.midX), Int(found.midY))
        }
        throw ControlFailure("Its place isn't known: Wayland doesn't tell applications where they are. Use `look --image` and give a place.")
    }

    /// The element as it is now. Always looked up again: the screen may have changed in any number of ways
    /// since the last look, and acting on where something was is how the wrong thing gets clicked. One
    /// that has moved is found where it is. One that has gone, or can't be told apart from others like it
    /// any more, is an error.
    private func refreshed(_ known: DeskEntry, number: Int) async throws -> DeskEntry {
        // What was read off the pixels is read there again, in the same place.
        guard known.elementID != nil else {
            let frame = try await settle()
            guard let image = frame.image, let area = known.frame else { return known }
            let lines = (try? await ScreenText.lines(in: image, within: area.insetBy(dx: -8, dy: -8))) ?? []
            let letters = ScreenText.letters(of: known.name ?? "")
            guard let line = lines.first(where: { ScreenText.letters(of: $0.text).contains(letters) }) else {
                throw ControlFailure("[\(number)] “\(known.name ?? "")” isn't on the screen any more. Look again.")
            }
            var entry = known
            entry.frame = line.frame
            return entry
        }
        let frame = try await settle()
        let screen = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        // Mostly it is in the application in front, and that is quick to ask.
        var alike: [DeskEntry] = []
        for front in [true, false] where alike.isEmpty {
            let reading = try await read(frame: frame, front: front)
            guard let tree = reading.tree else {
                throw ControlFailure("Whether [\(number)] is still there can't be told: \(ShownText.line(reading.problem ?? "", limit: 200)) Look again.")
            }
            alike = tree.entries(screen: screen, all: true).filter { $0.identity == known.identity }
        }
        guard !alike.isEmpty else {
            throw ControlFailure("[\(number)] \(known.role) “\(known.name ?? "")” isn't on the screen any more. Look again.")
        }
        // As the last look had them, in its order.
        let before = table.filter { $0.value.identity == known.identity }.sorted { $0.key < $1.key }
        var found: DeskEntry?
        if before.count == 1, alike.count == 1 {
            found = alike[0]
        } else if before.count == alike.count {
            // Several alike are only told apart by where they are. If that is as it was, it is the same
            // one. A row taken from a list moves the others up, each into the place of the one before.
            let places = { (entries: [DeskEntry]) in entries.map { $0.frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [] } }
            if places(before.map(\.value)).sorted(by: { $0.lexicographicallyPrecedes($1) }) == places(alike).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                found = known.frame == nil
                    ? before.firstIndex { $0.key == number }.map { alike[$0] }
                    : alike.first { $0.frame == known.frame }
            }
        }
        guard let found else {
            throw ControlFailure("[\(number)] \(known.role) “\(known.name ?? "")” is one of several alike, and they have changed. Look again.")
        }
        table[number] = found
        return found
    }

    /// The one thing on the screen that says `text`. Looks at what the guest tools tell first and at the
    /// pixels after that. Several things that say it are for whoever asked to tell apart.
    private func find(_ text: String) async throws -> DeskEntry {
        let frame = try await settle()
        let screen = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        // Mostly it is in the application in front, and that is quick to ask.
        let reading = try await read(frame: frame, front: true)
        if let found = try choose(text, among: reading.tree?.entries(screen: screen) ?? []) { return found }
        let everything = try await read(frame: frame).tree?.entries(screen: screen, all: true) ?? []
        if let found = try choose(text, among: everything) { return found }
        guard let lines = await ocrLines(of: frame) else {
            throw ControlFailure("Nothing the guest tools tell says “\(text)”, and the screen's pixels couldn't be read on this Mac.")
        }
        if let found = try choose(text, among: DeskOCR.merged(lines, into: everything)) { return found }
        throw ControlFailure("Nothing on the screen says “\(text)”.")
    }

    private func choose(_ text: String, among entries: [DeskEntry]) throws -> DeskEntry? {
        for exactly in [true, false] {
            let matches = entries.filter { $0.says(text, exactly: exactly) }
            guard !matches.isEmpty else { continue }
            if matches.count == 1 { return matches[0] }
            // What takes a click comes before what only says so.
            let usable = matches.filter(\.isInteractive)
            if usable.count == 1 { return usable[0] }
            // A box and the field inside it, saying the same, are one thing to whoever asks: the innermost.
            if let inner = Self.innermost(usable.isEmpty ? matches : usable) { return inner }
            let numbered = numbering.number(entries)
            let listed = (usable.isEmpty ? matches : usable).prefix(6).compactMap { match in
                numbered.first { $0.entry == match }.map { "[\($0.number)] \(match.role) “\(match.name ?? match.value ?? "")”" }
            }
            table.merge(numbered.map { ($0.number, $0.entry) }, uniquingKeysWith: { _, new in new })
            throw ControlFailure("Several things say “\(text)”: \(listed.joined(separator: ", ")). Use one's number.")
        }
        return nil
    }

    /// The one of `entries` that all the others hold, if there is one.
    private static func innermost(_ entries: [DeskEntry]) -> DeskEntry? {
        let placed = entries.compactMap { entry in entry.frame.map { (entry, $0) } }
        guard placed.count == entries.count,
              let smallest = placed.min(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }),
              placed.allSatisfy({ $0.1.contains(smallest.1) })
        else { return nil }
        return smallest.0
    }

    // MARK: Acting

    private func click(_ step: ControlStep) async throws -> String? {
        let located = try await locate(try require(step.target, "what to click"))
        let count = step.count ?? 1
        guard (1...3).contains(count) else { throw ControlFailure("A click is one, two or three clicks.") }
        guard let place = located.place else {
            // No place: Wayland doesn't tell. The guest tools can press it all the same, if it is a plain click.
            guard let id = located.entry?.elementID, count == 1, (step.button ?? .left) == .left else {
                throw ControlFailure("Its place isn't known, and only a plain click can do without. Use `look --image` and give a place.")
            }
            try await machine.act(on: .init(action: .press, element: id))
            acted()
            return nil
        }
        try await machine.pointer(.init(action: .click, x: Int(place.x), y: Int(place.y), button: step.button.map(pointerButton), count: count))
        acted()
        return nil
    }

    private func scroll(_ step: ControlStep) async throws {
        let frame = try await awakeFrame()
        var place = (x: frame.width / 2, y: frame.height / 2)
        if let target = step.target {
            place = try await self.place(of: target)
        }
        let notches = step.amount ?? 3
        guard (1...100).contains(notches) else { throw ControlFailure("How far to scroll is a number of notches, 100 at most.") }
        let delta: (x: Int, y: Int) = switch step.direction ?? .down {
        case .up: (0, -notches)
        case .down: (0, notches)
        case .left: (-notches, 0)
        case .right: (notches, 0)
        }
        try await machine.pointer(.init(action: .scroll, x: place.x, y: place.y, deltaX: delta.x, deltaY: delta.y))
        acted()
    }

    private func selectAllKeys() -> String {
        machine.guestFamily == .macOS ? "cmd+a" : "ctrl+a"
    }

    /// Replaces the text of a field the way a person does, which is what programs listen for: a value
    /// that the guest tools set is there to see, and the Save dialog of Windows saves under the old name
    /// all the same. The guest tools do it where a person can't: where its place isn't known, or for
    /// what the machine's keyboard has no keys for.
    private func set(_ step: ControlStep) async throws -> String? {
        let text = try require(step.text, "what to set it to")
        let located = try await locate(try require(step.target, "what to set"))
        let isTypeable = text.allSatisfy { MacKeys.press(typing: $0) != nil }
        if let place = located.place, isTypeable {
            try await machine.pointer(.init(action: .click, x: Int(place.x), y: Int(place.y)))
            try await machine.press(.init(keys: [selectAllKeys()]))
            if text.isEmpty {
                try await machine.press(.init(keys: ["Delete"]))
            } else {
                try await machine.press(.init(text: text))
            }
            acted()
            return nil
        }
        guard let id = located.entry?.elementID else {
            throw ControlFailure("Its place isn't known, or the machine's keyboard can't type that, and it isn't something the guest tools know.")
        }
        do {
            try await machine.act(on: .init(action: .set, element: id, text: text))
        } catch {
            throw ControlFailure("It doesn't take text from the guest tools: \(error.localizedDescription) Click on it, and type.")
        }
        acted()
        return nil
    }

    private func focus(_ step: ControlStep) async throws {
        let located = try await locate(try require(step.target, "what to give the keyboard"))
        if let id = located.entry?.elementID, (try? await machine.act(on: .init(action: .focus, element: id))) != nil {
            acted()
            return
        }
        guard let place = located.place else { throw ControlFailure("It can't be given the keyboard, and its place isn't known.") }
        try await machine.pointer(.init(action: .click, x: Int(place.x), y: Int(place.y)))
        acted()
    }

    // MARK: Waiting

    /// Waits for text to appear or go, or for the screen to settle. Looks only when the pixels changed,
    /// so that a screen at rest costs next to nothing.
    ///
    /// While the screen is moving it only reads pixels, which nothing in the guest knows of. Asking a
    /// desktop what it shows while it is changing that is what brings it down: GNOME Shell has been seen to
    /// crash, taking the session with it, when its accessibility is read during the unlock animation.
    private func wait(_ step: ControlStep) async throws -> String? {
        let settling = step.text == nil && step.gone == nil
        let seconds = min(max(step.timeout ?? (settling ? 10 : 30), 0), Self.longestWait)
        let start = clock.now
        let deadline = start + .seconds(seconds)
        var sample: [UInt32]?
        var quietSince = start
        // What changed since the guest tools, and the pixels, were last read.
        var treeIsOld = true
        var pixelsAreOld = true
        var lastTree: ContinuousClock.Instant?
        var lastPixels: ContinuousClock.Instant?
        var treeEntries: [DeskEntry] = []
        var pixelEntries: [DeskEntry] = []
        // Whether the guest tools and the pixels could be read at all. Not being able to read something
        // says nothing about whether it is there.
        var treeIsKnown = false
        var pixelsAreKnown = false
        var hasTriedWaking = false
        func took() -> String {
            String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), Double((clock.now - start) / .milliseconds(1)) / 1000)
        }
        func outOfTime() throws -> String {
            // A screen that keeps moving, such as one that shows a video or an animated lock screen,
            // is no failure: waiting for it to settle is only ever a courtesy.
            if settling { return "still changing after \(took())" }
            let wanted = step.text.map { "“\($0)” to show" } ?? step.gone.map { "“\($0)” to go" } ?? ""
            let time = seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            throw ControlFailure("Waited \(time) seconds for \(wanted).", timedOut: true)
        }
        while true {
            let frame: ScreenFrame
            do {
                // A guest that is restarting has no picture for a while, and it comes back by itself.
                frame = hasTriedWaking ? try await machine.frame() : try await awakeFrame()
            } catch MachineDeskError.nothingShown {
                hasTriedWaking = true
                sample = nil
                guard clock.now < deadline else { return try outOfTime() }
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            let now = frame.sample
            let difference = sample.map { ScreenFrame.difference(between: $0, and: now) } ?? .max
            if difference != 0 {
                sample = now
                treeIsOld = true
                pixelsAreOld = true
            }
            if difference > Self.restlessPixels { quietSince = clock.now }
            let isQuiet = clock.now - quietSince >= Self.quiet
            if settling {
                if clock.now - quietSince >= .milliseconds(400) { return "settled after \(took())" }
            } else {
                let readsTree = isQuiet && treeIsOld && (lastTree.map { clock.now - $0 >= .milliseconds(200) } ?? true)
                let readsPixels = pixelsAreOld && (lastPixels.map { clock.now - $0 >= .seconds(1) } ?? true)
                if readsTree {
                    treeIsOld = false
                    lastTree = clock.now
                    let screen = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                    let tree = try await read(frame: frame).tree
                    treeIsKnown = tree != nil
                    treeEntries = tree?.entries(screen: screen, all: true) ?? []
                }
                if readsPixels {
                    pixelsAreOld = false
                    lastPixels = clock.now
                    let lines = await ocrLines(of: frame)
                    pixelsAreKnown = lines != nil
                    pixelEntries = DeskOCR.merged(lines ?? [], into: [])
                }
                if readsTree || readsPixels {
                    let isSaid = { (text: String) in (treeEntries + pixelEntries).contains { $0.says(text, exactly: false) } }
                    if let text = step.text, isSaid(text) {
                        return "“\(text)” is on the screen after \(took())"
                    }
                    // Gone is only gone when what can be read of this screen says so, and something can be.
                    if let gone = step.gone, isQuiet, !treeIsOld, !pixelsAreOld, treeIsKnown || pixelsAreKnown, !isSaid(gone) {
                        return "“\(gone)” has gone after \(took())"
                    }
                }
            }
            guard clock.now < deadline else { return try outOfTime() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Commands in the guest's session

    private func open(_ what: String) async throws {
        do {
            _ = try await machine.runInSession(GuestCommands.open(what, on: machine.guestFamily), input: nil)
        } catch {
            throw ControlFailure("“\(what)” couldn't be opened: \(error.localizedDescription)")
        }
    }

    private func clipboard(_ text: String?) async throws -> String? {
        let family = machine.guestFamily
        if let text {
            _ = try await machine.runInSession(GuestCommands.setClipboard(on: family), input: Data(text.utf8))
            return nil
        }
        let said = try await machine.runInSession(GuestCommands.clipboard(on: family), input: nil)
        return String(decoding: said, as: UTF8.self)
    }
}

/// The commands that a machine's system does some things with: no agent has to know them.
enum GuestCommands {
    static func open(_ what: String, on family: GuestFamily) -> [String] {
        switch family {
        case .macOS:
            if what.hasPrefix("~/") {
                // No shell reads a command, so nothing else says what `~` is.
                return ["/bin/sh", "-c", "exec /usr/bin/open \"$HOME/$1\"", "swiftvm-open", String(what.dropFirst(2))]
            }
            let isPlace = what.contains("://") || what.hasPrefix("/")
            return ["/usr/bin/open"] + (isPlace ? [] : ["-a"]) + [what]
        case .linux:
            return ["/bin/sh", "-c", linuxOpen, "swiftvm-open", what]
        case .windows:
            // `start` takes its first quoted word as a window's title.
            return ["cmd.exe", "/c", "start", "", windowsWord(what)]
        }
    }

    /// `word` as `cmd.exe` is to read it. What has spaces is quoted on its way there, and needs nothing.
    /// What hasn't, a URL with `&` in it for one, would be taken for several commands.
    static func windowsWord(_ word: String) -> String {
        guard !word.contains(where: \.isWhitespace), !word.contains("\"") else { return word }
        return word.reduce(into: "") { result, character in
            if "&|<>^()".contains(character) { result.append("^") }
            result.append(character)
        }
    }

    /// A URL or a file goes to what opens those. A name is looked for among the desktop's applications,
    /// by what their menu calls them, and failing that it is a command, which keeps running by itself.
    private static let linuxOpen = #"""
        what=$1
        case $what in
        "~/"*) what=$HOME/${what#"~/"} ;;
        esac
        case $what in
        *://* | /* | ./*) exec setsid -f xdg-open "$what" >/dev/null 2>&1 ;;
        esac
        for folder in "$HOME/.local/share/applications" /usr/local/share/applications /usr/share/applications /var/lib/flatpak/exports/share/applications /var/lib/snapd/desktop/applications; do
            [ -d "$folder" ] || continue
            found=$(grep -ilE "^Name=$what\$" "$folder"/*.desktop 2>/dev/null | head -n 1)
            [ -n "$found" ] || found=$(ls "$folder/$what.desktop" 2>/dev/null)
            [ -n "$found" ] || found=$(grep -ilE "^Name=.*$what" "$folder"/*.desktop 2>/dev/null | head -n 1)
            if [ -n "$found" ]; then
                id=$(basename "$found" .desktop)
                # Both come back once it has been started, and say whether it was. A desktop that has only
                # just come up may not take it the first time.
                if command -v gtk-launch >/dev/null 2>&1; then
                    setsid gtk-launch "$id" >/dev/null 2>&1 && exit 0
                    sleep 1
                    exec setsid gtk-launch "$id" >/dev/null 2>&1
                fi
                exec setsid gio launch "$found" >/dev/null 2>&1
            fi
        done
        command -v "$what" >/dev/null 2>&1 || { echo "no application is called $what" >&2; exit 127; }
        exec setsid -f "$what" >/dev/null 2>&1
        """#

    static func clipboard(on family: GuestFamily) -> [String] {
        switch family {
        case .macOS: ["/usr/bin/pbpaste"]
        case .linux: ["/bin/sh", "-c", linuxClipboard]
        case .windows: powershell("[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; Get-Clipboard -Raw")
        }
    }

    static func setClipboard(on family: GuestFamily) -> [String] {
        switch family {
        case .macOS: ["/usr/bin/pbcopy"]
        case .linux: ["/bin/sh", "-c", linuxSetClipboard]
        case .windows: powershell("$s = [Console]::OpenStandardInput(); $m = New-Object IO.MemoryStream; $s.CopyTo($m); Set-Clipboard -Value ([Text.Encoding]::UTF8.GetString($m.ToArray()))")
        }
    }

    private static func powershell(_ script: String) -> [String] {
        var encoded = Data()
        for unit in ("$ProgressPreference = 'SilentlyContinue'; " + script).utf16 {
            encoded.append(UInt8(unit & 0xFF))
            encoded.append(UInt8(unit >> 8))
        }
        return ["powershell.exe", "-NoProfile", "-NonInteractive", "-Sta", "-EncodedCommand", encoded.base64EncodedString()]
    }

    private static let noClipboardTool = "echo 'Reading the clipboard takes wl-clipboard or xclip in the guest.' >&2; exit 127"

    private static let linuxClipboard = """
        if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste >/dev/null 2>&1; then exec wl-paste --no-newline; fi
        if command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard -o; fi
        if command -v xsel >/dev/null 2>&1; then exec xsel --clipboard --output; fi
        \(noClipboardTool)
        """

    private static let linuxSetClipboard = """
        if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then exec wl-copy; fi
        if command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard -in >/dev/null 2>&1; fi
        if command -v xsel >/dev/null 2>&1; then exec xsel --clipboard --input; fi
        \(noClipboardTool)
        """
}
