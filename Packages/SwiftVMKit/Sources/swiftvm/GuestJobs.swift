import Foundation
import GuestChannel
import VMControl

/// `swiftvm exec`, `cp`, `screenshot` and `ui`: what the guest tools do in a guest when asked from here.
///
/// The app opens the job and then only passes bytes on, so that this tool and the agent in the guest
/// speak to each other in ``JobFrame``s. Leaving, for whatever reason, calls the job off.
enum GuestJobs {
    /// What `swiftvm exec` exits with when it isn't the command's own status, as `timeout` and `docker`
    /// have it: the time was up, or the command never got to run.
    static let timedOutStatus: Int32 = 124
    static let failedStatus: Int32 = 125
    /// A reader that went away, as the shell reports a program that a closed pipe ended.
    static let brokenPipeStatus: Int32 = 141
    /// The most that a job which isn't a command may put out: a screenshot, or the tree of a screen.
    static let longestCollectedOutput = 256 << 20
    /// How long such a job gets. An agent gives its own slowest part, the tree, a minute.
    static let collectTimeout: TimeInterval = 120

    // MARK: Running a job

    /// Has the guest tools of `machine` take on `job` and returns the connection that carries it. Stops
    /// with the reason when the app or the guest tools say no.
    static func open(_ job: GuestJob, in machine: String, failureStatus: Int32 = 1) -> Int32 {
        // A line that has gone shows as a write that fails, not as the end of this tool.
        signal(SIGPIPE, SIG_IGN)
        do {
            let (response, descriptor) = try ControlClient().openStream(ControlRequest(command: .job, machine: machine, job: job))
            guard let descriptor else { fail(response.error ?? "The guest tools didn't take that on.", status: failureStatus) }
            return descriptor
        } catch {
            fail(error.localizedDescription, status: failureStatus)
        }
    }

    /// Carries a job to its end and returns how it ended.
    ///
    /// - Parameters:
    ///   - input: What a command gets as its input. Jobs that aren't commands take none.
    ///   - output: Takes what the job puts out. Returning `false` says nobody is listening any more.
    ///   - errorOutput: The same for what a command prints as errors.
    static func run(
        _ descriptor: Int32, input: Input = .none, output: (Data) -> Bool, errorOutput: (Data) -> Bool = { write($0, to: STDERR_FILENO) }
    ) -> JobEnd {
        if input != .none {
            // Nobody else writes to the connection, so the frames of the input can't get mixed up with others.
            Thread.detachNewThread {
                if case .from(let source) = input {
                    var buffer = [UInt8](repeating: 0, count: JobFrame.maximumPayloadLength)
                    while true {
                        let count = read(source, &buffer, buffer.count)
                        if count > 0 {
                            guard JobFrame.write(.input, Data(buffer[0..<count]), to: descriptor) else { return }
                        } else if count == 0 || errno != EINTR {
                            break
                        }
                    }
                }
                // An empty frame is the end of the input.
                JobFrame.write(.input, to: descriptor)
            }
        }
        while true {
            guard let frame = try? JobFrame.read(from: descriptor) else {
                return .failure("The connection to the guest was lost before it was done.")
            }
            switch frame.kind {
            case .output:
                guard output(frame.payload) else { exit(brokenPipeStatus) }
            case .errorOutput:
                guard errorOutput(frame.payload) else { exit(brokenPipeStatus) }
            case .end:
                return frame.end ?? .success
            case .input:
                break
            }
        }
    }

    /// What a job is given as its input.
    enum Input: Equatable {
        /// Nothing is said about input: the job isn't a command.
        case none
        /// The command is told at once that no input is coming.
        case empty
        /// What can be read from this descriptor, to its end.
        case from(Int32)
    }

    /// Runs a job that has nothing to take in, and returns what it put out. Stops with the reason when
    /// it didn't work out.
    static func collect(_ job: GuestJob, in machine: String) -> Data {
        var collected = Data()
        let descriptor = open(job, in: machine)
        // These take a moment, not minutes. A guest that took the job on and then says nothing
        // would keep whoever asked waiting for good, and a script has nobody to press Control-C.
        DispatchQueue.global().asyncAfter(deadline: .now() + collectTimeout) {
            fail("The guest tools took this on and didn't finish in \(Int(collectTimeout)) seconds.")
        }
        let end = run(descriptor) { data in
            // A picture of a screen is a few megabytes. A guest that sends without end isn't sending one.
            guard collected.count + data.count <= longestCollectedOutput else {
                fail("The guest sent more than \(longestCollectedOutput >> 20) MB, which is no answer to this.")
            }
            collected.append(data)
            return true
        }
        if let error = end.shownError {
            fail(error)
        }
        guard end.status == 0 else { fail("The guest tools gave up, without saying why.") }
        return collected
    }

