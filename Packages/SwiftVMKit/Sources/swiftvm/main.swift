import Foundation
import VMControl

// swiftvm: control the running SwiftVM app from the command line.

let usage = """
Usage: swiftvm <command> [arguments]

  list                              List virtual machines
  create <distribution> [options]   Create a Linux machine from a ready-made image
      --name <name>  --cpus <n>  --memory <GB>  --disk <GB>
      --user <name>  --password <password>  --no-start
  start <machine>                   Start, or resume a suspended machine
  stop <machine>                    Shut down and wait
  force-stop <machine>              Stop immediately
  suspend <machine>                 Save state to disk
  pause <machine> | resume <machine>
  restart <machine>
  open <machine>                    Show the machine's window
  delete <machine>                  Move a stopped machine to the Trash
  share <machine> <folder> [--read-only]   Share a folder with the machine
  unshare <machine> <folder>        Stop sharing a folder
  ip <machine>                      Print the machine's IP address
  ssh <machine> [ssh arguments]     Open a shell (or run a command) in the machine

<machine> is a name, SSH alias or UUID.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swiftvm: \(message)\n".utf8))
    exit(1)
}

func send(_ request: ControlRequest) -> ControlResponse {
    do {
        let response = try ControlClient().send(request)
        if !response.ok {
            fail(response.error ?? "The command failed.")
        }
        return response
    } catch {
        fail(error.localizedDescription)
    }
}

func formatBytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(clamping: value))
}

func printTable(_ machines: [MachineSummary]) {
    guard !machines.isEmpty else {
        print("No virtual machines.")
        return
    }
    let rows = [["NAME", "STATE", "ADDRESS", "SSH", "CPU", "MEMORY", "DISK", "SYSTEM"]] + machines.map { machine in
        [
            machine.name,
            machine.state,
            machine.address ?? "-",
            machine.sshAlias ?? "-",
            String(machine.cpuCount),
            formatBytes(machine.memorySize),
            "\(formatBytes(machine.diskAllocated)) of \(formatBytes(machine.diskCapacity))",
            machine.system,
        ]
    }
    let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
    for row in rows {
        let line = zip(row, widths).map { cell, width in cell.padding(toLength: width, withPad: " ", startingAt: 0) }
        print(line.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let commandName = arguments.first else {
    print(usage)
    exit(0)
}
arguments.removeFirst()

@MainActor func requireMachine() -> String {
    guard let machine = arguments.first else { fail("Missing machine name.\n\n\(usage)") }
    return machine
}

switch commandName {
case "help", "--help", "-h":
    print(usage)

case "list", "ls":
    printTable(send(ControlRequest(command: .list)).machines)

case "create":
    guard let distribution = arguments.first, !distribution.hasPrefix("--") else {
        fail("Missing distribution, e.g. ubuntu-26.04.")
    }
    var parameters = ControlRequest.CreateParameters(distribution: distribution)
    var index = 1
    func value(for option: String) -> String {
        index += 1
        guard index < arguments.count else { fail("\(option) needs a value.") }
        return arguments[index]
    }
    func number(for option: String) -> Int {
        guard let number = Int(value(for: option)), number > 0 else { fail("\(option) needs a positive number.") }
        return number
    }
    while index < arguments.count {
        let option = arguments[index]
        switch option {
        case "--name": parameters.name = value(for: option)
        case "--cpus": parameters.cpuCount = number(for: option)
        case "--memory": parameters.memoryGigabytes = number(for: option)
        case "--disk": parameters.diskGigabytes = number(for: option)
        case "--user": parameters.user = value(for: option)
        case "--password": parameters.password = value(for: option)
        case "--no-start": parameters.start = false
        default: fail("Unknown option \(option).")
        }
        index += 1
    }
    printTable(send(ControlRequest(command: .create, create: parameters)).machines)

case "share", "unshare":
    let machine = requireMachine()
    guard arguments.count >= 2 else { fail("Missing folder path.") }
    let path = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
    let parameters = ControlRequest.ShareParameters(path: path, readOnly: arguments.dropFirst(2).contains("--read-only"))
    let command: ControlRequest.Command = commandName == "share" ? .share : .unshare
    printTable(send(ControlRequest(command: command, machine: machine, share: parameters)).machines)

case "ip":
    let response = send(ControlRequest(command: .list, machine: requireMachine()))
    guard let address = response.machines.first?.address else { fail("The machine has no address yet.") }
    print(address)

case "ssh":
    let response = send(ControlRequest(command: .list, machine: requireMachine()))
    guard let alias = response.machines.first?.sshAlias else { fail("The machine has no SSH alias.") }
    let sshArguments = ["ssh", "-F", ControlPaths.sshConfig.path, alias] + arguments.dropFirst()
    var cArguments: [UnsafeMutablePointer<CChar>?] = sshArguments.map { strdup($0) }
    cArguments.append(nil)
    execv("/usr/bin/ssh", cArguments)
    fail("Couldn't run ssh: \(String(cString: strerror(errno)))")

default:
    guard let command = ControlRequest.Command(rawValue: commandName), command != .create, command != .list else {
        fail("Unknown command “\(commandName)”.\n\n\(usage)")
    }
    printTable(send(ControlRequest(command: command, machine: requireMachine())).machines)
}
