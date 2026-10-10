import Foundation
import VMControl

/// `swiftvm console`: connects this terminal to a machine's serial console.
enum ConsoleSession {
    /// The key that ends the session: Control-], as in telnet. Everything else, Control-C included, goes
    /// to the guest.
    static let escapeByte: UInt8 = 0x1D

    /// Relays between the terminal and the console until the user leaves or the app goes away.
    ///
    /// - Parameters:
    ///   - descriptor: The stream to the app.
    ///   - name: The machine's name, for the greeting.
    ///   - idleTimeout: When input is piped in rather than typed, how long to keep printing output after
    ///     the input has ended and the guest has gone quiet. `nil` picks a short while for piped input,
    ///     and no limit for a job in the background, which is there to record.
    static func run(descriptor: Int32, name: String, idleTimeout: TimeInterval?) -> Never {
        // A job in the background of a terminal may neither change the terminal's settings nor read from
        // it (it would be stopped for trying). It only listens.
        let isBackgroundJob = isatty(STDIN_FILENO) == 1 && tcgetpgrp(STDIN_FILENO) != getpgrp()
        let isInteractive = isatty(STDIN_FILENO) == 1 && !isBackgroundJob
        let idleTimeout = idleTimeout ?? (isBackgroundJob ? nil : 1.5)
        var original = termios()
        if isInteractive {
            tcgetattr(STDIN_FILENO, &original)
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            note("Connected to the serial console of “\(name)”. Press Return for a prompt, Control-] to leave.")
        }
        func leave(_ message: String? = nil, status: Int32 = 0) -> Never {
            if isInteractive {
                tcsetattr(STDIN_FILENO, TCSANOW, &original)
                note(message ?? "Disconnected.", raw: false)
            }
            exit(status)
        }

        var descriptors = [
            pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
        ]
        var inputHasEnded = isBackgroundJob
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            // Once piped input has run out, stay only until the guest stops answering.
            let timeout = inputHasEnded ? idleTimeout.map { Int32($0 * 1000) } ?? -1 : -1
            let ready = poll(&descriptors, nfds_t(inputHasEnded ? 1 : 2), timeout)
            if ready == 0 { leave() }
            if ready < 0 {
                if errno == EINTR { continue }
                leave("The connection to SwiftVM was lost.", status: 1)
            }

            if descriptors[0].revents != 0 {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { leave("SwiftVM closed the console.", status: inputHasEnded ? 0 : 1) }
                writeAll(Array(buffer[0..<count]), to: STDOUT_FILENO)
            }
            if !inputHasEnded, descriptors[1].revents != 0 {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 {
                    inputHasEnded = true
                    continue
                }
                var bytes = Array(buffer[0..<count])
                var wantsToLeave = false
                if isInteractive, let index = bytes.firstIndex(of: escapeByte) {
                    bytes = Array(bytes[..<index])
                    wantsToLeave = true
                }
                writeAll(bytes, to: descriptor)
                if wantsToLeave { leave() }
            }
        }
    }

    /// A line from this tool rather than from the guest. In raw mode a new line needs its own return.
    private static func note(_ text: String, raw: Bool = true) {
        let line = raw ? "\r\n[\(text)]\r\n" : "\n[\(text)]\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if errno != EINTR {
                return
            }
        }
    }
}