    @discardableResult
    static func write(_ data: Data, to descriptor: Int32) -> Bool {
        ByteRelay.writeAll(ArraySlice(data), to: descriptor)
    }

    // MARK: exec

    static let execUsage = "Usage: swiftvm exec <machine> [--root | --user <name>] [--cwd <folder>] [--env <name>=<value>] [--timeout <seconds>] [--] <command> [arguments]"

    /// `swiftvm exec`: runs a command in the guest, and ends the way the command did.
    static func exec(_ arguments: [String]) -> Never {
        guard let machine = arguments.first, !machine.hasPrefix("-") else { fail(execUsage, status: failedStatus) }
        var account = Account()
        var directory: String?
        var environment: [String: String] = [:]
        var timeout: Double?
        var index = 1
        func value(for option: String) -> String {
            index += 1
            guard index < arguments.count else { fail("\(option) needs a value.", status: failedStatus) }
            return arguments[index]
        }
        // Options end at the first word that isn't one, or at a double dash: what follows is the
        // command's, dashes and all.
        options: while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--":
                index += 1
                break options
            case "--root", "--user":
                account.take(option, value: option == "--user" ? value(for: option) : nil, failureStatus: failedStatus)
            case "--cwd":
                directory = value(for: option)
            case "--env":
                let pair = value(for: option).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, !pair[0].isEmpty else { fail("--env needs <name>=<value>.", status: failedStatus) }
                environment[String(pair[0])] = String(pair[1])
            case "--timeout":
                guard let seconds = Double(value(for: option)), seconds > 0, seconds.isFinite else {
                    fail("--timeout needs a number of seconds.", status: failedStatus)
                }
                timeout = seconds
            default:
                guard !option.hasPrefix("-") else { fail("Unknown option \(option).\n\(execUsage)", status: failedStatus) }
                break options
            }
            index += 1
        }
        let command = Array(arguments.dropFirst(index))
        guard !command.isEmpty else { fail(execUsage, status: failedStatus) }

        let job = GuestJob.exec(.init(
            arguments: command, user: account.name, directory: directory, environment: environment.isEmpty ? nil : environment
        ))
        let descriptor = open(job, in: machine, failureStatus: failedStatus)
        if let timeout {
            // Leaving is what calls the command off in the guest.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                FileHandle.standardError.write(Data("swiftvm: The command didn't finish in \(timeout.formatted()) seconds, and was stopped.\n".utf8))
                exit(timedOutStatus)
            }
        }
        // What is typed at a terminal isn't the command's to read: it has no terminal of its own.
        let end = run(descriptor, input: isatty(STDIN_FILENO) == 1 ? .empty : .from(STDIN_FILENO)) { write($0, to: STDOUT_FILENO) }
        if let error = end.shownError {
            FileHandle.standardError.write(Data("swiftvm: \(error)\n".utf8))
        }
        exit(end.status ?? end.signal.map { 128 + $0 } ?? failedStatus)
    }

    /// The account a command runs as, the way `--root` and `--user` name it.
    struct Account {
        /// `nil` leaves it to the app: the machine's own account.
        var name: String?

        mutating func take(_ option: String, value: String?, failureStatus: Int32 = 1) {
            guard name == nil else { fail("Give --root or --user, once.", status: failureStatus) }
            name = option == "--root" ? "root" : value
        }
    }

    // MARK: cp

    static let copyUsage = "Usage: swiftvm cp [--root | --user <name>] <from> <to>, where one of the two is <machine>:<path>"

    /// Puts what arrives on its input where `cp -R` would: into `$1` if that is a folder, under the name
    /// `$1` otherwise. `$2` is the name it arrives under, a dot for the contents of a folder.
    private static let unpackScript = """
        set -e
        dest=$1
        name=$2
        if [ "$name" = . ]; then
            mkdir -p -- "$dest"
            exec tar --no-same-owner -xf - -C "$dest"
        fi
        if [ -d "$dest" ]; then
            exec tar --no-same-owner -xf - -C "$dest"
        fi
        parent=$(dirname -- "$dest")
        [ -d "$parent" ] || { echo "$parent: no such folder" >&2; exit 1; }
        work=$(mktemp -d "$parent/.swiftvm-cp.XXXXXX")
        trap 'rm -rf -- "$work"' EXIT
        tar --no-same-owner -xf - -C "$work"
        mv -f -- "$work/$name" "$dest"
        """

    private static let packScript = """
        cd -- "$(dirname -- "$1")" && exec tar -cf - -- "$(basename -- "$1")"
        """

    /// `swiftvm cp`: copies a file or a folder into a guest or out of one, as a tar archive that a
    /// command in the guest unpacks or packs.
    static func copy(_ arguments: [String]) -> Never {
        var account = Account()
        var places: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--root":
                account.take(argument, value: nil)
            case "--user":
                index += 1
                guard index < arguments.count else { fail("--user needs a value.") }
                account.take(argument, value: arguments[index])
            default:
                guard !argument.hasPrefix("--") else { fail("Unknown option \(argument).\n\(copyUsage)") }
                places.append(argument)
            }
            index += 1
        }
        guard places.count == 2 else { fail(copyUsage) }
        switch (CopyEndpoint(places[0]), CopyEndpoint(places[1])) {
        case (.local(let source), .guest(let machine, let destination)):
            copyIn(source, to: destination, in: machine, as: account.name)
        case (.guest(let machine, let source), .local(let destination)):
            copyOut(source, in: machine, to: destination, as: account.name)
        case (.local, .local):
            fail("Neither is in a virtual machine. \(copyUsage)")
        case (.guest, .guest):
            fail("Copying from one virtual machine to another isn't done in one step: copy to this Mac first.")
        }
    }

    /// What the commands that pack and unpack in the guest run with: macOS keeps its tar from adding
    /// files of its own with this, and Linux doesn't mind.
    private static let archiveEnvironment = ["COPYFILE_DISABLE": "1"]

    private static func copyIn(_ source: String, to destination: String, in machine: String, as user: String?) -> Never {
        guard !destination.isEmpty else { fail("Missing where to put it in “\(machine)”.") }
        // `folder/.` is the folder's contents, as it is to cp.
        let isContents = source == "." || source.hasSuffix("/.")
        let url = URL(fileURLWithPath: source).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { fail("“\(source)” isn't there.") }
        let (parent, name) = isContents ? (url.path, ".") : (url.deletingLastPathComponent().path, url.lastPathComponent)

        let archive = Pipe()
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--no-xattrs", "--no-mac-metadata", "-cf", "-", "-C", parent, "--", name]
        tar.environment = ProcessInfo.processInfo.environment.merging(archiveEnvironment) { _, new in new }
        tar.standardInput = FileHandle.nullDevice
        tar.standardOutput = archive
        let job = GuestJob.exec(.init(
            arguments: ["/bin/sh", "-c", unpackScript, "swiftvm-cp", destination, name], user: user, environment: archiveEnvironment
        ))
        let descriptor = open(job, in: machine)
        do {
            try tar.run()
        } catch {
            fail("tar couldn't be run: \(error.localizedDescription)")
        }
        // The pipe's other end is tar's alone once tar runs, so that tar's end is the end of the archive.
        let packed = archive.fileHandleForReading.fileDescriptor
        let end = run(descriptor, input: .from(packed)) { _ in true }
        if end.error != nil || end.status != 0 {
            // The guest's side gave up before the archive was through, and nobody takes the rest of
            // it. tar would wait for someone to, for good.
            tar.terminate()
        } else {
            // The guest has all it needs. What tar still has to say after that is read to its end.
            var rest = [UInt8](repeating: 0, count: 64 * 1024)
            while read(packed, &rest, rest.count) > 0 {}
        }
        tar.waitUntilExit()
        finishCopy(end, archiver: tar)
    }

    private static func copyOut(_ source: String, in machine: String, to destination: String, as user: String?) -> Never {
        guard !source.isEmpty else { fail("Missing what to copy from “\(machine)”.") }
        let isContents = source == "." || source.hasSuffix("/.")
        // The last part of a path in the guest, read as text: this Mac's folders have no say in it.
        let name = isContents ? "." : String(source.split(separator: "/").last ?? "")
        guard !name.isEmpty, name != "..", isContents || name != "." else {
            fail("“\(source)” doesn't name a file or a folder in “\(machine)”. To copy what is in a folder, end its path with a slash and a dot, as in \(machine):/srv/.")
        }
        let target = URL(fileURLWithPath: destination).standardizedFileURL
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder)
        // The archive is the guest's word. It is unpacked in a folder of its own, next to where the copy
        // goes, and only what was asked for is taken out of it.
        let home = isContents || (exists && isFolder.boolValue) ? target : target.deletingLastPathComponent()
        let work: URL
        do {
            if isContents {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            work = home.appending(path: ".swiftvm-cp.\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        } catch {
            fail(error.localizedDescription)
        }
        func leave(_ message: String) -> Never {
            try? FileManager.default.removeItem(at: work)
            fail(message)
        }

        let archive = Pipe()
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", "-", "-C", work.path]
        tar.standardInput = archive
        tar.standardOutput = FileHandle.nullDevice
        let job = GuestJob.exec(.init(arguments: ["/bin/sh", "-c", packScript, "swiftvm-cp", source], user: user, environment: archiveEnvironment))
        let descriptor = open(job, in: machine)
        do {
            try tar.run()
        } catch {
            leave("tar couldn't be run: \(error.localizedDescription)")
        }
        let packed = archive.fileHandleForWriting.fileDescriptor
        // A tar that gave up shows in how it exits. The guest's side is heard out either way.
        let end = run(descriptor, input: .empty) { data in
            write(data, to: packed)
            return true
        }
        try? archive.fileHandleForWriting.close()
        tar.waitUntilExit()
        guard end.error == nil, end.status == 0, tar.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: work)
            finishCopy(end, archiver: tar)
        }

        // cp puts it where cp would: into a folder that is there, under the name given otherwise.
        let unpacked = isContents ? work.path + "/." : work.appending(path: name).path
        guard isContents || FileManager.default.fileExists(atPath: unpacked) else { leave("The guest sent something else than what was asked for.") }
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-Rc", unpacked, target.path]
        do {
            try cp.run()
        } catch {
            leave("cp couldn't be run: \(error.localizedDescription)")
        }
        cp.waitUntilExit()
        try? FileManager.default.removeItem(at: work)
        exit(cp.terminationStatus)
    }

    /// Ends `swiftvm cp` the way its two halves ended.
    private static func finishCopy(_ end: JobEnd, archiver: Process) -> Never {
        if let error = end.shownError {
            fail(error)
        }
        guard end.status == 0 else { exit(end.status ?? 1) }
        exit(archiver.terminationStatus)
    }

    // MARK: screenshot

    /// `swiftvm screenshot`: saves what is on the guest's screen as a PNG.
    static func screenshot(_ arguments: [String]) -> Never {
        guard let machine = arguments.first, arguments.count <= 2 else { fail("Usage: swiftvm screenshot <machine> [<file> | -]") }
        let picture = collect(.screenshot, in: machine)
        if arguments.count == 2, arguments[1] == "-" {
            exit(write(picture, to: STDOUT_FILENO) ? 0 : 1)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // A name of this tool's choosing is made of what a machine may be called by and nothing else.
        let stem = machine.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let path = arguments.count == 2 ? arguments[1] : "\(String(stem))-\(formatter.string(from: Date())).png"
        do {
            try picture.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            fail("The screenshot couldn't be saved: \(error.localizedDescription)")
        }
        print(path)
        exit(0)
    }

    // MARK: ui

    static let uiUsage = """
        Usage: swiftvm ui <machine> click <x> <y> [--button left|right|middle] [--count <n>]
               swiftvm ui <machine> double-click <x> <y> | right-click <x> <y> | move <x> <y>
               swiftvm ui <machine> drag <x> <y> <to x> <to y>
               swiftvm ui <machine> scroll <x> <y> up|down|left|right [<notches>]
               swiftvm ui <machine> type <text>
               swiftvm ui <machine> key <key>...
               swiftvm ui <machine> tree [--app <name>] [--depth <levels>] [--all]
               swiftvm ui <machine> press <element> [--action <name>] | focus <element> | set <element> <text>
        """

    /// `swiftvm ui`: the guest's mouse and keyboard, and what is on its screen as a tree.
    static func ui(_ arguments: [String]) -> Never {
        guard arguments.count >= 2 else { fail(uiUsage) }
        let machine = arguments[0]
        let action = arguments[1]
        var rest = Array(arguments.dropFirst(2))

        /// Takes `--name <value>` out of the arguments, if it is there.
        func option(_ name: String) -> String? {
            guard let index = rest.firstIndex(of: name) else { return nil }
            guard index + 1 < rest.count else { fail("\(name) needs a value.") }
            defer { rest.removeSubrange(index...(index + 1)) }
            return rest[index + 1]
        }
        func numbers(_ count: Int) -> [Int] {
            let values = rest.prefix(count).compactMap { Int($0) }
            guard values.count == count, values.allSatisfy({ $0 >= 0 }) else { fail(uiUsage) }
            rest.removeFirst(count)
            return values
        }
        func nothingLeft() {
            guard rest.isEmpty else { fail("“\(rest[0])” is one word too many.\n\(uiUsage)") }
        }

        let job: GuestJob
        switch action {
        case "click", "double-click", "right-click":
            var button = GuestJob.Pointer.Button.left
            if let name = option("--button") {
                guard let named = GuestJob.Pointer.Button(rawValue: name) else { fail("--button is left, right or middle.") }
                button = named
            }
            var count = action == "double-click" ? 2 : 1
            if let text = option("--count") {
                guard let number = Int(text), (1...3).contains(number) else { fail("--count is 1, 2 or 3.") }
                count = number
            }
            let place = numbers(2)
            nothingLeft()
            job = .pointer(.init(action: .click, x: place[0], y: place[1], button: action == "right-click" ? .right : button, count: count))
        case "move":
            let place = numbers(2)
            nothingLeft()
            job = .pointer(.init(action: .move, x: place[0], y: place[1]))
        case "drag":
            let places = numbers(4)
            nothingLeft()
            job = .pointer(.init(action: .drag, x: places[0], y: places[1], toX: places[2], toY: places[3]))
        case "scroll":
            let place = numbers(2)
            guard let direction = rest.first else { fail(uiUsage) }
            rest.removeFirst()
            var notches = 3
            if let text = rest.first {
                guard let number = Int(text), (1...100).contains(number) else { fail("How far to scroll is a number of notches, 100 at most.") }
                notches = number
                rest.removeFirst()
            }
            nothingLeft()
            let delta: (x: Int, y: Int)
            switch direction {
            case "up": delta = (0, -notches)
            case "down": delta = (0, notches)
            case "left": delta = (-notches, 0)
            case "right": delta = (notches, 0)
            default: fail("Scrolling goes up, down, left or right.")
            }
            job = .pointer(.init(action: .scroll, x: place[0], y: place[1], deltaX: delta.x, deltaY: delta.y))
        case "type":
            guard !rest.isEmpty else { fail("Missing the text to type.") }
            job = .keys(.init(text: rest.joined(separator: " ")))
        case "key":
            guard !rest.isEmpty else { fail("Missing the key to press, such as Return or ctrl+c.") }
            job = .keys(.init(keys: rest))
        case "tree":
            let application = option("--app")
            var depth: Int?
            if let text = option("--depth") {
                guard let number = Int(text), number > 0 else { fail("--depth needs a positive number.") }
                depth = number
            }
            let all = rest.firstIndex(of: "--all").map { rest.remove(at: $0) } != nil
            nothingLeft()
            job = .tree(.init(application: application, depth: depth, all: all ? true : nil))
        case "press", "focus":
            let named = action == "press" ? option("--action") : nil
            guard rest.count == 1 else { fail("Usage: swiftvm ui <machine> \(action) <element>, with the element's id from `swiftvm ui <machine> tree`") }
            job = .element(.init(action: action == "press" ? .press : .focus, element: rest[0], actionName: named))
        case "set":
            guard rest.count >= 2 else { fail("Usage: swiftvm ui <machine> set <element> <text>") }
            job = .element(.init(action: .set, element: rest[0], text: rest.dropFirst().joined(separator: " ")))
        default:
            fail("Unknown action “\(action)”.\n\(uiUsage)")
        }
        // What the guest tools have to say about it: the tree, or the element they acted on.
        let said = collect(job, in: machine)
        if !said.isEmpty {
            write(said, to: STDOUT_FILENO)
            if said.last != UInt8(ascii: "\n") {
                write(Data("\n".utf8), to: STDOUT_FILENO)
            }
        }
        exit(0)
    }
}
