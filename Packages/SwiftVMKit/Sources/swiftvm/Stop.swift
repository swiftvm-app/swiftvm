import Foundation
import VMControl

enum Stop {
    static let usage = "Usage: swiftvm stop <machine> [--once --via agent|power-button [--timeout <seconds>]]"

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ arguments: [String]) throws -> ControlRequest {
        guard let machine = arguments.first, !machine.hasPrefix("-") else { throw ParseError(message: usage) }
        var once = false
        var mechanism: String?
        var timeout: Double?
        var index = 1
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError(message: usage) }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--once" where !once:
                once = true
            case "--via" where mechanism == nil:
                let selected = try value()
                guard selected == "agent" || selected == "power-button" else { throw ParseError(message: usage) }
                mechanism = selected
            case "--timeout" where timeout == nil:
                guard let seconds = Double(try value()), seconds.isFinite, seconds > 0, seconds <= ControlRequest.longestWait else {
                    throw ParseError(message: "--timeout needs seconds greater than zero and at most 86400.")
                }
                timeout = seconds
            default:
                throw ParseError(message: usage)
            }
            index += 1
        }
        if !once {
            guard mechanism == nil, timeout == nil else { throw ParseError(message: usage) }
            return ControlRequest(command: .stop, machine: machine)
        }
        guard let mechanism else { throw ParseError(message: "--once needs --via agent or --via power-button.") }
        return ControlRequest(command: .shutdownOnce, machine: machine, timeout: timeout ?? 30, shutdownMechanism: mechanism)
    }

    static func status(for result: ControlResponse.Shutdown) -> Int32 {
        if result.observedState == "stopped" { return 0 }
        return result.timedOut ? 124 : 1
    }
}
