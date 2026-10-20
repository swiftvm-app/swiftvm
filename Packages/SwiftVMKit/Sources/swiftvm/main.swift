import Foundation
import VMControl

// swiftvm: control the running SwiftVM app from the command line.

let usage = """
Usage: swiftvm <command> [arguments]

  list                              List virtual machines
  info <machine>                    Show one machine in detail
  create <system> [options]         Create a machine and wait until it is ready
      <system> is macos, windows, or a Linux image such as ubuntu-26.04
      --name <name>  --cpus <n>  --memory <GB>  --disk <GB>
      --user <name>  --password <password>  --no-start
      --location <folder>           Keep the machine in this folder, on an external disk for one, instead
                                    of the folder for new machines
      --no-ssh-key                  Don't let this Mac's SSH key into the account. Linux then needs a password
      --rosetta                     Linux: run x86-64 programs with Rosetta, using Apple's backend without GPU acceleration
      --gpu                         Linux: draw with this Mac's GPU (on by default for Omarchy).
                                    The machine runs on QEMU, so it can't be suspended or use Rosetta.
                                    Windows: install the experimental 3D driver (on by default when available).
                                    Windows is sharp at the size it starts at; a new window size takes a restart
      --no-gpu                      Linux: use Apple's backend without GPU acceleration, with suspend support.
                                    Windows: a driver for a display only, sharp at any window size but slower
      --compressed                  Linux and Windows: keep the disk compressed, which usually takes less
                                    than half the space on this Mac and makes writing slower
      --ipsw <file>                 macOS: install this restore image instead of downloading the latest
      --iso <file>                  Windows: install from this Windows 11 Arm64 ISO instead of downloading
                                    it from Microsoft. Windows needs a password
      --script <name>|<file>        Linux: run a setup script on the first start, a desktop for one.
                                    By its name in `swiftvm scripts`, or a file by its path (./mine.sh).
                                    Give it again for more scripts, which run in that order.
                                    A desktop needs a password
  create --template <template> [options]
                                    Create a machine from a template, with everything that was in the
                                    template's machine when it was saved
      --name <name>  --cpus <n>  --memory <GB>  --location <folder>  --no-start
      --disk <GB>                   Grow the disk beyond the template's
  scripts [<system>]                List the setup scripts for --script, or those for one Linux image
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
  move <machine> <folder>           Move a machine that is shut down into another folder, which may be on
                                    another disk. Waits until it is there
  share <machine> <folder> [--read-only]   Share a folder with the machine
  unshare <machine> <folder>        Stop sharing a folder
  attach <machine> <image> [--read-only]   Plug in a disc or disk image as a USB drive
  eject <machine> <image>           Unplug it again
  resize <machine> <GB>             Grow the disk of a machine that is shut down
  compression <machine> on|off      Keep the disk of a Linux machine that is shut down compressed, which
                                    usually takes less than half the space on this Mac, or not. Waits until
                                    the disk is converted
  forward <machine> <port>[:<guest port>] [--udp] [--allow-others]
                                    Make a port in the machine reachable as localhost:<port>
  unforward <machine> <port> [--udp]
  snapshot <machine> [name]         Save the machine's state to go back to later
  snapshots <machine>               List snapshots
  revert <machine> <snapshot>       Go back to a snapshot, discarding what happened since
  delete-snapshot <machine> <snapshot>
  rename-snapshot <machine> <snapshot> <new name>
  templates                         List templates
  save-template <machine> [name] [--snapshot <snapshot>]
                                    Save a machine that is shut down as a template, to create machines
                                    from. With --snapshot, save it as it was at a snapshot that was
                                    taken while it was shut down
  rename-template <template> <new name>
  delete-template <template>        Move a template to the Trash. Machines made from it stay as they are
  plug <machine> | unplug <machine> Plug the machine's network cable in, or pull it
  install-tools <machine> [--disc] [--password <password>]
                                    Install or reinstall the guest tools in a running machine. Connected
                                    tools replace themselves; otherwise use SSH (macOS needs --password).
                                    With --disc, plug in the tools disc to install from inside the guest
  share-clipboard <machine> on|off  Share what is copied on this Mac with the machine and the other way
                                    round, or stop. macOS guests need the guest tools for it
  usb                               List the USB devices this Mac has given the app
  usb attach <machine> <device>     Hand a USB device to a running machine. This Mac is without it until
                                    it is detached or pulled out, or the machine stops
  usb detach <machine> <device>     Give it back to this Mac
  usb auto <machine> <device> on|off
                                    Have the machine take the device by itself whenever both are there,
                                    or stop. <device> is its number in the list, its vendor:product, its
                                    serial number or its name
  ip <machine>                      Print the machine's IP address
  ssh <machine> [--vsock] [ssh arguments]
                                    Open a shell (or run a command) in the machine. With --vsock the
                                    connection goes through the machine's socket device rather than its
                                    network, so it also works while the network is down
  vsock <machine> <port>            Connect this command's input and output to a port in the machine over
                                    its socket device. Made for ssh: ProxyCommand swiftvm vsock <machine> 22
  console <machine> [--wait <seconds>]
                                    Connect this terminal to the machine's serial console
  wait <machine> [--timeout <seconds>]
                                    Wait until the machine's guest tools answer, which is when the
                                    commands below work
  exec <machine> [--root | --user <name>] [--cwd <folder>] [--env <name>=<value>]
       [--timeout <seconds>] [--] <command> [arguments]
                                    Run a command in the machine, as its own account or another. No
                                    shell reads it: for pipes and the like, run sh -c '...'. What is
                                    piped in goes to the command. Ends with the command's own status,
                                    124 when the time was up, 125 when the command couldn't be run
  cp [--root | --user <name>] <from> <to>
                                    Copy a file or a folder into the machine or out of it. The side in
                                    the machine is <machine>:<path>. Works as cp -R does
  screenshot <machine> [<file> | -] Save what is on the machine's screen as a PNG, and print where
  ui <machine> click <x> <y> [--button left|right|middle] [--count <n>]
  ui <machine> double-click <x> <y> | right-click <x> <y> | move <x> <y>
  ui <machine> drag <x> <y> <to x> <to y>
  ui <machine> scroll <x> <y> up|down|left|right [<notches>]
                                    Use the machine's mouse. Places are in the pixels of a screenshot
  ui <machine> type <text>          Type text on the machine's keyboard
  ui <machine> key <key>...         Press keys, one after the other: Return, Escape, ctrl+c, cmd+space
  ui <machine> tree [--app <name>] [--depth <levels>] [--all]
                                    Print what is on the machine's screen as a tree of its parts, in
                                    JSON: windows, buttons, text fields, each with an id. Boxes that
                                    only hold other parts are left out, unless you add --all
  ui <machine> press <element> [--action <name>] | focus <element> | set <element> <text>
                                    Do to one part of the tree, by its id, what a click on it would or
                                    another of its actions, give it the keyboard, or replace its text
  allow-accessibility <machine> --password <password>
                                    Have a macOS machine let its guest tools read the screen as a tree,
                                    for ui tree, press, set and focus. macOS asks someone at its screen
                                    for that: this turns the switch on in its System Settings and gives
                                    the account's password, with the machine's own mouse and keyboard
  automation <machine> on|off       Let exec, cp, screenshot and ui work in the machine, or not
  quit [--cancel-creations]         Quit the app. It refuses while a machine is running, and while one
                                    is being created unless you add --cancel-creations

<machine> is a name, SSH alias or UUID. <template> is a name or UUID.

exec and cp need the guest tools in the machine: swiftvm install-tools. So do screenshot and ui in a
Linux machine. A macOS machine's screen, mouse and keyboard need nothing in it. Its tree needs the
guest tools, and macOS to let them: swiftvm allow-accessibility.
"""

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("swiftvm: \(message)\n".utf8))
    exit(status)
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

