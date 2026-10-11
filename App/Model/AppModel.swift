import AppKit
import Installers
import Observation
import SSHIntegration
import VMControl
import VMCore
import VMNetworking
import VZEngine

/// App-wide state: the machine library and the services machines depend on.
@Observable
final class AppModel {
    static let shared = AppModel()

    let library: VMLibrary
    let downloader = ImageDownloader()
    let sshWriter: SSHConfigWriter
    let keyManager = SSHKeyManager()
    /// Relays the ports that machines forward from this Mac.
    let portForwarder = PortForwarder()
    /// Passes copied text between this Mac and the guests that share their clipboard.
    let clipboardSharing = ClipboardSharing()

    /// `nil` if the virtual network couldn't be set up; machines then can't start.
    private(set) var networkManager: NetworkManager?
    private(set) var backendProvider: VZBackendProvider?

    /// Machines that are still being downloaded or prepared.
    var creations: [MachineCreation] = []
    /// Machines whose own window is open; their errors are shown there instead of in the library.
    var openMachineWindows: Set<UUID> = []
    /// A problem that isn't tied to a single machine.
    var generalError: VMErrorInfo?
    /// Whether `~/.ssh/config` includes SwiftVM's generated hosts.
    private(set) var isSSHIncludeInstalled = false
    /// Addresses that running machines actually hold, by machine ID.
    private var observedAddresses: [UUID: String] = [:]
    /// The address each machine was last known to hold for certain: its agent said so, or it answered
    /// there. It outlives a stop, so that a machine that comes back is first looked for where it was.
    @ObservationIgnored private var lastSeenAddresses: [UUID: String] = [:]
    /// What the address monitor is waiting on between two rounds. Resuming it starts the next round early.
    @ObservationIgnored private var addressMonitorPause: CheckedContinuation<Void, Never>?
    /// Someone asked for another round while one was under way.
    @ObservationIgnored private var isAddressRefreshDue = false
    /// Shows a machine's window; set by the library window, which owns the SwiftUI window actions.
    @ObservationIgnored var showMachineWindow: ((UUID) -> Void)?
    @ObservationIgnored private var controlServer: ControlServer?
    /// The last duplication that was started. Each waits for the one before it, so that two of them can't
    /// pick the same name or SSH alias for their copies.
    @ObservationIgnored var lastDuplication: Task<Void, Never>?
    /// Set once the app has agreed to quit for the command-line tool, where there is nobody to ask what
    /// to do with machines. See ``quitUnattended()``.
    @ObservationIgnored private(set) var isQuittingUnattended = false
    @ObservationIgnored private var unattendedQuitTimer: Timer?
    /// Set once the user has said how to quit with machines running, and those are being suspended or
    /// shut down. See ``closeDown()``.
    @ObservationIgnored private(set) var isClosingDown = false

    private init() {
        library = VMLibrary()
        sshWriter = SSHConfigWriter(generatedConfigURL: library.rootDirectory.appending(path: "ssh_config"))
        isSSHIncludeInstalled = sshWriter.isIncludeInstalled

        do {
            let networkManager = try NetworkManager(rootDirectory: library.rootDirectory)
            networkManager.planProvider = { [weak self] in self?.networkPlan() ?? NetworkPlan() }
            networkManager.onDefaultSubnetChange = { [weak self] previous, current in
                self?.remapReservedAddresses(from: previous, to: current)
            }
            let provider = VZBackendProvider(networkManager: networkManager)
            self.networkManager = networkManager
            self.backendProvider = provider
            library.backendProvider = provider
        } catch {
            generalError = VMErrorInfo(title: "Virtual networking isn't available", message: error.localizedDescription)
        }

        library.onChange = { [weak self] in
            self?.syncSSHConfiguration()
            self?.syncPortForwards()
            // Clipboard sharing may have been turned on or off for one of them.
            self?.syncClipboardSharing()
        }
        library.onGuestAgentChange = { [weak self] machine in self?.clipboardSharing.update(machine) }
        library.onGuestClipboard = { [weak self] machine, text in self?.clipboardSharing.guest(machine, didCopy: text) }
        library.onGuestClipboardRequest = { [weak self] machine in self?.clipboardSharing.guestWantsClipboard(machine) }
        library.onMachineResume = { [weak self] machine in self?.correctClock(of: machine) }
        // A guest that says where it is doesn't have to wait for the next round to be believed.
        library.onGuestAddressesChange = { [weak self] _ in self?.refreshAddressesSoon() }
        // Whatever was being created when the app last quit can't be finished.
        library.removeStagedBundles()
        library.load()
        // If the host has joined a network that collides with ours, move before any machine starts.
        networkManager?.relocateDefaultSubnetIfNeeded()
        startControlServer()
        startAddressMonitor()
    }

