import Foundation
import GuestChannel
import VMControl

/// `swiftvm control`: sees and works a machine's desktop, for scripts and agents.
enum Control {
    static let usage = """
    Usage: swiftvm control <machine> <action> [arguments] [--then <action> [arguments]]... [--json]

    See and work a machine's desktop, the same on macOS, Windows and Linux, at a login screen too. The app
    reads the machine's screen and uses its mouse and keyboard from outside the guest, so nothing there has
    to allow it. Steps joined with --then run in one go: no process starts between them.

    Look
      look [--changes] [--image[=<file>]] [--region <x> <y> <w> <h>] [--app <name>] [--all] [--ocr]
          What is on the screen, one numbered line each:  [12] button "Save" 640,400 80x24
          The numbers stay with an element from look to look. --changes says only what changed. --image
          also saves a JPEG, whose pixels are the places in the list (it prints where). --region shows that
          part as sharp as it is, for reading: only the list's places are for clicking. By default a look covers the application in front; --app and --all widen
          it. What accessibility doesn't tell is read off the pixels; --ocr does that always.
      wait [--text <text> | --gone <text>] [--timeout <seconds>]
          Until the text is on the screen or has left it (30 seconds by default, then ending with 124), or
          without either until the screen has settled (10 seconds at most, then carrying on).
      screenshot [<file> | -]
          The display as a PNG, at its own full size. Prefer look --image, unless pixels matter.

    Act: <target> is a number from the last look, a text on the screen, or <x> <y>
      click <target> [--right | --middle] [--double | --count <n>]
      move <target>
      drag <target> --to <target>
      scroll [<target>] up|down|left|right [<notches>]
      type <text>                 Any text. Characters a US keyboard lacks need guest tools
      key <key>...                One after the other: Return, Escape, Tab, cmd+s, ctrl+shift+t, F5, shift
      set <number | text> <text>  Replace what a text field holds, as a person would. '' empties it
      focus <target>              Give it the keyboard

    In the guest's session
      open <application | file | URL>
      clipboard [<text>]          Say what is on the clipboard, or put text there

    Other
      allow --password <password>  Have macOS let the guest tools read its screen. Quick Create and
                                   install-tools --password do this already. No other system asks

    Text in a target goes by what the element says, ignoring case; when several say it, nothing is done
    and the numbers are listed. A number is checked before it is used: one whose element has gone, or that
    can't be told apart from others like it any more, is an error, never a click somewhere else.

    Exit status: 0 done, 1 a step failed, 124 a wait ran out of time, 125 it couldn't be asked.

    Examples
      swiftvm control desk look
      swiftvm control desk click 12 --then type 'hello' --then key Return --then look --changes
      swiftvm control desk click 'Sign In' --then wait --text 'Welcome' --timeout 60
      swiftvm control desk look --image=/tmp/screen.jpg
    """

    /// What arguments mean, or why they mean nothing.
    enum ParseError: Error, Equatable {
        case invalid(String)
    }

    struct Request: Equatable {
        var call: ControlCall
        /// Where to save what each step shows, by the step's position.
        var imageFiles: [Int: String] = [:]
        var printsJSON = false
    }

    static func run(_ arguments: [String]) -> Never {
        guard let machine = arguments.first, !machine.hasPrefix("-") else {
            if arguments.isEmpty || ["--help", "-h", "help"].contains(arguments[0]) {
                print(usage)
                exit(arguments.isEmpty ? ControlExit.couldNotRun : 0)
            }
            fail(usage, status: ControlExit.couldNotRun)
        }
        let rest = Array(arguments.dropFirst())
        if rest.isEmpty || ["--help", "-h", "help"].contains(rest[0]) {
            print(usage)
            exit(rest.isEmpty ? ControlExit.couldNotRun : 0)
        }
        if rest[0] == "allow" {
            allow(machine, Array(rest.dropFirst()))
        }
        let request: Request
        do {
            request = try parse(rest)
        } catch ParseError.invalid(let reason) {
            fail("\(reason)\nFor what there is: swiftvm control --help", status: ControlExit.couldNotRun)
        } catch {
            fail(error.localizedDescription, status: ControlExit.couldNotRun)
        }
        signal(SIGPIPE, SIG_IGN)
        let outcome: ControlOutcome
        do {
            outcome = try call(request.call, on: machine, timeout: deadline(of: request.call))
        } catch {
            fail(error.localizedDescription, status: ControlExit.couldNotRun)
        }
        report(outcome, request: request, machine: machine)
    }

    /// How long a call may take, in the tool, past which the app is taken not to answer.
    static func deadline(of call: ControlCall) -> TimeInterval {
        // Long text takes as long as its keys, which is a tenth of a second each on the slowest keyboard.
        60 + call.steps.reduce(0) { $0 + ($1.action == .wait ? ($1.timeout ?? 30) : 0) + Double($1.text?.count ?? 0) * 0.1 }
    }