func printTemplates(_ templates: [TemplateSummary]) {
    guard !templates.isEmpty else {
        print("No templates.")
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let rows = [["NAME", "SYSTEM", "CPU", "MEMORY", "DISK", "SAVED", "ID"]] + templates.map { template in
        [
            template.name,
            template.system,
            String(template.cpuCount),
            formatBytes(template.memorySize),
            "\(formatBytes(template.diskAllocated)) of \(formatBytes(template.diskCapacity))",
            formatter.string(from: template.createdAt),
            template.id.uuidString,
        ]
    }
    let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
    for row in rows {
        let line = zip(row, widths).map { cell, width in cell.padding(toLength: width, withPad: " ", startingAt: 0) }
        print(line.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}

func printUSBDevices(_ devices: [USBDeviceSummary]) {
    guard !devices.isEmpty else {
        print("No USB devices.")
        return
    }
    let rows = [["NUMBER", "DEVICE", "MAKER", "VENDOR:PRODUCT", "SERIAL NUMBER", "USED BY"]] + devices.map { device in
        // Some sticks give a serial number of over a hundred characters. Its beginning tells them apart.
        let serialNumber = device.serialNumber.map { $0.count > 24 ? $0.prefix(24) + "…" : $0 } ?? "-"
        return [String(device.id), device.name, device.manufacturer ?? "-", device.identifier, serialNumber, device.machine ?? "-"]
    }
    let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
    for row in rows {
        let line = zip(row, widths).map { cell, width in cell.padding(toLength: width, withPad: " ", startingAt: 0) }
        print(line.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    }
}

func printScripts(_ scripts: [SetupScriptSummary]) {
    guard !scripts.isEmpty else {
        print("No setup scripts.")
        return
    }
    let rows = [["NAME", "SETS UP", "KIND", "FOR", "NEEDS", "FROM", "ABOUT"]] + scripts.map { script in
        let needs = [
            script.minimumMemoryGigabytes.map { "\($0) GB memory" },
            script.minimumDiskGigabytes.map { "\($0) GB disk" },
        ].compactMap { $0 }
        return [
            script.id,
            script.name,
            script.category ?? "-",
            script.systems.isEmpty ? "any" : script.systems.joined(separator: ", "),
            needs.isEmpty ? "-" : needs.joined(separator: ", "),
            script.isBuiltIn ? "SwiftVM" : "your folder",
            script.summary ?? "-",
        ]
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
        for (index, device) in (details.usbDevices ?? []).enumerated() {
            lines.append((index == 0 ? "USB" : "", "\(device.name) (\(device.identifier))"))
        }
        for (index, rule) in (details.usbAutoConnect ?? []).enumerated() {
            lines.append((index == 0 ? "USB, by itself" : "", rule))
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
        if let tools = details.guestTools {
            lines.append(("Guest tools", tools.version ?? "not connected"))
            if let kernel = tools.kernel {
                lines.append(("Kernel", kernel))
            }
        }
        if let setup = details.setup {
            // `KDE Plasma: running, Installing KDE Plasma`
            let progress = [setup.state, setup.step].compactMap { $0 }.joined(separator: ", ")
            lines.append(("Setup", [setup.name, progress].compactMap { $0 }.joined(separator: ": ")))
        }
        if let sharesClipboard = details.sharesClipboard {
            lines.append(("Clipboard", sharesClipboard ? "shared" : "not shared"))
        }
        if let automation = details.automation {
            // `on (exec, screen, input, accessibility)`, with what the connected guest tools do.
            let features = automation.features.isEmpty || !automation.isAllowed ? "" : " (\(automation.features.joined(separator: ", ")))"
            lines.append(("Automation", (automation.isAllowed ? "on" : "off") + features))
        }
        lines.append(("Snapshots", String(details.snapshotCount)))
        lines.append(("Location", details.location))
    }
    let width = lines.map(\.0.count).max() ?? 0
    for (label, value) in lines {
        print((label.isEmpty ? "" : label + ":").padding(toLength: width + 3, withPad: " ", startingAt: 0) + value)
    }
}

// Built at the repository's root, this tool lands in the folder of the app's program, SwiftVM, and on a
// disk that takes the two names for one it replaces it. `swift run SwiftVM` then starts the tool. Say
// so, rather than answer as the tool to someone who asked for the app.
if let program = CommandLine.arguments.first.map({ URL(fileURLWithPath: $0) }), program.lastPathComponent == "SwiftVM" {
    fail("""
    This is the swiftvm tool, in the place of the app's program. It was built at the repository's root, \
    where the two share a folder and the disk takes swiftvm and SwiftVM for one name.
    Delete \(program.path) and run the command again. The tool on its own is built with
        swift build --package-path Packages/SwiftVMKit --product swiftvm
    """)
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
    // What the machine is made from: a system to install, which comes first, or a template.
    let system = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
    guard system != nil || arguments.contains("--template") else {
        fail("Missing system: macos, windows, or a Linux image such as ubuntu-26.04. Or a template, with --template <template>.")
    }
    var parameters = ControlRequest.CreateParameters(distribution: system ?? "")
    var options: [String] = []
    var index = system == nil ? 0 : 1
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
        options.append(option)
        switch option {
        case "--template": parameters.template = value(for: option)
        case "--name": parameters.name = value(for: option)
        case "--cpus": parameters.cpuCount = number(for: option)
        case "--memory": parameters.memoryGigabytes = number(for: option)
        case "--disk": parameters.diskGigabytes = number(for: option)
        case "--user": parameters.user = value(for: option)
        case "--password": parameters.password = value(for: option)
        case "--location": parameters.location = URL(fileURLWithPath: value(for: option)).standardizedFileURL.path
        case "--no-ssh-key": parameters.installsSSHKey = false
        case "--rosetta": parameters.rosetta = true
        case "--gpu": parameters.acceleratesGraphics = true
        case "--no-gpu": parameters.acceleratesGraphics = false
        case "--compressed": parameters.compressed = true
        case "--ipsw": parameters.restoreImagePath = URL(fileURLWithPath: value(for: option)).standardizedFileURL.path
        case "--iso": parameters.installerPath = URL(fileURLWithPath: value(for: option)).standardizedFileURL.path
        case "--script":
            // A name is one from the list. What has a slash in it is a file: ./mine.sh, ~/scripts/mine.sh.
            // The app is told where the file is from the root, as it isn't in this folder.
            let script = value(for: option)
            parameters.scripts = (parameters.scripts ?? []) + [script.contains("/") ? URL(fileURLWithPath: script).standardizedFileURL.path : script]
        case "--no-start": parameters.start = false
        default: fail("Unknown option \(option).")
        }
        index += 1
    }
    if options.contains("--gpu"), options.contains("--no-gpu") {
        fail("Use --gpu or --no-gpu, not both.")
    }
    if parameters.template != nil {
        guard system == nil else { fail("Give a system to install or a template, not both.") }
        // A template brings its system, its account and whatever was set up in it.
        let allowed: Set = ["--template", "--name", "--cpus", "--memory", "--disk", "--location", "--no-start"]
        if let option = options.first(where: { !allowed.contains($0) }) {
            fail("\(option) isn't for a machine made from a template, which keeps the template's system and account.")
        }
    }
    printTable(send(ControlRequest(command: .create, create: parameters)).machines)

case "scripts":
    guard arguments.count <= 1 else { fail("Usage: swiftvm scripts [<system>]") }
    let response = send(ControlRequest(command: .scripts, system: arguments.first))
    printScripts(response.setupScripts ?? [])
    if let note = response.note {
        print("\n" + note)
    }

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

case "install-tools":
    let machine = requireMachine()
    var options = Array(arguments.dropFirst())
    var password: String?
    if let index = options.firstIndex(of: "--password") {
        guard index + 1 < options.count else { fail("--password needs a value.") }
        password = options[index + 1]
        options.removeSubrange(index...(index + 1))
    }
    rejectUnknownOptions(options, allowed: ["--disc"])
    guard password == nil || !options.contains("--disc") else { fail("--password is for installing over SSH, not from the disc.") }
    let request = ControlRequest(
        command: .installTools, machine: machine, usesDisc: options.contains("--disc") ? true : nil, password: password
    )
    let response = send(request)
    if let machine = response.machines.first {
        printDetails(of: machine)
    }
    if let note = response.note {
        print("\n" + note)
    }

case "share-clipboard":
    let machine = requireMachine()
    guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
        fail("Usage: swiftvm share-clipboard <machine> on|off")
    }
    if let machine = send(ControlRequest(command: .shareClipboard, machine: machine, isOn: arguments[1] == "on")).machines.first {
        printDetails(of: machine)
    }

case "automation":
    let machine = requireMachine()
    guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
        fail("Usage: swiftvm automation <machine> on|off")
    }
    if let machine = send(ControlRequest(command: .automation, machine: machine, isOn: arguments[1] == "on")).machines.first {
        printDetails(of: machine)
    }

case "allow-accessibility":
    let machine = requireMachine()
    guard arguments.count == 3, arguments[1] == "--password" else {
        fail("Usage: swiftvm allow-accessibility <machine> --password <password>")
    }
    if let machine = send(ControlRequest(command: .allowAccessibility, machine: machine, password: arguments[2])).machines.first {
        printDetails(of: machine)
    }

case "wait":
    let machine = requireMachine()
    var options = Array(arguments.dropFirst())
    var timeout: Double?
    if let index = options.firstIndex(of: "--timeout") {
        guard index + 1 < options.count, let seconds = Double(options[index + 1]), seconds > 0, seconds <= ControlRequest.longestWait else {
            fail("--timeout needs a number of seconds, a day at most.")
        }
        timeout = seconds
        options.removeSubrange(index...(index + 1))
    }
    rejectUnknownOptions(options, allowed: [])
    printTable(send(ControlRequest(command: .wait, machine: machine, timeout: timeout)).machines)

case "exec":
    GuestJobs.exec(arguments)

case "cp":
    GuestJobs.copy(arguments)

case "screenshot":
    GuestJobs.screenshot(arguments)

case "ui":
    GuestJobs.ui(arguments)

case "usb":
    guard let action = arguments.first else {
        let response = send(ControlRequest(command: .usbList))
        printUSBDevices(response.usbDevices ?? [])
        if let note = response.note {
            print("\n" + note)
        }
        break
    }
    arguments.removeFirst()
    let commands: [String: ControlRequest.Command] = ["attach": .usbAttach, "detach": .usbDetach, "auto": .usbAuto]
    guard let command = commands[action] else {
        fail("Usage: swiftvm usb [attach <machine> <device> | detach <machine> <device> | auto <machine> <device> on|off]")
    }
    let machine = requireMachine()
    var rest = Array(arguments.dropFirst())
    var isOn: Bool?
    if command == .usbAuto {
        guard let last = rest.popLast(), ["on", "off"].contains(last) else {
            fail("Usage: swiftvm usb auto <machine> <device> on|off")
        }
        isOn = last == "on"
    }
    // A device's name can be several words.
    guard !rest.isEmpty else { fail("Missing USB device. `swiftvm usb` lists them.") }
    let request = ControlRequest(command: command, machine: machine, isOn: isOn, usbDevice: rest.joined(separator: " "))
    if let machine = send(request).machines.first {
        printDetails(of: machine)
    }

case "resize":
    let machine = requireMachine()
    guard arguments.count >= 2, let gigabytes = Int(arguments[1]), gigabytes > 0 else { fail("Missing disk size in GB.") }
    rejectUnknownOptions(arguments.dropFirst(2), allowed: [])
    printTable(send(ControlRequest(command: .resize, machine: machine, diskGigabytes: gigabytes)).machines)

case "compression":
    let machine = requireMachine()
    guard arguments.count == 2, ["on", "off"].contains(arguments[1]) else {
        fail("Usage: swiftvm compression <machine> on|off")
    }
    printTable(send(ControlRequest(command: .compression, machine: machine, isOn: arguments[1] == "on")).machines)

case "move":
    let machine = requireMachine()
    guard arguments.count == 2 else { fail("Usage: swiftvm move <machine> <folder>. Put a folder with spaces in quotes.") }
    // The app is told where the folder is from the root, as it isn't in this folder.
    let folder = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
    if let machine = send(ControlRequest(command: .move, machine: machine, location: folder)).machines.first {
        printDetails(of: machine)
    }

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

case "rename-snapshot":
    let machine = requireMachine()
    guard arguments.count == 3 else {
        fail("Usage: swiftvm rename-snapshot <machine> <snapshot> <new name>. Put a name with spaces in quotes.")
    }
    let request = ControlRequest(command: .renameSnapshot, machine: machine, name: arguments[2], snapshot: arguments[1])
    printSnapshots(send(request).snapshots ?? [])

case "templates":
    guard arguments.isEmpty else { fail("Usage: swiftvm templates") }
    let response = send(ControlRequest(command: .templates))
    printTemplates(response.templates ?? [])
    if let note = response.note {
        print("\n" + note)
    }

case "save-template":
    let machine = requireMachine()
    var rest = Array(arguments.dropFirst())
    var snapshot: String?
    if let index = rest.firstIndex(of: "--snapshot") {
        guard index + 1 < rest.count else { fail("--snapshot needs a value.") }
        snapshot = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
    }
    if let option = rest.first(where: { $0.hasPrefix("--") }) {
        fail("Unknown option \(option).")
    }
    // A name can be several words, as a snapshot's can.
    let name = rest.isEmpty ? nil : rest.joined(separator: " ")
    let request = ControlRequest(command: .saveTemplate, machine: machine, name: name, snapshot: snapshot)
    printTemplates(send(request).templates ?? [])

case "delete-template":
    guard !arguments.isEmpty else { fail("Missing template name.") }
    let request = ControlRequest(command: .deleteTemplate, template: arguments.joined(separator: " "))
    printTemplates(send(request).templates ?? [])

case "rename-template":
    guard arguments.count == 2 else {
        fail("Usage: swiftvm rename-template <template> <new name>. Put a name with spaces in quotes.")
    }
    let request = ControlRequest(command: .renameTemplate, name: arguments[1], template: arguments[0])
    printTemplates(send(request).templates ?? [])

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
    rejectUnknownOptions(arguments, allowed: ["--cancel-creations"])
    _ = send(ControlRequest(command: .quit, cancelsCreations: arguments.contains("--cancel-creations") ? true : nil))

case "ip":
    let response = send(ControlRequest(command: .list, machine: requireMachine()))
    guard let address = response.machines.first?.address else { fail("The machine has no address yet.") }
    print(address)

case "vsock":
    let machine = requireMachine()
    guard arguments.count == 2, let port = UInt32(arguments[1]), port > 0 else {
        fail("Usage: swiftvm vsock <machine> <port>")
    }
    do {
        let (response, descriptor) = try ControlClient().openStream(ControlRequest(command: .vsock, machine: machine, port: port))
        guard let descriptor else { fail(response.error ?? "The connection couldn't be made.") }
        StreamSession.run(descriptor: descriptor)
    } catch {
        fail(error.localizedDescription)
    }

case "ssh":
    let response = send(ControlRequest(command: .list, machine: requireMachine()))
    guard let machine = response.machines.first, let alias = machine.sshAlias else { fail("The machine has no SSH alias.") }
    var rest = Array(arguments.dropFirst())
    var options: [String] = []
    if rest.first == "--vsock" {
        rest.removeFirst()
        guard let tool = Bundle.main.executablePath else { fail("Couldn't find this tool's own path.") }
        // ssh runs this in a shell, after replacing what starts with a percent sign, and talks to it
        // instead of connecting to the machine's address.
        let quoted = "'" + tool.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "\(quoted) vsock \(machine.id.uuidString) \(StreamSession.sshPort)".replacingOccurrences(of: "%", with: "%%")
        options = ["-o", "ProxyCommand=\(command)"]
    }
    let sshArguments = ["ssh", "-F", ControlPaths.sshConfig.path] + options + [alias] + rest
    var cArguments: [UnsafeMutablePointer<CChar>?] = sshArguments.map { strdup($0) }
    cArguments.append(nil)
    execv("/usr/bin/ssh", cArguments)
    fail("Couldn't run ssh: \(String(cString: strerror(errno)))")

default:
    // What is left takes a machine and nothing else. The USB commands are spelled `usb …`, above.
    let others: [ControlRequest.Command] = [
        .create, .list, .quit, .usbList, .usbAttach, .usbDetach, .usbAuto, .scripts, .job, .move,
        .templates, .saveTemplate, .deleteTemplate, .renameTemplate,
    ]
    guard let command = ControlRequest.Command(rawValue: commandName), !others.contains(command) else {
        fail("Unknown command “\(commandName)”.\n\n\(usage)")
    }
    printTable(send(ControlRequest(command: command, machine: requireMachine())).machines)
}