    /// Lets the `swiftvm` command-line tool drive the app.
    private func startControlServer() {
        do {
            controlServer = try ControlServer(
                handler: { [weak self] request in
                    await self?.handle(request) ?? .failure("SwiftVM is shutting down.")
                },
                streamHandler: { [weak self] request in
                    await self?.openStream(request) ?? (.failure("SwiftVM is shutting down."), nil)
                }
            )
        } catch {
            // The app works without the command-line tool; don't interrupt launch for this.
            NSLog("SwiftVM: control socket unavailable: \(error.localizedDescription)")
        }
    }

    func stopControlServer() {
        controlServer?.invalidate()
        controlServer = nil
    }

    // MARK: Networking

    /// The address reserved for every machine, applied when the default network is created.
    private func networkPlan() -> NetworkPlan {
        var plan = NetworkPlan()
        for machine in library.machines {
            for interface in machine.configuration.networkInterfaces {
                guard let macAddress = MACAddress(interface.macAddress),
                      let address = interface.ipv4Address.flatMap(IPv4Address.init)
                else { continue }
                plan.reservations.append(.init(macAddress: macAddress, address: address))
            }
        }
        return plan
    }

    /// Forwards a port on this Mac to a port in `machine`. Takes effect at once if the machine is running.
    func addPortForward(_ forward: PortForward, to machine: VirtualMachine) throws {
        guard forward.hostPort > 0, forward.guestPort > 0 else {
            throw VMError.invalidConfiguration("Ports are numbers from 1 to 65535.")
        }
        guard !machine.configuration.networkInterfaces.isEmpty else {
            throw VMError.invalidConfiguration("“\(machine.name)” has no network interface.")
        }
        for other in library.machines {
            let taken = other.configuration.networkInterfaces.flatMap(\.portForwards)
                .contains { $0.hostPort == forward.hostPort && $0.transport == forward.transport }
            if taken {
                let owner = other.id == machine.id ? "this virtual machine" : "“\(other.name)”"
                throw VMError.invalidConfiguration(
                    "\(forward.transport.rawValue.uppercased()) port \(forward.hostPort) on this Mac already leads to \(owner)."
                )
            }
        }
        try machine.updateConfiguration { $0.networkInterfaces[0].portForwards.append(forward) }
    }

    func removePortForward(_ id: UUID, from machine: VirtualMachine) throws {
        try machine.updateConfiguration { configuration in
            for index in configuration.networkInterfaces.indices {
                configuration.networkInterfaces[index].portForwards.removeAll { $0.id == id }
            }
        }
    }

    /// Opens the forwarded ports of machines that are running and closes those of machines that aren't.
    /// Called whenever something they depend on may have changed, and regularly to retry ports that
    /// couldn't be opened.
    func syncPortForwards() {
        var routes: [UUID: PortRelay.Route] = [:]
        for machine in library.machines where machine.state == .running || machine.state == .paused {
            guard let address = address(for: machine).flatMap(IPv4Address.init) else { continue }
            for forward in machine.configuration.networkInterfaces.flatMap(\.portForwards) {
                routes[forward.id] = PortRelay.Route(
                    transport: forward.transport, hostPort: forward.hostPort,
                    guestAddress: address, guestPort: forward.guestPort,
                    allowsOtherDevices: forward.allowsOtherDevices
                )
            }
        }
        portForwarder.apply(routes)
    }

    private func syncClipboardSharing() {
        for machine in library.machines {
            clipboardSharing.update(machine)
        }
    }

    /// Moves every machine's reserved address along when the default network changes subnet.
    private func remapReservedAddresses(from previous: IPv4Subnet, to current: IPv4Subnet) {
        for machine in library.machines {
            try? machine.updateConfiguration { configuration in
                for index in configuration.networkInterfaces.indices {
                    guard let address = configuration.networkInterfaces[index].ipv4Address.flatMap(IPv4Address.init),
                          previous.contains(address)
                    else { continue }
                    configuration.networkInterfaces[index].ipv4Address =
                        NetworkManager.remap(address, from: previous, to: current).description
                }
            }
        }
        syncSSHConfiguration()
    }

    /// An unused address on the default network for a new machine.
    func allocateAddress() -> IPv4Address? {
        guard let networkManager else { return nil }
        let used = Set(library.machines.flatMap { machine in
            machine.configuration.networkInterfaces.compactMap { $0.ipv4Address.flatMap(IPv4Address.init) }
        })
        return networkManager.defaultSubnet.firstAvailableAddress(excluding: used)
    }

