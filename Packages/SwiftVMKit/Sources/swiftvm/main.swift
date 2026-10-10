import Foundation
import VMControl

// swiftvm: control the running SwiftVM app from the command line.

let usage = """
Usage: swiftvm <command> [arguments]

  list                              List virtual machines
  info <machine>                    Show one machine in detail
  create <system> [options]         Create a machine and wait until it is ready
      <system> is macos, or a Linux image such as ubuntu-26.04
      --name <name>  --cpus <n>  --memory <GB>  --disk <GB>
      --user <name>  --password <password>  --no-start
      --ipsw <file>                 macOS: install this restore image instead of downloading the latest
  start <machine>                   Start, or resume a suspended machine
  stop <machine>                    Shut down and wait
  force-stop <machine>              Stop immediately
  suspend <machine>                 Save state to disk
  discard-state <machine>           Throw away a suspended machine's saved state, to start it up fresh
  pause <machine> | resume <machine>
  restart <machine>
  open <machine>                    Show the machine's window
  delete <machine>                  Move a stopped machine to the Trash
  clone <machine> [name]            Copy a machine that is shut down
  share <machine> <folder> [--read-only]   Share a folder with the machine
  unshare <machine> <folder>        Stop sharing a folder
  attach <machine> <image> [--read-only]   Plug in a disc or disk image as a USB drive
  eject <machine> <image>           Unplug it again
  resize <machine> <GB>             Grow the disk of a machine that is shut down
  forward <machine> <port>[:<guest port>] [--udp] [--allow-others]
                                    Make a port in the machine reachable as localhost:<port>
  unforward <machine> <port> [--udp]
  snapshot <machine> [name]         Save the machine's state to go back to later
  snapshots <machine>               List snapshots
  revert <machine> <snapshot>       Go back to a snapshot, discarding what happened since
  delete-snapshot <machine> <snapshot>
  ip <machine>                      Print the machine's IP address
  ssh <machine> [ssh arguments]     Open a shell (or run a command) in the machine
  console <machine> [--wait <seconds>]
                                    Connect this terminal to the machine's serial console
  quit                              Quit the app (only when no machine is running)

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

func printSnapshots(_ snapshots: [SnapshotSummary]) {
    guard !snapshots.isEmpty else {
        print("No snapshots.")
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let rows = [["NAME", "TAKEN", "RESUMES", "ID"]] + snapshots.map { snapshot in
        [snapshot.name, formatter.string(from: snapshot.createdAt), snapshot.includesMemory ? "yes" : "no", snapshot.id.uuidString]
    }
    let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
    for row in rows {
        let line = zip(row, widths).map { cell, width in cell.padding(toLength: width, withPad: " ", startingAt: 0) }
        print(line.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}

func printDetails(of machine: MachineSummary) {
    var lines: [(String, String)] = [
        ("Name", machine.name),
        ("State", machine.state),
        ("System", machine.system),
        ("Hardware", "\(machine.cpuCount) CPU, \(formatBytes(machine.memorySize)) RAM"),
        ("Disk", "\(formatBytes(machine.diskAllocated)) of \(formatBytes(machine.diskCapacity))"),
        ("Address", machine.address ?? "-"),
        ("SSH", machine.sshAlias.map { "swiftvm ssh \($0)" } ?? "-"),
    ]
    if let details = machine.details {
        lines.append(("MAC address", details.macAddress ?? "-"))
        for (index, drive) in details.drives.enumerated() {
            lines.append((index == 0 ? "Drives" : "", drive.path + (drive.readOnly ? " (read-only)" : "")))
        }
        for (index, folder) in details.sharedFolders.enumerated() {
            lines.append((index == 0 ? "Shared" : "", folder.path + (folder.readOnly ? " (read-only)" : "")))
        }
        for (index, forward) in (details.forwards ?? []).enumerated() {
            var text = "\(forward.allowsOtherDevices ? "*" : "localhost"):\(forward.hostPort) → \(forward.guestPort)"
            if forward.udp { text += " udp" }
            if let status = forward.status { text += " (\(status))" }
            lines.append((index == 0 ? "Forwards" : "", text))
        }
        lines.append(("Snapshots", String(details.snapshotCount)))
        lines.append(("Location", details.location))
    }
    let width = lines.map(\.0.count).max() ?? 0
    for (label, value) in lines {
        print((label.isEmpty ? "" : label + ":").padding(toLength: width + 3, withPad: " ", startingAt: 0) + value)
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

/// Stops with a message if `options` holds anything but the `allowed` flags. A misspelt flag that is
/// quietly ignored does the opposite of what was meant (`--readonly` attaching an image writable).
func rejectUnknownOptions(_ options: some Sequence<String>, allowed: Set<String>) {
    if let unknown = options.first(where: { !allowed.contains($0) }) {
        fail("Unknown option \(unknown).")
    }
}

switch commandName {
case "help", "--help", "-h":
    print(usage)

case "list", "ls":
    printTable(send(ControlRequest(command: .list)).machines)

case "create":
    guard let distribution = arguments.first, !distribution.hasPrefix("--") else {
        fail("Missing system: macos, or a Linux image such as ubuntu-26.04.")
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
        case "--ipsw": parameters.restoreImagePath = URL(fileURLWithPath: value(for: option)).standardizedFileURL.path
        case "--no-start": parameters.start = false
        default: fail("Unknown option \(option).")
        }
        index += 1
    }
    printTable(send(ControlRequest(command: .create, create: parameters)).machines)

case "share", "unshare":
    let machine = requireMachine()
    guard arguments.count >= 2 else { fail("Missing folder path.") }
    rejectUnknownOptions(arguments.dropFirst(2), allowed: commandName == "share" ? ["--read-only"] : [])
    let path = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
    let parameters = ControlRequest.ShareParameters(path: path, readOnly: arguments.dropFirst(2).contains("--read-only"))
    let command: ControlRequest.Command = commandName == "share" ? .share : .unshare
    printTable(send(ControlRequest(command: command, machine: machine, share: parameters)).machines)

case "info":
    if let machine = send(ControlRequest(command: .info, machine: requireMachine())).machines.first {
        printDetails(of: machine)
    }

case "attach", "eject":
    let machine = requireMachine()
    guard arguments.count >= 2 else { fail("Missing disk image.") }
    rejectUnknownOptions(arguments.dropFirst(2), allowed: commandName == "attach" ? ["--read-only"] : [])
    // To eject, the file name is enough; the app looks it up among the attached images.
    let isPath = commandName == "attach" || arguments[1].contains("/")
    let path = isPath ? URL(fileURLWithPath: arguments[1]).standardizedFileURL.path : arguments[1]
    let parameters = ControlRequest.DriveParameters(path: path, readOnly: arguments.dropFirst(2).contains("--read-only"))
    let command: ControlRequest.Command = commandName == "attach" ? .attach : .eject
    if let machine = send(ControlRequest(command: command, machine: machine, drive: parameters)).machines.first {
        printDetails(of: machine)
    }

case "forward", "unforward":
    let machine = requireMachine()
    guard arguments.count >= 2 else { fail("Missing port.") }
    let ports = arguments[1].split(separator: ":", omittingEmptySubsequences: false).map { UInt16($0) }
    guard (1...2).contains(ports.count), let hostPort = ports[0], hostPort > 0, ports.allSatisfy({ ($0 ?? 0) > 0 }) else {
        fail("“\(arguments[1])” isn't a port. Use <port> or <port on this Mac>:<port in the machine>.")
    }
    let options = arguments.dropFirst(2)
    rejectUnknownOptions(options, allowed: commandName == "forward" ? ["--udp", "--allow-others"] : ["--udp"])
    let parameters = ControlRequest.ForwardParameters(
        hostPort: hostPort, guestPort: ports.count == 2 ? ports[1] : nil,
        udp: options.contains("--udp"), allowsOtherDevices: options.contains("--allow-others")
    )
    let command: ControlRequest.Command = commandName == "forward" ? .forward : .unforward
    if let machine = send(ControlRequest(command: command, machine: machine, forward: parameters)).machines.first {
        printDetails(of: machine)
    }

case "resize":
    let machine = requireMachine()
    guard arguments.count >= 2, let gigabytes = Int(arguments[1]), gigabytes > 0 else { fail("Missing disk size in GB.") }
    rejectUnknownOptions(arguments.dropFirst(2), allowed: [])
    printTable(send(ControlRequest(command: .resize, machine: machine, diskGigabytes: gigabytes)).machines)

case "clone", "duplicate":
    let machine = requireMachine()
    // The name can be given the way `create` takes it or the way `snapshot` does.
    var name: String?
    var rest = Array(arguments.dropFirst())
    if let index = rest.firstIndex(of: "--name") {
        guard index + 1 < rest.count else { fail("--name needs a value.") }
        name = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
    }
    if let option = rest.first(where: { $0.hasPrefix("--") }) {
        fail("Unknown option \(option).")
    }
    if !rest.isEmpty {
        guard name == nil else { fail("Give the copy's name once.") }
        name = rest.joined(separator: " ")
    }
    printTable(send(ControlRequest(command: .clone, machine: machine, name: name)).machines)

case "snapshot":
    let machine = requireMachine()
    let name = arguments.count >= 2 ? arguments.dropFirst().joined(separator: " ") : nil
    printSnapshots(send(ControlRequest(command: .snapshot, machine: machine, name: name)).snapshots ?? [])

case "snapshots":
    printSnapshots(send(ControlRequest(command: .snapshots, machine: requireMachine())).snapshots ?? [])

case "revert", "delete-snapshot":
    let machine = requireMachine()
    guard arguments.count >= 2 else { fail("Missing snapshot name.") }
    let snapshot = arguments.dropFirst().joined(separator: " ")
    let command: ControlRequest.Command = commandName == "revert" ? .revert : .deleteSnapshot
    let response = send(ControlRequest(command: command, machine: machine, snapshot: snapshot))
    if command == .revert {
        printTable(response.machines)
    } else {
        printSnapshots(response.snapshots ?? [])
    }

case "console":
    let machine = requireMachine()
    var idleTimeout: Double?
    if let index = arguments.firstIndex(of: "--wait") {
        guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]), seconds >= 0, seconds <= 86_400 else {
            fail("--wait needs a number of seconds, a day at most.")
        }
        idleTimeout = seconds
    }
    do {
        let (response, descriptor) = try ControlClient().openStream(ControlRequest(command: .console, machine: machine))
        guard let descriptor else { fail(response.error ?? "The console isn't available.") }
        ConsoleSession.run(descriptor: descriptor, name: response.machines.first?.name ?? machine, idleTimeout: idleTimeout)
    } catch {
        fail(error.localizedDescription)
    }

case "quit":
    _ = send(ControlRequest(command: .quit))

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
    guard let command = ControlRequest.Command(rawValue: commandName), ![.create, .list, .quit].contains(command) else {
        fail("Unknown command “\(commandName)”.\n\n\(usage)")
    }
    printTable(send(ControlRequest(command: command, machine: requireMachine())).machines)
}