    /// Has the app do the steps, and returns how they went. The connection carries the outcome in frames.
    static func call(_ call: ControlCall, on machine: String, timeout: TimeInterval, client: ControlClient = ControlClient()) throws -> ControlOutcome {
        let (response, descriptor) = try client.openStream(ControlRequest(command: .control, machine: machine, control: call))
        guard let descriptor else { throw ControlFailure(response.error ?? "The app didn't take that on.") }
        defer { close(descriptor) }
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ControlFailure("The app didn't finish that in \(Int(timeout)) seconds.") }
            guard let frame = try? JobFrame.read(from: descriptor, timeout: remaining) else {
                throw ControlFailure("The connection to the app was lost before it was done.")
            }
            switch frame.kind {
            case .output:
                collected.append(frame.payload)
            case .end:
                if let error = frame.end?.shownError { throw ControlFailure(error) }
                guard let outcome = ControlOutcomeCoding.outcome(from: collected) else {
                    throw ControlFailure("The app's answer couldn't be read.")
                }
                return outcome
            case .errorOutput, .input:
                break
            }
        }
    }

    struct ControlFailure: Error, LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func report(_ outcome: ControlOutcome, request: Request, machine: String) -> Never {
        var outcome = outcome
        var saved: [String] = []
        for (index, result) in outcome.results.enumerated() {
            guard let image = result.image else { continue }
            let file = request.imageFiles[index]
            if file == "-" {
                _ = ByteRelay.writeAll(ArraySlice(image), to: STDOUT_FILENO)
                exit(ControlExit.status(of: outcome))
            }
            let isPNG = result.action == .screenshot
            let path = file ?? defaultImagePath(for: machine, extension: isPNG ? "png" : "jpg")
            do {
                try image.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                fail("The picture couldn't be saved: \(error.localizedDescription)", status: ControlExit.failed)
            }
            saved.append(path)
            outcome.results[index].image = nil
            outcome.results[index].note = "image: \(path)"
        }
        if request.printsJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(outcome) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            let text = outcome.results.filter { $0.error == nil }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { print(text) }
            if let failure = outcome.failure, let error = failure.error {
                FileHandle.standardError.write(Data("swiftvm: \(failure.action.rawValue): \(error)\n".utf8))
            }
        }
        exit(ControlExit.status(of: outcome))
    }

    private static func defaultImagePath(for machine: String, extension fileExtension: String) -> String {
        let stem = String(machine.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftvm", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return folder.appending(path: "\(stem)-\(formatter.string(from: Date())).\(fileExtension)").path
    }

    private static func allow(_ machine: String, _ arguments: [String]) -> Never {
        guard arguments.count == 2, arguments[0] == "--password" else {
            fail("Usage: swiftvm control <machine> allow --password <password>", status: ControlExit.couldNotRun)
        }
        let response = send(ControlRequest(command: .allowAccessibility, machine: machine, password: arguments[1]))
        if let note = response.note { print(note) }
        exit(0)
    }

    // MARK: Reading the arguments

    static func parse(_ arguments: [String]) throws -> Request {
        var arguments = arguments
        var request = Request(call: ControlCall(steps: []))
        // At the very end, or it could be what is to be typed.
        if arguments.last == "--json" {
            request.printsJSON = true
            arguments.removeLast()
        }
        var pieces: [[String]] = [[]]
        for argument in arguments {
            if argument == "--then" {
                pieces.append([])
            } else {
                pieces[pieces.count - 1].append(argument)
            }
        }
        for piece in pieces {
            guard let name = piece.first else { throw ParseError.invalid("A step is missing around --then.") }
            let (step, file) = try parseStep(name, Array(piece.dropFirst()))
            if let file { request.imageFiles[request.call.steps.count] = file }
            request.call.steps.append(step)
        }
        return request
    }

    private static func parseStep(_ name: String, _ arguments: [String]) throws -> (ControlStep, String?) {
        guard let action = ControlStep.Action(rawValue: name) else {
            throw ParseError.invalid("“\(name)” isn't an action. The old `ui`, `desktop` and `screenshot` commands are all this one now.")
        }
        var words = Words(arguments)
        var step = ControlStep(action)
        var file: String?
        switch action {
        case .look:
            step.changes = words.flag("--changes") ? true : nil
            step.all = words.flag("--all") ? true : nil
            step.ocr = words.flag("--ocr") ? true : nil
            step.application = try words.option("--app")
            if words.flag("--image") {
                step.image = true
            } else if let path = words.prefixed("--image=") {
                step.image = true
                file = path
            }
            if let index = words.rest.firstIndex(of: "--region") {
                guard index + 4 < words.rest.count else { throw ParseError.invalid("--region takes its left, top, width and height.") }
                let numbers = words.rest[(index + 1)...(index + 4)].compactMap { Int($0) }
                guard numbers.count == 4 else { throw ParseError.invalid("--region takes its left, top, width and height, as numbers.") }
                step.region = numbers
                step.image = true
                words.rest.removeSubrange(index...(index + 4))
            }
        case .wait:
            step.text = try words.option("--text")
            step.gone = try words.option("--gone")
            step.timeout = try words.seconds("--timeout")
            if step.text != nil, step.gone != nil { throw ParseError.invalid("Wait for --text or for --gone, one at a time.") }
        case .screenshot:
            if let path = words.rest.first {
                file = path
                words.rest.removeFirst()
            }
        case .click:
            if words.flag("--right") { step.button = .right }
            if words.flag("--middle") { step.button = .middle }
            if words.flag("--double") { step.count = 2 }
            if let count = try words.option("--count") {
                guard let number = Int(count), (1...3).contains(number) else { throw ParseError.invalid("--count is 1, 2 or 3.") }
                step.count = number
            }
            step.target = try words.target()
        case .move, .focus:
            step.target = try words.target()
        case .drag:
            guard let index = words.rest.firstIndex(of: "--to") else { throw ParseError.invalid("A drag goes somewhere: drag <target> --to <target>.") }
            var to = Words(Array(words.rest[(index + 1)...]))
            step.to = try to.target()
            guard to.rest.isEmpty else { throw ParseError.invalid("“\(to.rest[0])” is one word too many.") }
            words.rest.removeSubrange(index...)
            step.target = try words.target()
        case .scroll:
            if let index = words.rest.firstIndex(where: { ControlStep.Direction(rawValue: $0) != nil }) {
                step.direction = ControlStep.Direction(rawValue: words.rest[index])
                if index + 1 < words.rest.count {
                    guard let notches = Int(words.rest[index + 1]) else { throw ParseError.invalid("How far to scroll is a number of notches.") }
                    step.amount = notches
                    words.rest.remove(at: index + 1)
                }
                words.rest.remove(at: index)
            }
            if !words.rest.isEmpty { step.target = try words.target() }
            if step.direction == nil { throw ParseError.invalid("Scrolling goes up, down, left or right.") }
        case .type:
            guard !words.rest.isEmpty else { throw ParseError.invalid("Say what to type.") }
            step.text = words.rest.joined(separator: " ")
            words.rest = []
        case .key:
            guard !words.rest.isEmpty else { throw ParseError.invalid("Say which keys to press, such as Return or ctrl+c.") }
            step.keys = words.rest
            words.rest = []
        case .set:
            // One word for what, and all the rest is the text: a number in it is no place.
            guard words.rest.count >= 2 else { throw ParseError.invalid("Say what to set and to what: set <number | text> <text>. '' empties it.") }
            let what = words.rest.removeFirst()
            step.target = Int(what.hasPrefix("[") && what.hasSuffix("]") ? String(what.dropFirst().dropLast()) : what).map { .number($0) } ?? .text(what)
            step.text = words.rest.joined(separator: " ")
            words.rest = []
        case .open:
            guard !words.rest.isEmpty else { throw ParseError.invalid("Say what to open: an application, a file or a URL.") }
            step.text = words.rest.joined(separator: " ")
            words.rest = []
        case .clipboard:
            if !words.rest.isEmpty {
                step.text = words.rest.joined(separator: " ")
                words.rest = []
            }
        }
        guard words.rest.isEmpty else { throw ParseError.invalid("“\(words.rest[0])” is one word too many for \(name).") }
        return (step, file)
    }

    private struct Words {
        var rest: [String]

        init(_ words: [String]) {
            rest = words
        }

        mutating func flag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }

        mutating func prefixed(_ prefix: String) -> String? {
            guard let index = rest.firstIndex(where: { $0.hasPrefix(prefix) }) else { return nil }
            return String(rest.remove(at: index).dropFirst(prefix.count))
        }

        mutating func option(_ name: String) throws -> String? {
            guard let index = rest.firstIndex(of: name) else { return nil }
            guard index + 1 < rest.count else { throw ParseError.invalid("\(name) needs a value.") }
            defer { rest.removeSubrange(index...(index + 1)) }
            return rest[index + 1]
        }

        mutating func seconds(_ name: String) throws -> Double? {
            guard let text = try option(name) else { return nil }
            guard let seconds = Double(text), seconds >= 0, seconds.isFinite else { throw ParseError.invalid("\(name) needs a number of seconds.") }
            return seconds
        }

        /// Two numbers are a place, one is a number from a look, and anything else is what it says.
        mutating func target() throws -> ControlTarget {
            guard let first = rest.first else { throw ParseError.invalid("Say what: a number from the last look, a text on the screen, or a place.") }
            if rest.count >= 2, let x = Int(first), let y = Int(rest[1]) {
                rest.removeFirst(2)
                return .point(x: x, y: y)
            }
            rest.removeFirst()
            if let number = Int(first.hasPrefix("[") && first.hasSuffix("]") ? String(first.dropFirst().dropLast()) : first) {
                return .number(number)
            }
            return .text(first)
        }
    }
}