    /// The address the guest is reachable at from the host, if known.
    ///
    /// While a machine runs this is the address it actually holds; otherwise the one reserved for it.
    func address(for machine: VirtualMachine) -> String? {
        if machine.state.isActive, let observed = observedAddresses[machine.id] {
            return observed
        }
        return machine.configuration.networkInterfaces.first?.ipv4Address
    }

    /// Works out the address each active machine currently holds and updates the SSH hosts if any changed.
    ///
    /// A guest whose agent is connected says so itself. For the others: a guest normally gets its reserved
    /// address. One whose DHCP client doesn't identify itself by MAC address is handed a different one,
    /// which shows up in the lease database. When there is more than one candidate, the one that accepts a
    /// connection on the SSH port wins.
    private func refreshObservedAddresses() async {
        guard let networkManager else { return }
        var updated: [UUID: String] = [:]
        for machine in library.machines where machine.state.isActive {
            guard let interface = machine.configuration.networkInterfaces.first,
                  let macAddress = MACAddress(interface.macAddress)
            else { continue }
            if machine.agent.isConnected {
                // A guest with the agent says which address it holds, and nothing has to be worked out.
                // That is the address of the machine's network card, or, where the card is part of a
                // bridge or a bond with a hardware address of its own, whichever address is on the
                // app's network.
                let subnet = networkManager.defaultSubnet
                let onCard = machine.agent.addresses(ofInterface: interface.macAddress).compactMap(IPv4Address.init)
                let reported = onCard.first(where: subnet.contains) ?? onCard.first
                    ?? machine.agent.addresses.compactMap(IPv4Address.init).first(where: subnet.contains)
                if let reported {
                    updated[machine.id] = reported.description
                    lastSeenAddresses[machine.id] = reported.description
                    continue
                }
                // It reports none: its cable is out, it is still asking for an address, or its agent
                // can't tell. Then it is worked out as for any guest, with one difference below.
            }
            let hasAgent = machine.agent.isConnected
            // Where the machine was last known to be for certain, or failing that where it was listed.
            // With an agent on the line the listing was itself only a guess.
            let previous = (lastSeenAddresses[machine.id] ?? (hasAgent ? nil : observedAddresses[machine.id])).flatMap(IPv4Address.init)
            let ssh = machine.configuration.ssh
            var candidates = DHCPLeases.currentAddresses(macAddress: macAddress, hostName: ssh.alias, in: networkManager.defaultSubnet)
            if let reserved = networkManager.activeReservation(for: macAddress), !candidates.contains(reserved) {
                candidates.append(reserved)
            }
            guard var chosen = candidates.first else { continue }
            if candidates.count > 1 {
                var answering: IPv4Address?
                for candidate in candidates where await Reachability.canConnect(to: candidate, port: ssh.port) {
                    answering = candidate
                    break
                }
                // While nothing answers (still starting up), keep what was shown before rather than flip
                // around. A guest whose agent is there and reports no address most likely holds none
                // yet: a lease on the books is then history, and the reserved address is where it will
                // turn up.
                let expected = hasAgent ? networkManager.activeReservation(for: macAddress) : nil
                chosen = answering ?? previous.flatMap { candidates.contains($0) ? $0 : nil } ?? expected ?? chosen
                if let answering {
                    lastSeenAddresses[machine.id] = answering.description
                }
            }
            updated[machine.id] = chosen.description
        }
        if updated != observedAddresses {
            observedAddresses = updated
            syncSSHConfiguration()
        }
        syncPortForwards()
    }

