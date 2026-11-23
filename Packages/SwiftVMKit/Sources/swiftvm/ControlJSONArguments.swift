/// Interprets the output option without consuming another command's payload.
enum ControlJSONArguments {
    enum ParseError: Error, Equatable {
        case invalid(String)
    }

    static func isRequested(command: String, arguments: [String]) -> Bool {
        // Guest arguments are opaque. In particular, a guest's `--json` is data.
        ControlJSONResult.commands.contains(command) && arguments.contains { $0 == "--json" || $0.hasPrefix("--json=") }
    }

    static func parse(command: String, arguments: [String]) throws -> [String] {
        // Unsupported control commands must not mistake the option for a snapshot name or folder.
        // Creation parses option values itself, including passwords; streams and desktop control own theirs.
        if !ControlJSONResult.commands.contains(command), !["create", "exec", "cp", "ssh", "control"].contains(command),
           arguments.contains(where: { $0 == "--json" || $0.hasPrefix("--json=") }) {
            throw ParseError.invalid("--json isn't available for \(command). Supported control commands: \(ControlJSONResult.commands.sorted().joined(separator: ", ")).")
        }
        guard isRequested(command: command, arguments: arguments) else { return arguments }
        guard arguments.last == "--json", arguments.filter({ $0 == "--json" }).count == 1 else {
            throw ParseError.invalid("Put --json once, at the end of the command.")
        }
        let remaining = Array(arguments.dropLast())
        if command == "list" || command == "ls" {
            guard remaining.isEmpty else { throw ParseError.invalid("Usage: swiftvm list --json") }
        } else {
            guard let machine = remaining.first, !machine.hasPrefix("--") else { throw ParseError.invalid("Missing machine name.") }
            if command != "wait" && command != "network", remaining.count != 1 {
                throw ParseError.invalid("Usage: swiftvm \(command) <machine> --json")
            }
        }
        return remaining
    }
}
