import Foundation
import GuestChannel

extension GuestJobs {
    static let desktopUsage = "Usage: swiftvm desktop <machine> [--timeout <seconds>] [--] <agent-desktop arguments>"

    /// The native CLI runs only in the guest's graphical session. Its output is not re-encoded: JSON
    /// errors, refs, skill text and batch input keep the upstream contract, including its exit status.
    static func desktop(_ arguments: [String]) -> Never {
        guard let machine = arguments.first, !machine.hasPrefix("-") else { fail(desktopUsage, status: failedStatus) }
        var rest = Array(arguments.dropFirst())
        var timeout = collectTimeout
        if rest.first == "--timeout" {
            guard rest.count >= 2, let seconds = Double(rest[1]), seconds > 0, seconds.isFinite, seconds <= 86_400 else {
                fail("--timeout needs a number of seconds, a day at most.", status: failedStatus)
            }
            timeout = seconds
            rest.removeFirst(2)
        }
        if rest.first == "--" { rest.removeFirst() }
        guard !rest.isEmpty, !rest.contains(where: { $0.contains("\0") }) else { fail(desktopUsage, status: failedStatus) }
        let seconds = timeout
        let diagnostic = Data("swiftvm: agent-desktop didn't finish in \(seconds.formatted()) seconds. The connection was closed; observe the guest before retrying an action.\n".utf8)
        signal(SIGPIPE, SIG_IGN)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            // A full error pipe must not hold cancellation. Its flags are shared with the caller,
            // and normal exit cleanup could wait for a blocked writer too.
            let reported = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                write(diagnostic, to: STDERR_FILENO)
                reported.signal()
            }
            _ = reported.wait(timeout: .now() + .milliseconds(50))
            _exit(timedOutStatus)
        }
        // The app's first answer may never arrive, so opening the job is part of the deadline too.
        let descriptor = open(.desktop(.init(arguments: rest)), in: machine, failureStatus: failedStatus)
        let end = run(descriptor, input: isatty(STDIN_FILENO) == 1 ? .empty : .from(STDIN_FILENO)) { write($0, to: STDOUT_FILENO) }
        if let error = end.shownError {
            FileHandle.standardError.write(Data("swiftvm: \(error)\n".utf8))
        }
        exit(end.status ?? end.signal.map { 128 + $0 } ?? failedStatus)
    }
}