    /// Keeps observed addresses current while machines run. Reading the small lease file is cheap.
    ///
    /// One round runs at a time, every two seconds, and sooner when ``refreshAddressesSoon()`` asks.
    private func startAddressMonitor() {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshObservedAddresses()
                guard let self else { return }
                if isAddressRefreshDue {
                    isAddressRefreshDue = false
                    continue
                }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled {
                        self?.refreshAddressesSoon()
                    }
                }
                await withCheckedContinuation { self.addressMonitorPause = $0 }
                timer.cancel()
            }
        }
    }

    /// Has the address monitor look again now rather than at its next turn.
    private func refreshAddressesSoon() {
        guard let pause = addressMonitorPause else {
            // A round is under way and may have looked at this machine already.
            isAddressRefreshDue = true
            return
        }
        addressMonitorPause = nil
        pause.resume()
    }

    // MARK: SSH

    /// Rewrites the generated SSH configuration from the current library.
    func syncSSHConfiguration() {
        let entries = library.machines.compactMap { machine -> SSHHostEntry? in
            let configuration = machine.configuration
            guard !configuration.ssh.alias.isEmpty, let address = address(for: machine) else { return nil }
            return SSHHostEntry(
                alias: configuration.ssh.alias,
                hostName: address,
                user: configuration.ssh.user.isEmpty ? nil : configuration.ssh.user,
                port: configuration.ssh.port,
                identityFile: configuration.ssh.identityFile
            )
        }
        do {
            try sshWriter.write(entries)
        } catch {
            generalError = VMErrorInfo(title: "Couldn't update the SSH configuration", message: error.localizedDescription)
        }
    }

    /// Adds or removes the `Include` line in `~/.ssh/config`.
    func setSSHIncludeInstalled(_ installed: Bool) {
        do {
            if installed {
                syncSSHConfiguration()
                try sshWriter.installInclude()
            } else {
                try sshWriter.removeInclude()
            }
        } catch {
            generalError = VMErrorInfo(title: "Couldn't change ~/.ssh/config", message: error.localizedDescription)
        }
        isSSHIncludeInstalled = sshWriter.isIncludeInstalled
    }

    /// The command that opens a shell in the guest, or `nil` if the machine has no SSH alias.
    func sshCommand(for machine: VirtualMachine) -> String? {
        let alias = machine.configuration.ssh.alias
        guard !alias.isEmpty, address(for: machine) != nil else { return nil }
        if isSSHIncludeInstalled {
            return "ssh \(alias)"
        }
        // Without the Include line, point ssh at the generated file explicitly.
        return "ssh -F \(Self.shellQuoted(sshWriter.generatedConfigURL.path)) \(alias)"
    }

    func copySSHCommand(for machine: VirtualMachine) {
        guard let command = sshCommand(for: machine) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Opens a terminal window connected to the guest.
    func openTerminal(for machine: VirtualMachine) {
        guard let command = sshCommand(for: machine) else { return }
        let alias = machine.configuration.ssh.alias
        if isSSHIncludeInstalled, let url = URL(string: "ssh://\(alias)") {
            // Goes to the user's default terminal app.
            NSWorkspace.shared.open(url)
            return
        }
        runInTerminal(["exec \(command)"], scriptName: "swiftvm-ssh-\(alias)")
    }

    /// The `swiftvm` tool that ships inside the app, if this build has one.
    var commandLineToolURL: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/swiftvm")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Opens a terminal window on the guest's serial console, which works without a network and before
    /// the guest has finished starting.
    func openSerialConsole(for machine: VirtualMachine) {
        guard let tool = commandLineToolURL else { return }
        var lines: [String] = []
        // A copy of the app that keeps its data elsewhere has to be told apart by the tool as well.
        if let home = ProcessInfo.processInfo.environment[VMLibrary.rootDirectoryEnvironmentKey], !home.isEmpty {
            lines.append("export \(VMLibrary.rootDirectoryEnvironmentKey)=\(Self.shellQuoted(home))")
        }
        lines.append("exec \(Self.shellQuoted(tool.path)) console \(machine.id.uuidString)")
        runInTerminal(lines, scriptName: "swiftvm-console-\(machine.id.uuidString.prefix(8))")
    }

    /// Runs shell commands in a new window of the user's terminal app.
    private func runInTerminal(_ lines: [String], scriptName: String) {
        let script = FileManager.default.temporaryDirectory.appending(path: "\(scriptName).command")
        do {
            try (["#!/bin/zsh"] + lines).joined(separator: "\n").appending("\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            generalError = VMErrorInfo(title: "Couldn't open Terminal", message: error.localizedDescription)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Sets the clock of a guest that has just been resumed and thinks it is still the moment it was
    /// suspended. A guest with the agent has it set through the agent, by the machine itself. Without
    /// one, this works for Linux guests that let the host sign in and use `sudo`; others are left to
    /// their own time service.
    private func correctClock(of machine: VirtualMachine) {
        let configuration = machine.configuration
        guard configuration.os.family == .linux else { return }
        let alias = configuration.ssh.alias
        let configURL = sshWriter.generatedConfigURL
        Task {
            // An agent that is there answers at once, and it is known at once when there is none.
            guard await !machine.agent.waitUntilConnected(timeout: .seconds(2)), !alias.isEmpty else { return }
            await Task.detached(priority: .utility) {
                // The guest's network needs a moment to notice it is back.
                for _ in 0..<5 {
                    if (try? GuestClock.setFromHardwareClock(on: alias, configURL: configURL)) != nil { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }.value
        }
    }

    // MARK: Machines

    /// An SSH alias derived from `name` that no other machine uses.
    func uniqueAlias(for name: String) -> String {
        let taken = Set(library.machines.map(\.configuration.ssh.alias))
        return SSHAlias.unique(SSHAlias.slug(from: name), avoiding: taken)
    }

    /// Whether a machine or an in-progress creation already uses `name`.
    func isNameTaken(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return library.machines.contains { $0.name.lowercased() == lowered }
            || creations.contains { $0.name.lowercased() == lowered }
    }

    /// Asks the guest to shut down, or to restart once it has.
    ///
    /// A guest with the guest tools just does it. macOS without them answers with a dialog on its own
    /// screen, so the machine's window is brought up for someone to see it. Without an answer the machine
    /// simply stays running.
    ///
    /// - Parameter activatingApp: Also bring the app forward for that dialog, for a request that was
    ///   made from outside the app's windows.
    @discardableResult
    func shutDown(_ machine: VirtualMachine, thenRestart: Bool = false, activatingApp: Bool = false) async -> ShutdownRequest? {
        let request = thenRestart ? await machine.restart() : await machine.shutDown()
        if request == .powerButton, machine.configuration.asksBeforeShuttingDown {
            if activatingApp {
                NSApp.activate()
            }
            showMachineWindow?(machine.id)
        }
        return request
    }

    /// The user has said how to quit with machines running. From here until the app is gone nothing
    /// starts and the command-line tool is turned down: a machine that came up now, or a snapshot that
    /// began, would be cut off by the quit.
    func closeDown() {
        isClosingDown = true
        library.allowsStarting = false
    }

    /// Shuts down the machines that are up because the app is about to quit, and returns when none is
    /// left running. Call ``closeDown()`` first.
    ///
    /// Running guests with the guest tools are asked through them and shut down properly; they get a
    /// moment for it, and so do guests that were already on their way down. Everything else is stopped
    /// outright: there is no telling how long another guest would take, or whether it would put up a
    /// question that nobody is going to answer.
    func shutDownForQuit(_ machines: [VirtualMachine], patience: Duration = .seconds(45)) async {
        for machine in machines where machine.state == .running && machine.agent.isConnected {
            await machine.shutDown()
        }
        // A macOS guest that was asked with the power button is waiting for an answer on its screen,
        // not shutting down. Its agent, had it one, would have been asked instead.
        func isOnItsWayDown(_ machine: VirtualMachine) -> Bool {
            machine.state == .stopping && (machine.agent.isConnected || !machine.configuration.asksBeforeShuttingDown)
        }
        let deadline = ContinuousClock.now + patience
        while machines.contains(where: isOnItsWayDown), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for machine in machines where machine.state.isActive {
            await machine.forceStop()
        }
    }

    func delete(_ machine: VirtualMachine) {
        let alias = machine.configuration.ssh.alias
        do {
            try library.remove(machine, movingToTrash: true)
            if !alias.isEmpty {
                sshWriter.forgetHostKey(for: alias)
            }
        } catch {
            generalError = VMErrorInfo(title: "Couldn't delete “\(machine.name)”", message: error.localizedDescription)
        }
    }

    func revealInFinder(_ machine: VirtualMachine) {
        NSWorkspace.shared.activateFileViewerSelecting([machine.bundle.url])
    }

    var activeMachines: [VirtualMachine] {
        library.machines.filter(\.state.isActive)
    }

    /// Whether a snapshot, a copy or a resize is under way on any machine.
    var isWorkingOnMachineFiles: Bool {
        library.machines.contains { $0.activity != nil }
    }

    /// Returns once no machine's files are being worked on. That work is short, and stopping the app in
    /// the middle of it could leave a machine half saved.
    func waitForWorkOnMachineFiles() async {
        while isWorkingOnMachineFiles {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Creations that are still working (not failed and waiting to be dismissed).
    var creationsInProgress: [MachineCreation] {
        creations.filter { $0.errorMessage == nil }
    }

    // MARK: Quitting

    /// Quits for the command-line tool, a moment from now so that the tool gets its answer first. Call it
    /// only when no machine is running.
    ///
    /// From here on nothing starts, and further requests from the tool are turned down. That is what
    /// makes it safe to quit without the dialog that asks what to do with running machines: none can
    /// have come up between the check and the quit.
    func quitUnattended() {
        isQuittingUnattended = true
        library.allowsStarting = false
        unattendedQuitTimer = AppDelegate.terminate(after: 0.2)
    }

    /// Goes back to normal after a quit for the command-line tool was called off.
    func cancelUnattendedQuit() {
        isQuittingUnattended = false
        isClosingDown = false
        library.allowsStarting = true
        unattendedQuitTimer?.invalidate()
        unattendedQuitTimer = nil
    }
}
