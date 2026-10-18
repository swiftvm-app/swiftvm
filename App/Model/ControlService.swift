import AppKit
import GuestChannel
import Installers
import QEMUEngine
import VMControl
import VMCore
import VZEngine
import Virtualization

/// Handles requests from the `swiftvm` command-line tool.
extension AppModel {
    func handle(_ request: ControlRequest) async -> ControlResponse {
        guard !isQuittingUnattended, !isClosingDown else { return .failure("\(AppIdentity.current.name) is quitting.") }
        switch request.command {
        case .list:
            if let identifier = request.machine {
                guard let machine = findMachine(identifier) else { return notFound(identifier) }
                return success(machine)
            }
            return ControlResponse(ok: true, machines: library.machines.map { summary(of: $0) })
        case .info:
            guard let identifier = request.machine else { return .failure("Missing machine name.") }
            guard let machine = findMachine(identifier) else { return notFound(identifier) }
            return details(machine)
        case .create:
            guard let parameters = request.create else { return .failure("Missing creation parameters.") }
            return await createMachine(parameters)
        case .usbList:
            guard usb.availability == .available else {
                return .failure(USBPassthrough.Failure.unavailable(usb.availability).localizedDescription)
            }
            let devices = usb.devices.map { summary(of: $0) }
            return ControlResponse(ok: true, note: devices.isEmpty ? USBDevicesHint.howToGiveOne : nil, usbDevices: devices)
        case .scripts:
            var distribution: LinuxDistribution?
            if let system = request.system {
                guard let found = DistributionCatalog.quickCreate.first(where: { $0.id == system.lowercased() }) else {
                    let available = DistributionCatalog.quickCreate.map(\.id).joined(separator: ", ")
                    return .failure("Unknown Linux image “\(system)”. Available: \(available).")
                }
                distribution = found
            }
            let listing = SetupScriptCatalog.listing()
            let scripts = listing.scripts.filter { script in distribution.map(script.supports) ?? true }.map { script in
                SetupScriptSummary(
                    id: script.id, name: script.name, summary: script.summary, category: script.category, systems: script.systems,
                    minimumMemoryGigabytes: script.minimumMemoryGigabytes, minimumDiskGigabytes: script.minimumDiskGigabytes,
                    isBuiltIn: script.origin == .builtIn
                )
            }
            // Where a script of one's own goes, and which of the files there aren't taken for one.
            let folder = (SetupScriptCatalog.userDirectory.path as NSString).abbreviatingWithTildeInPath
            let skipped = listing.skipped.map { "Not a setup script: \($0.fileName). \($0.reason)" }
            let note = (["Your own scripts go in \(folder)."] + skipped).joined(separator: "\n")
            return ControlResponse(ok: true, note: note, setupScripts: scripts)
        case .templates:
            // One may have been put in the folder by hand since it was last read.
            templates.load()
            return templatesResponse()
        case .deleteTemplate, .renameTemplate:
            guard let identifier = request.template else { return .failure("Missing template name.") }
            let newName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard request.command != .renameTemplate || !newName.isEmpty else {
                return .failure("Missing the template's new name.")
            }
            templates.load()
            do {
                let template = try findTemplate(identifier)
                if request.command == .renameTemplate {
                    try templates.rename(template, to: newName)
                } else {
                    try templates.remove(template, movingToTrash: true)
                }
            } catch {
                return .failure(error.localizedDescription)
            }
            return templatesResponse()
        case .quit:
            // Quitting from the command line never puts up the dialog that asks what to do with machines.
            guard activeMachines.isEmpty else {
                return .failure("Stop or suspend the running virtual machines first.")
            }
            let creating = creationsInProgress
            guard creating.isEmpty || request.cancelsCreations == true else {
                let subject = creating.count == 1 ? "“\(creating[0].name)” is" : "\(creating.count) virtual machines are"
                return .failure("\(subject) still being created. To quit anyway, use `swiftvm quit --cancel-creations`: a download carries on where it stopped the next time, an installation starts over.")
            }
            if let moving = machinesBeingMoved.first {
                return .failure("“\(moving.name)” is being moved to another folder. Wait until it is there, or call the move off in the machine's settings.")
            }
            if let saving = machinesBeingSavedAsTemplates.first {
                return .failure("“\(saving.name)” is being saved as a template. Wait until that is done.")
            }
            guard !isWorkingOnMachineFiles else {
                return .failure("A virtual machine is busy with a snapshot, a copy, a resize or a conversion of its disk. Try again in a moment.")
            }
            // macOS doesn't let an app quit while one of its windows has a sheet open or a panel waits
            // for an answer, and there is nobody here to close it: what is being filled in there would
            // be lost.
            guard NSApp.modalWindow == nil, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else {
                return .failure("\(AppIdentity.current.name) has a dialog open in one of its windows. Close it first.")
            }
            quitUnattended()
            return ControlResponse(ok: true)
        default:
            break
        }

        guard let identifier = request.machine else { return .failure("Missing machine name.") }
        guard let machine = findMachine(identifier) else { return notFound(identifier) }
        machine.lastError = nil

        switch request.command {
        case .start:
            await machine.start()
        case .stop:
            let request = await shutDown(machine)
            // The machine goes back to running when the guest doesn't act on the request.
            _ = await waitForState(of: machine, timeout: .seconds(90), where: { $0 != .stopping })
            guard machine.state == .stopped else {
                if request == .powerButton, machine.configuration.asksBeforeShuttingDown {
                    return .failure("“\(machine.name)” asks for confirmation on its screen before it shuts down, and nobody answered. Answer it in the machine's window, or use force-stop to stop it immediately.\(guestToolsHint(for: machine))")
                }
                return .failure("“\(machine.name)” didn't shut down in time. Use force-stop to stop it immediately.")
            }
        case .forceStop:
            await machine.forceStop()
        case .suspend:
            await machine.suspend()
        case .pause:
            await machine.pause()
        case .resume:
            await machine.resume()
        case .restart:
            guard machine.state == .running else { return .failure("“\(machine.name)” isn't running.") }
            let runs = machine.startCount
            let request = await shutDown(machine, thenRestart: true)
            // Wait for the guest to go down and come back up. Its state alone doesn't say: a guest that
            // shuts down at once is running again between two looks.
            let deadline = ContinuousClock.now + .seconds(150)
            while machine.startCount == runs || machine.state != .running {
                if machine.startCount == runs, machine.state == .running {
                    // Still the same run: the guest was asked and has let the request pass.
                    if request == .powerButton, machine.configuration.asksBeforeShuttingDown {
                        return .failure("“\(machine.name)” asks for confirmation on its screen before it restarts, and nobody answered. Answer it in the machine's window.\(guestToolsHint(for: machine))")
                    }
                    return .failure("“\(machine.name)” didn't shut down in time, so it wasn't restarted.")
                }
                // It failed to start again, which the error says better than this could.
                guard machine.lastError == nil else { break }
                if machine.state == .stopped, !machine.isRestartPending {
                    // The guest couldn't be asked and was stopped outright, which is no restart.
                    return .failure("“\(machine.name)” was stopped and didn't start again.")
                }
                guard ContinuousClock.now < deadline else {
                    return .failure("“\(machine.name)” didn't come back up in time.")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        case .open:
            guard windows.showMachine(machine.id, activatingApp: false) else {
                return .failure("\(AppIdentity.current.name) has only just opened and can't show a window yet. Try again in a moment.")
            }
        case .delete:
            guard !machine.state.isActive else { return .failure("Stop “\(machine.name)” before deleting it.") }
            let summary = summary(of: machine)
            delete(machine)
            if let error = generalError {
                generalError = nil
                return .failure(error.message)
            }
            return ControlResponse(ok: true, machines: [summary])
        case .share:
            guard let share = request.share else { return .failure("Missing folder path.") }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: share.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure("“\(share.path)” isn't a folder.")
            }
            changeConfiguration(of: machine) { configuration in
                if let index = configuration.sharedFolders.firstIndex(where: { $0.path == share.path }) {
                    configuration.sharedFolders[index].readOnly = share.readOnly
                } else {
                    let name = URL(fileURLWithPath: share.path).lastPathComponent
                    configuration.sharedFolders.append(SharedFolder(name: name, path: share.path, readOnly: share.readOnly))
                }
            }
        case .unshare:
            guard let share = request.share else { return .failure("Missing folder path.") }
            guard machine.configuration.sharedFolders.contains(where: { $0.path == share.path }) else {
                return .failure("“\(share.path)” isn't shared with “\(machine.name)”.")
            }
            changeConfiguration(of: machine) { $0.sharedFolders.removeAll { $0.path == share.path } }
        case .attach:
            guard let drive = request.drive else { return .failure("Missing disk image.") }
            do {
                try await machine.attachImage(RemovableImage(url: URL(fileURLWithPath: drive.path), readOnly: drive.readOnly))
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .eject:
            guard let drive = request.drive else { return .failure("Missing disk image.") }
            let images = machine.configuration.removableImages
            // A full path names one image; a bare file name is enough when only one image has it.
            let matches = drive.path.contains("/")
                ? images.filter { $0.path == drive.path }
                : images.filter { $0.name == drive.path }
            guard let image = matches.first else {
                return .failure("“\(drive.path)” isn't attached to “\(machine.name)”.")
            }
            guard matches.count == 1 else {
                return .failure("More than one attached image is called “\(drive.path)”. Give its full path.")
            }
            do {
                try await machine.ejectImage(image.id)
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .forward:
            guard let parameters = request.forward else { return .failure("Missing port.") }
            let forward = PortForward(
                transport: parameters.udp ? .udp : .tcp, hostPort: parameters.hostPort,
                guestPort: parameters.guestPort ?? parameters.hostPort, allowsOtherDevices: parameters.allowsOtherDevices
            )
            do {
                try addPortForward(forward, to: machine)
            } catch {
                return .failure(error.localizedDescription)
            }
            // For a running machine the port is opened right away; say so if that didn't work.
            if machine.state == .running {
                let deadline = ContinuousClock.now + .seconds(3)
                while portForwarder.statuses[forward.id] ?? .starting == .starting, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if case .failed(let reason) = portForwarder.statuses[forward.id] {
                    return .failure("The forward was added, but the port isn't open: \(reason) SwiftVM keeps trying while “\(machine.name)” runs.")
                }
            }
            return details(machine)
        case .unforward:
            guard let parameters = request.forward else { return .failure("Missing port.") }
            let transport: PortForward.TransportProtocol = parameters.udp ? .udp : .tcp
            let forwards = machine.configuration.networkInterfaces.flatMap(\.portForwards)
            guard let forward = forwards.first(where: { $0.hostPort == parameters.hostPort && $0.transport == transport }) else {
                return .failure("“\(machine.name)” doesn't forward \(transport.rawValue.uppercased()) port \(parameters.hostPort).")
            }
            do {
                try removePortForward(forward.id, from: machine)
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .plug, .unplug:
            guard !machine.configuration.networkInterfaces.isEmpty else {
                return .failure("“\(machine.name)” has no network interface.")
            }
            // In between states the change would be written down and not reach the guest.
            guard !machine.state.isTransitioning else {
                return .failure("“\(machine.name)” is busy starting up or shutting down. Try again in a moment.")
            }
            changeConfiguration(of: machine) { $0.networkInterfaces[0].isConnected = request.command == .plug }
        case .installTools:
            do {
                if request.usesDisc == true {
                    let disc = try await attachGuestToolsDisc(to: machine)
                    var response = details(machine)
                    let alias = machine.configuration.ssh.alias
                    if machine.configuration.os.family == .windows {
                        response.note = """
                            The guest tools disc and the drivers for virtual machines are plugged into “\(machine.name)”. \(guestToolsInstallCommand(for: machine)) Restart Windows afterwards, so that its display follows the window.
                            """
                        return response
                    }
                    response.note = """
                        The guest tools disc is plugged into “\(machine.name)”. To install from it, run this in the guest:

                            \(guestToolsInstallCommand(for: machine))

                        Afterwards, eject the disc: swiftvm eject \(alias.isEmpty ? machine.id.uuidString : alias) "\(disc.name)"
                        """
                    return response
                }
                try await installGuestTools(on: machine, password: request.password)
            } catch let error as ProcessRunner.Failure {
                if let complaint = LinuxGuestAgent.installerComplaint(in: error) {
                    // The installer ran and gave up; from the disc it would give up the same way.
                    return .failure("The guest tools couldn't be installed in “\(machine.name)”: \(complaint).")
                }
                // What went wrong is in the last thing that was said: ssh and sudo lead up to it.
                let reason = error.output.standardError.split(whereSeparator: \.isNewline).last
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let detail = reason.isEmpty ? "" : " (\(reason))"
                if machine.configuration.os.family == .macOS {
                    let advice = request.password == nil
                        ? "Give the password with --password <password>, or install from inside the guest with `swiftvm install-tools <machine> --disc`."
                        : "To install from inside the guest instead, use `swiftvm install-tools <machine> --disc`."
                    return .failure("The guest tools couldn't be installed over SSH, which takes key sign-in and the account's password\(detail). \(advice)")
                }
                return .failure("The guest tools couldn't be installed over SSH, which takes key sign-in and sudo without a password\(detail). To install from inside the guest instead, use `swiftvm install-tools <machine> --disc`.")
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .shareClipboard:
            guard let isOn = request.isOn else { return .failure("Missing on or off.") }
            guard machine.configuration.os.family != .linux || machine.configuration.engine == .virtualization else {
                return .failure("“\(machine.name)” has graphics acceleration, which doesn't share the clipboard yet.")
            }
            // A Linux guest shares the clipboard through a device, which like all hardware is there
            // from the start or not at all. The agent of a macOS or Windows guest is simply told, or no
            // longer told.
            guard machine.configuration.os.family != .linux || machine.state == .stopped
                || machine.configuration.clipboard.isShared == isOn
            else {
                return .failure("Shut down “\(machine.name)” first: this guest shares the clipboard through a device, which can't be added or taken away while it is up or suspended.")
            }
            changeConfiguration(of: machine) { $0.clipboard.isShared = isOn }
            if machine.lastError == nil {
                return details(machine)
            }
        case .usbAttach, .usbDetach, .usbAuto:
            guard let wanted = request.usbDevice, !wanted.isEmpty else { return .failure("Missing USB device.") }
            do {
                switch request.command {
                case .usbAttach:
                    // In a copy that has no USB devices at all, that says more than "no such device".
                    guard usb.availability == .available else { throw USBPassthrough.Failure.unavailable(usb.availability) }
                    try await usb.attach(try findUSBDevice(wanted, among: usb.devices, preferringFree: true), to: machine)
                case .usbDetach:
                    guard !machine.usbDevices.matching(wanted).isEmpty else {
                        return .failure("“\(wanted)” isn't attached to “\(machine.name)”.")
                    }
                    try await usb.detach(try findUSBDevice(wanted, among: machine.usbDevices), from: machine)
                default:
                    guard let isOn = request.isOn else { return .failure("Missing on or off.") }
                    let rules = machine.configuration.usb.autoConnect
                    if !isOn, let rule = rules.first(where: { $0.id == wanted.lowercased() || $0.name.lowercased() == wanted.lowercased() }) {
                        // A rule can be taken back while its device is somewhere else.
                        try machine.updateConfiguration { $0.usb.autoConnect.removeAll { $0.id == rule.id } }
                    } else {
                        guard usb.availability == .available else { throw USBPassthrough.Failure.unavailable(usb.availability) }
                        let device = try findUSBDevice(wanted, among: usb.devices, anyOfOneMake: true)
                        try usb.setConnectsAutomatically(isOn, device, to: machine)
                        if isOn, machine.state == .running {
                            // The machine takes a device that is free a moment from now. Wait for that,
                            // so that the answer shows it.
                            let deadline = ContinuousClock.now + .seconds(2)
                            while usb.devices.contains(where: { $0.id == device.id }), usb.holder(of: device.id) == nil,
                                  ContinuousClock.now < deadline {
                                try? await Task.sleep(for: .milliseconds(50))
                            }
                        }
                    }
                }
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .automation:
            guard let isOn = request.isOn else { return .failure("Missing on or off.") }
            changeConfiguration(of: machine) { $0.automation.isAllowed = isOn }
            if machine.lastError == nil {
                return details(machine)
            }
        case .allowAccessibility:
            guard let password = request.password, !password.isEmpty else {
                return .failure("macOS takes this from someone who knows the account's password. Give it with --password <password>.")
            }
            do {
                try await allowAccessibility(on: machine, password: password)
            } catch {
                return .failure(Self.explanation(of: error, for: machine))
            }
            return details(machine)
        case .wait:
            if let problem = await waitForGuestTools(of: machine, timeout: request.waitTimeout) {
                return .failure(problem)
            }
        case .discardState:
            guard machine.state == .suspended else { return .failure("“\(machine.name)” isn't suspended.") }
            machine.discardSavedState()
        case .compression:
            guard let isOn = request.isOn else { return .failure("Missing on or off.") }
            do {
                try await setDiskCompression(of: machine, enabled: isOn)
            } catch is CancellationError {
                return .failure("Converting the disk of “\(machine.name)” was called off. It is as it was.")
            } catch {
                return .failure(error.localizedDescription)
            }
        case .resize:
            guard let gigabytes = request.diskGigabytes, gigabytes > 0 else { return .failure("Missing disk size.") }
            guard gigabytes <= HostResources.maximumDiskGigabytes else {
                return .failure("\(gigabytes) GB is more than a disk can have (\(HostResources.maximumDiskGigabytes) GB). The size is in GB.")
            }
            do {
                try await resizeDisk(of: machine, to: UInt64(gigabytes) * HostResources.gibibyte)
            } catch {
                return .failure(error.localizedDescription)
            }
        case .clone:
            do {
                return success(try await duplicate(machine, named: request.name))
            } catch {
                return .failure(error.localizedDescription)
            }
        case .move:
            guard let location = request.location, location.hasPrefix("/") else { return .failure("Missing the folder to move to.") }
            do {
                try await move(machine, to: URL(fileURLWithPath: location, isDirectory: true))
            } catch is CancellationError {
                return .failure("Moving “\(machine.name)” was called off. It is where it was.")
            } catch {
                return .failure(error.localizedDescription)
            }
            return details(machine)
        case .snapshot:
            do {
                try await machine.takeSnapshot(named: request.name)
            } catch {
                return .failure(error.localizedDescription)
            }
            // The guest is resumed afterwards; if that failed, say so rather than report success.
            if let error = machine.lastError {
                machine.lastError = nil
                return .failure("The snapshot was taken, but: \(error.title): \(error.message)")
            }
            return snapshots(of: machine)
        case .snapshots:
            return snapshots(of: machine)
        case .revert, .deleteSnapshot, .renameSnapshot:
            guard let identifier = request.snapshot else { return .failure("Missing snapshot name.") }
            let newName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard request.command != .renameSnapshot || !newName.isEmpty else {
                return .failure("Missing the snapshot's new name.")
            }
            let found = findSnapshot(identifier, of: machine)
            guard case .success(let snapshot) = found else {
                if case .failure(let problem) = found { return .failure(problem.message) }
                return .failure("No such snapshot.")
            }
            do {
                if request.command == .revert {
                    try await machine.revert(to: snapshot)
                } else if request.command == .renameSnapshot {
                    try machine.renameSnapshot(snapshot, to: newName)
                    return snapshots(of: machine)
                } else {
                    try machine.deleteSnapshot(snapshot)
                    return snapshots(of: machine)
                }
            } catch {
                return .failure(error.localizedDescription)
            }
        case .saveTemplate:
            var snapshot: VMSnapshot?
            if let identifier = request.snapshot {
                switch findSnapshot(identifier, of: machine) {
                case .success(let found): snapshot = found
                case .failure(let problem): return .failure(problem.message)
                }
            }
            do {
                try await saveTemplate(of: machine, at: snapshot, named: request.name)
            } catch is CancellationError {
                return .failure("Saving “\(machine.name)” as a template was called off.")
            } catch {
                return .failure(error.localizedDescription)
            }
            return templatesResponse()
        case .list, .info, .console, .vsock, .job, .create, .quit, .usbList, .scripts, .templates, .deleteTemplate, .renameTemplate:
            break
        }

        // The command-line caller gets the error, so don't also raise an alert in the app.
        if let error = machine.lastError {
            machine.lastError = nil
            return .failure("\(error.title): \(error.message)")
        }
        return success(machine)
    }

    // MARK: Streams

    /// Answers a request that turns its connection into a byte stream. With a yes comes what serves the
    /// stream once the answer has gone out.
    func openStream(_ request: ControlRequest) async -> (response: ControlResponse, stream: ControlServer.Stream?) {
        guard !isQuittingUnattended, !isClosingDown else { return (.failure("\(AppIdentity.current.name) is quitting."), nil) }
        guard let identifier = request.machine else { return (.failure("Missing machine name."), nil) }
        guard let machine = findMachine(identifier) else { return (notFound(identifier), nil) }
        switch request.command {
        case .console:
            let (console, name) = (machine.console, machine.name)
            return (success(machine), { connection in await Self.serveConsole(console, name: name, connection: connection) })
        case .vsock:
            guard let port = request.port, port > 0 else { return (.failure("Missing port."), nil) }
            // The agent serves one connection, the app's. Another one would take its place. And what
            // the guest tools do in the guest is asked for by name, where it can be turned off.
            guard port != GuestAgent.port, port != GuestProtocol.jobPort else {
                return (.failure("Port \(port) is the line between SwiftVM and the guest tools, and not for anything else."), nil)
            }
            do {
                let guest = try await machine.connectToGuest(port: port)
                return (success(machine), { connection in
                    await ByteRelay.run(between: connection, and: guest.fileDescriptor)
                    try? guest.close()
                })
            } catch let error as VMError {
                return (.failure(error.localizedDescription), nil)
            } catch {
                return (.failure("Nothing in “\(machine.name)” answers on port \(port) of its socket device. (\(error.localizedDescription))"), nil)
            }
        case .job:
            guard var job = request.job else { return (.failure("Missing what to do in the guest."), nil) }
            // A command runs as the machine's own account unless another is named. Without either, the
            // guest tools take whoever is logged in at the guest's screen.
            if case .exec(var exec) = job, exec.user == nil, !machine.configuration.ssh.user.isEmpty {
                exec.user = machine.configuration.ssh.user
                job = .exec(exec)
            }
            // The screen, the mouse and the keyboard of a macOS guest, or of a guest on QEMU, are the
            // machine's own, and the app has those: no agent is asked, and nothing in the guest has to
            // allow it.
            if machine.doesItself(job) {
                guard machine.configuration.automation.isAllowed else {
                    return (.failure(Self.explanation(of: GuestJobError.notAllowed(name: machine.name), for: machine)), nil)
                }
                guard machine.state == .running else { return (.failure(VMError.notRunning(name: machine.name).localizedDescription), nil) }
                return (success(machine), { [job] connection in await Self.carryOut(job, in: machine, connection: connection) })
            }
            do {
                let guest = try await machine.openJob(job)
                return (success(machine), { connection in
                    // The tool only stops sending by going away, which calls the job off. An agent
                    // that doesn't hang up after that is hung up on.
                    await ByteRelay.run(between: connection, and: guest.fileDescriptor, patienceAfterFirstEnds: Self.jobCallOffPatience)
                    try? guest.close()
                })
            } catch {
                return (.failure(Self.explanation(of: error, for: machine)), nil)
            }
        default:
            return (.failure("This command doesn't open a stream."), nil)
        }
    }

    /// How long a guest's agent gets to end a job that was called off, before the app closes the line.
    private static let jobCallOffPatience: TimeInterval = 15

    /// Does a job that the app does itself, and tells the tool what came of it the way an agent would:
    /// what the job is for, and then how it ended.
    private nonisolated static func carryOut(_ job: GuestJob, in machine: VirtualMachine, connection: Int32) async {
        let output: Data
        let end: JobEnd
        do {
            output = try await machine.carryOut(job)
            end = .success
        } catch {
            output = Data()
            end = .failure(await explanation(of: error, for: machine))
        }
        // Writing waits for the tool to read, and holds a thread of its own for that.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                if output.isEmpty || JobFrame.write(.output, output, to: connection) {
                    JobFrame.write(.end, JobFrame.end(end).payload, to: connection)
                }
                // The tool hangs up once it has read how the job ended. Closing before that could
                // take the end with it. The connection itself is closed by whoever handed it over.
                shutdown(connection, SHUT_WR)
                var waiting = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                var rest = [UInt8](repeating: 0, count: 4096)
                let deadline = Date().addingTimeInterval(5)
                while deadline.timeIntervalSinceNow > 0 {
                    let ready = poll(&waiting, 1, Int32(max(deadline.timeIntervalSinceNow, 0) * 1000))
                    if ready < 0, errno == EINTR { continue }
                    guard ready > 0, read(connection, &rest, rest.count) > 0 else { break }
                }
                continuation.resume()
            }
        }
    }

    /// Why a job wasn't started, with what whoever is at the terminal can do about it.
    private static func explanation(of error: any Error, for machine: VirtualMachine) -> String {
        let alias = machine.configuration.ssh.alias
        let name = alias.isEmpty ? machine.id.uuidString : alias
        let advice: String? = switch error as? GuestJobError {
        case .notAllowed: "Turn it on in the machine's settings, or with `swiftvm automation \(name) on`."
        case .noAgent: "`swiftvm wait \(name)` waits for them, and `swiftvm install-tools \(name)` installs them."
        case .notOffered: "Update them with `swiftvm install-tools \(name)`."
        case .noAnswer, .tooLong, .refused, nil: nil
        }
        // A guest turns its display off after a while without input, and any key turns it on again.
        let wakes = error as? MachineDeskError == .nothingShown ? "A key wakes a display that went to sleep: `swiftvm ui \(name) key shift`." : nil
        return [error.localizedDescription, advice, wakes].compactMap { $0 }.joined(separator: " ")
    }

    /// Waits until the guest tools of a machine that is up, or coming up, have answered. Returns what
    /// is in the way if they don't.
    private func waitForGuestTools(of machine: VirtualMachine, timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while !machine.agent.isConnected {
            // A machine that is down isn't on its way to answering anything.
            guard machine.state.isActive, machine.state != .stopping, machine.state != .suspending else {
                return "“\(machine.name)” isn't running."
            }
            guard ContinuousClock.now < deadline else {
                return "The guest tools in “\(machine.name)” haven't answered in time. If they aren't installed, `swiftvm install-tools` installs them."
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Connects a `swiftvm console` session to a machine's serial console and returns when the tool hangs
    /// up. Like a cable, the session survives the machine being stopped and started.
    private nonisolated static func serveConsole(_ console: SerialConsole, name: String, connection: Int32) async {
        let writer = ConsoleClientWriter(descriptor: connection)
        let token = console.addListener { event in
            switch event {
            case .output(let data):
                writer.write(data)
            case .connectionChanged(let isConnected):
                writer.write(Data("\r\n[“\(name)” \(isConnected ? "is starting" : "has stopped")]\r\n".utf8))
            }
        }
        if !console.isConnected {
            writer.write(Data("[“\(name)” isn't running. The console comes to life when it starts.]\r\n".utf8))
        }

        // What is typed goes to the guest. This holds a thread, not the main actor, until the tool leaves.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(connection, &buffer, buffer.count)
                    if count > 0 {
                        console.send(Data(buffer[0..<count]))
                    } else if count == 0 || errno != EINTR {
                        break
                    }
                }
                continuation.resume()
            }
        }
        console.removeListener(token)
        // The connection is closed after this returns; nothing may be written to its number any more.
        writer.close()
    }

    // MARK: Creating

    private func createMachine(_ parameters: ControlRequest.CreateParameters) async -> ControlResponse {
        if let template = parameters.template {
            return await createMachine(fromTemplate: template, parameters)
        }
        if parameters.distribution == ControlRequest.CreateParameters.windows {
            return await createWindowsMachine(parameters)
        }
        let isMac = parameters.distribution == ControlRequest.CreateParameters.macOS
        let distribution = DistributionCatalog.quickCreate.first { $0.id == parameters.distribution }
        guard isMac || distribution != nil else {
            let systems = [ControlRequest.CreateParameters.macOS, ControlRequest.CreateParameters.windows] + DistributionCatalog.quickCreate.map(\.id)
            return .failure("Unknown system “\(parameters.distribution)”. Available: \(systems.joined(separator: ", ")).")
        }
        if parameters.installerPath != nil {
            return .failure("--iso is for Windows. Linux installs from its image, and macOS from a restore image (--ipsw).")
        }
        let family: GuestFamily = isMac ? .macOS : .linux
        var setupScripts: [SetupScript] = []
        if let asked = parameters.scripts, !asked.isEmpty {
            guard let distribution else { return .failure("A setup script is for a Linux image, not for macOS.") }
            do {
                setupScripts = try SetupScriptCatalog.scripts(for: asked, distribution: distribution)
            } catch SetupScript.ScriptError.unknown(let name, let system, let available) {
                return .failure(SetupScript.ScriptError.unknown(name: name, system: system, available: available).localizedDescription)
            } catch {
                return .failure("Couldn't read the setup script: \(error.localizedDescription)")
            }
            if let desktop = setupScripts.first(where: \.requiresPassword), (parameters.password ?? "").isEmpty {
                return .failure("\(desktop.name) is a desktop, which needs a password to sign in with at its login screen. Add --password <password>.")
            }
        }
        var name = parameters.name ?? distribution?.name.replacingOccurrences(of: " LTS", with: "") ?? "macOS"
        if parameters.name == nil {
            let base = name
            var counter = 2
            while isNameTaken(name) {
                name = "\(base) \(counter)"
                counter += 1
            }
        } else if isNameTaken(name) {
            return .failure("A virtual machine named “\(name)” already exists.")
        }
        // Sizes are in GB. One typed in bytes would overflow further down.
        if let memory = parameters.memoryGigabytes, !(1...Int(HostResources.memorySize / HostResources.gibibyte)).contains(memory) {
            return .failure("\(memory) GB of memory is more than this Mac has. The size is in GB.")
        }
        if let disk = parameters.diskGigabytes, !(1...HostResources.maximumDiskGigabytes).contains(disk) {
            return .failure("\(disk) GB is more than a disk can have (\(HostResources.maximumDiskGigabytes) GB). The size is in GB.")
        }
        let cpuCount = parameters.cpuCount ?? HostResources.recommendedCPUCount(for: family)
        // What nobody asked for by number is at least what the setup scripts need.
        let memorySize = parameters.memoryGigabytes.map { UInt64($0) * HostResources.gibibyte }
            ?? max(HostResources.recommendedMemorySize(for: family), UInt64(setupScripts.minimumMemoryGigabytes ?? 0) * HostResources.gibibyte)
        let diskCapacity = parameters.diskGigabytes.map { UInt64($0) * HostResources.gibibyte }
            ?? max(HostResources.recommendedDiskCapacity(for: family), UInt64(setupScripts.minimumDiskGigabytes ?? 0) * HostResources.gibibyte)
        if let distribution, let problem = setupScripts.problem(for: distribution, memorySize: memorySize, diskCapacity: diskCapacity) {
            return .failure(problem)
        }
        let location: URL?
        do {
            location = try creationFolder(at: parameters.location)
        } catch {
            return .failure(error.localizedDescription)
        }
        let installsSSHKey = parameters.installsSSHKey ?? true
        let usesRosetta = parameters.rosetta ?? false
        if usesRosetta {
            guard !isMac else { return .failure("Rosetta is for Linux guests. A macOS guest runs x86-64 programs by itself.") }
            guard VZLinuxRosettaDirectoryShare.availability == .installed else {
                return .failure("Rosetta isn't installed on this Mac. Install it with: softwareupdate --install-rosetta")
            }
        }

        if isMac, parameters.acceleratesGraphics != nil {
            return .failure("--gpu and --no-gpu are for Linux guests. A macOS guest draws with this Mac's GPU by itself.")
        }
        let acceleratesGraphics = parameters.acceleratesGraphics ?? false
        if acceleratesGraphics {
            guard !usesRosetta else { return .failure("A machine with --gpu runs on QEMU, which has no Rosetta. Leave out --gpu to use Rosetta, or --rosetta to use the GPU.") }
            guard qemuProvider?.canAccelerateGraphics == true else {
                return .failure("Graphics acceleration needs QEMU with OpenGL, which this copy of SwiftVM was built without.")
            }
        }

        let compressesDisk = parameters.compressed ?? false
        if compressesDisk, isMac {
            return .failure("The disk of a macOS machine can't be kept compressed: its files are compressed already.")
        }

        let start: () -> MachineCreation
        if let distribution {
            // A name that was asked for has to be one Linux takes. Without one, the Mac user's is made to fit.
            let userName = parameters.user ?? CloudInitSeed.userName(from: NSUserName())
            if let problem = CloudInitSeed.problem(withUserName: userName) {
                return .failure("“\(userName)” can't be the user name. \(problem)")
            }
            if !installsSSHKey, (parameters.password ?? "").isEmpty {
                return .failure("Without your SSH key the account needs a password, otherwise nobody can sign in. Add --password <password>.")
            }
            let request = LinuxQuickCreateRequest(
                name: name,
                distribution: distribution,
                cpuCount: cpuCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity,
                userName: userName,
                fullName: NSFullUserName(),
                password: parameters.password ?? "",
                installsSSHKey: installsSSHKey,
                rosetta: usesRosetta,
                compressesDisk: compressesDisk,
                acceleratesGraphics: acceleratesGraphics,
                setupScripts: setupScripts,
                location: location
            )
            start = { self.create(request) }
        } else {
            var image: MacRestoreImage?
            if let path = parameters.restoreImagePath {
                do {
                    image = try await MacRestoreImage.load(from: URL(fileURLWithPath: path))
                } catch {
                    return .failure("Couldn't read the restore image: \(error.localizedDescription)")
                }
            }
            // Without an image the latest macOS is installed, which sets up the account by itself.
            var account: GuestProvisioning?
            if image?.supportsProvisioning ?? true {
                let userName = parameters.user ?? NSUserName()
                if let problem = GuestProvisioning.problem(withUserName: userName) {
                    return .failure("“\(userName)” can't be the account name. \(problem)")
                }
                guard let password = parameters.password, !password.isEmpty else {
                    return .failure("macOS needs a password for the account. Add --password <password>.")
                }
                // Without the key nothing signs in over SSH by itself, so Remote Login stays off, as it
                // does when the form is told the same.
                let provisioning = GuestProvisioning(
                    fullName: NSFullUserName(), userName: userName, password: password, enablesRemoteLogin: installsSSHKey
                )
                do {
                    try provisioning.validateForMacOS()
                } catch {
                    return .failure("macOS can't create that account: \(error.localizedDescription)")
                }
                account = provisioning
            }
            let request = MacInstallRequest(
                name: name,
                image: image,
                cpuCount: cpuCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity,
                account: account,
                installsSSHKey: installsSSHKey,
                location: location
            )
            start = { self.create(request) }
        }
        return await finishCreating(named: name, starting: parameters.start, start)
    }

    /// Installs Windows into a new machine, from Microsoft's download or the disc that `--iso` names.
    private func createWindowsMachine(_ parameters: ControlRequest.CreateParameters) async -> ControlResponse {
        guard parameters.scripts == nil else { return .failure("Setup scripts are for Linux machines.") }
        guard parameters.rosetta == nil else { return .failure("Rosetta is for Linux guests. Windows on Arm runs x86-64 programs by itself.") }
        guard parameters.restoreImagePath == nil else { return .failure("--ipsw is for macOS. Windows installs from an ISO, with --iso.") }
        guard qemuProvider?.isAvailable == true else { return .failure(QEMUError.notInstalled.localizedDescription) }
        let canAccelerateGraphics = qemuProvider?.canAccelerateWindowsGraphics == true
        if parameters.acceleratesGraphics == true, !canAccelerateGraphics {
            return .failure("This copy of SwiftVM can't give Windows the Mac's GPU: its QEMU was built without Direct3D. Leave out --gpu.")
        }
        var name = parameters.name ?? "Windows 11"
        if parameters.name == nil {
            let base = name
            var counter = 2
            while isNameTaken(name) {
                name = "\(base) \(counter)"
                counter += 1
            }
        } else if isNameTaken(name) {
            return .failure("A virtual machine named “\(name)” already exists.")
        }
        if let memory = parameters.memoryGigabytes, !(4...Int(HostResources.memorySize / HostResources.gibibyte)).contains(memory) {
            return .failure("Windows needs 4 GB of memory or more, and no more than this Mac has. The size is in GB.")
        }
        if let disk = parameters.diskGigabytes, !(64...HostResources.maximumDiskGigabytes).contains(disk) {
            return .failure("A Windows disk can be from 64 GB to \(HostResources.maximumDiskGigabytes) GB. The size is in GB.")
        }
        let userName = parameters.user ?? (WindowsSetup.problem(withUserName: NSUserName()) == nil ? NSUserName() : "user")
        if let problem = WindowsSetup.problem(withUserName: userName) {
            return .failure("“\(userName)” can't be the account name. \(problem)")
        }
        guard let password = parameters.password, WindowsSetup.problem(withPassword: password) == nil else {
            return .failure("Windows needs a password for the account. Add --password <password>.")
        }
        var media = WindowsInstallRequest.Media.download
        if let path = parameters.installerPath {
            let url = URL(fileURLWithPath: path)
            do {
                _ = try await Task.detached(priority: .userInitiated) { try WindowsInstaller.inspect(url) }.value
            } catch {
                return .failure(error.localizedDescription)
            }
            media = .localFile(url)
        }
        let location: URL?
        do {
            location = try creationFolder(at: parameters.location)
        } catch {
            return .failure(error.localizedDescription)
        }
        let request = WindowsInstallRequest(
            name: name,
            media: media,
            cpuCount: parameters.cpuCount ?? HostResources.recommendedCPUCount(for: .windows),
            memorySize: parameters.memoryGigabytes.map { UInt64($0) * HostResources.gibibyte } ?? HostResources.recommendedMemorySize(for: .windows),
            diskCapacity: parameters.diskGigabytes.map { UInt64($0) * HostResources.gibibyte } ?? HostResources.recommendedDiskCapacity(for: .windows),
            userName: userName,
            fullName: NSFullUserName(),
            password: password,
            installsSSHKey: parameters.installsSSHKey ?? true,
            compressesDisk: parameters.compressed ?? false,
            acceleratesGraphics: parameters.acceleratesGraphics ?? canAccelerateGraphics,
            location: location
        )
        return await finishCreating(named: name, starting: parameters.start) { self.create(request) }
    }

    /// Makes a machine from a template, which brings its system, its account and whatever was set up
    /// in it. Its name, its hardware and where it is kept are the new machine's own.
    private func createMachine(fromTemplate identifier: String, _ parameters: ControlRequest.CreateParameters) async -> ControlResponse {
        guard parameters.user == nil, parameters.password == nil, parameters.restoreImagePath == nil,
              parameters.installerPath == nil, parameters.scripts == nil, parameters.rosetta == nil,
              parameters.installsSSHKey == nil, parameters.compressed == nil, parameters.acceleratesGraphics == nil
        else {
            return .failure("A machine made from a template keeps the template's system and account. Only its name, processors, memory, disk size and folder can be set.")
        }
        templates.load()
        let template: VMTemplate
        do {
            template = try findTemplate(identifier)
        } catch {
            return .failure(error.localizedDescription)
        }
        let name = parameters.name ?? nameForMachine(from: template)
        if parameters.name != nil, isNameTaken(name) {
            return .failure("A virtual machine named “\(name)” already exists.")
        }
        // Sizes are in GB. One typed in bytes would overflow further down.
        if let memory = parameters.memoryGigabytes, !(1...Int(HostResources.memorySize / HostResources.gibibyte)).contains(memory) {
            return .failure("\(memory) GB of memory is more than this Mac has. The size is in GB.")
        }
        var diskCapacity: UInt64?
        if let disk = parameters.diskGigabytes {
            guard (1...HostResources.maximumDiskGigabytes).contains(disk) else {
                return .failure("\(disk) GB is more than a disk can have (\(HostResources.maximumDiskGigabytes) GB). The size is in GB.")
            }
            let capacity = UInt64(disk) * HostResources.gibibyte
            let current = template.configuration.systemDisk?.capacity ?? 0
            guard capacity >= current else {
                return .failure("The template's disk is \(Formatting.bytes(current)). A disk can grow, but it can't shrink.")
            }
            diskCapacity = capacity > current ? capacity : nil
        }
        let location: URL?
        do {
            location = try creationFolder(at: parameters.location)
        } catch {
            return .failure(error.localizedDescription)
        }
        let request = TemplateCreateRequest(
            name: name, template: template, cpuCount: parameters.cpuCount,
            memorySize: parameters.memoryGigabytes.map { UInt64($0) * HostResources.gibibyte },
            diskCapacity: diskCapacity, location: location
        )
        return await finishCreating(named: name, starting: parameters.start) { self.create(request) }
    }

    /// The folder a machine is to be created in, made sure that it can be kept there. `nil` is the folder
    /// for new machines.
    private func creationFolder(at path: String?) throws -> URL? {
        guard let path else { return nil }
        guard path.hasPrefix("/") else {
            throw VMError.invalidConfiguration("The folder to keep the machine in has to be given from the root.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try library.prepareFolder(folder)
        return folder
    }

    /// Has `start` create the machine called `name`, waits until it is in the library, starts it if
    /// that was asked for, and answers for all of it.
    private func finishCreating(named name: String, starting startsMachine: Bool, _ start: () -> MachineCreation) async -> ControlResponse {
        // A quit may have been agreed to while the restore image was being read.
        guard !isQuittingUnattended else { return .failure("\(AppIdentity.current.name) is quitting.") }
        let result: Result<VirtualMachine, any Error> = await withCheckedContinuation { continuation in
            let creation = start()
            creation.onFinish = { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let machine):
            if startsMachine {
                guard !isQuittingUnattended else {
                    return .failure("“\(machine.name)” was created but not started, because \(AppIdentity.current.name) is quitting.")
                }
                await machine.start()
                if let error = machine.lastError {
                    machine.lastError = nil
                    return .failure("\(error.title): \(error.message)")
                }
            }
            return success(machine)
        case .failure(let error):
            // The caller reports the failure; don't leave a failed row behind in the menu bar panel.
            creations.removeAll { $0.name == name && $0.errorMessage != nil }
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// What to add to the news that a guest asked on its screen instead of shutting down: with the
    /// guest tools it wouldn't have. Nothing for a guest that has them and whose agent didn't answer.
    private func guestToolsHint(for machine: VirtualMachine) -> String {
        machine.agent.isConnected ? "" : " With the guest tools it does so without asking: swiftvm install-tools."
    }

    /// Finds a machine by UUID, name or SSH alias (case-insensitive).
    func findMachine(_ identifier: String) -> VirtualMachine? {
        if let id = UUID(uuidString: identifier), let machine = library.machine(id: id) {
            return machine
        }
        let lowered = identifier.lowercased()
        return library.machines.first { $0.name.lowercased() == lowered }
            ?? library.machines.first { $0.configuration.ssh.alias == lowered }
    }

    private struct SnapshotLookupProblem: Error {
        var message: String
    }

    /// Finds a snapshot by UUID or by name (case-insensitive).
    private func findSnapshot(_ identifier: String, of machine: VirtualMachine) -> Result<VMSnapshot, SnapshotLookupProblem> {
        if let id = UUID(uuidString: identifier), let snapshot = machine.snapshots.first(where: { $0.id == id }) {
            return .success(snapshot)
        }
        let matches = machine.snapshots.filter { $0.name.lowercased() == identifier.lowercased() }
        guard let snapshot = matches.first else {
            return .failure(.init(message: "“\(machine.name)” has no snapshot named “\(identifier)”."))
        }
        guard matches.count == 1 else {
            return .failure(.init(message: "More than one snapshot is named “\(identifier)”. Use its ID from `swiftvm snapshots`."))
        }
        return .success(snapshot)
    }

    /// Finds a template by UUID or by name (case-insensitive).
    private func findTemplate(_ identifier: String) throws -> VMTemplate {
        if let id = UUID(uuidString: identifier), let template = templates.templates.first(where: { $0.id == id }) {
            return template
        }
        let matches = templates.templates.filter { $0.name.lowercased() == identifier.lowercased() }
        guard let template = matches.first else {
            throw VMError.invalidConfiguration(["No template named “\(identifier)”.", missingTemplatesFolderNote].compactMap { $0 }.joined(separator: " "))
        }
        guard matches.count == 1 else {
            throw VMError.invalidConfiguration("More than one template is named “\(identifier)”. Use its ID from `swiftvm templates`.")
        }
        return template
    }

    /// What to say when the folder that was chosen for templates isn't there, and none of them is listed.
    private var missingTemplatesFolderNote: String? {
        guard templates.isDirectoryMissing else { return nil }
        return "The folder for templates, \(templates.directory.abbreviatedPath), isn't there. If it is on an external disk, connect the disk."
    }

    private func templatesResponse() -> ControlResponse {
        ControlResponse(ok: true, note: missingTemplatesFolderNote, templates: templates.templates.map { template in
            TemplateSummary(
                id: template.id, name: template.name, createdAt: template.createdAt, system: template.configuration.os.summary,
                cpuCount: template.configuration.cpuCount, memorySize: template.configuration.memorySize,
                diskAllocated: templates.allocatedSize(of: template), diskCapacity: template.configuration.totalDiskCapacity
            )
        })
    }

    /// Finds the one USB device among `devices` that `text` names: by its number, its `vendor:product`,
    /// its serial number or its name.
    ///
    /// - Parameters:
    ///   - preferringFree: When several fit, take the one no guest has, if that is one.
    ///   - anyOfOneMake: When several of one make fit, any of them will do: what is asked for goes by make.
    private func findUSBDevice(
        _ text: String, among devices: [USBDevice], preferringFree: Bool = false, anyOfOneMake: Bool = false
    ) throws -> USBDevice {
        var matches = devices.matching(text)
        if matches.count > 1, preferringFree {
            let free = matches.filter { usb.holder(of: $0.id) == nil }
            if free.count == 1 {
                matches = free
            }
        }
        if anyOfOneMake, Set(matches.map(\.identifier)).count == 1 {
            matches = Array(matches.prefix(1))
        }
        guard let device = matches.first else {
            throw VMError.invalidConfiguration("No USB device “\(text)”. `swiftvm usb` lists the ones this Mac has given \(AppIdentity.current.name).")
        }
        guard matches.count == 1 else {
            throw VMError.invalidConfiguration("More than one USB device fits “\(text)”. Use its number from `swiftvm usb`.")
        }
        return device
    }

    private func summary(of device: USBDevice) -> USBDeviceSummary {
        USBDeviceSummary(
            id: device.id, name: device.name, identifier: device.identifier, manufacturer: device.manufacturer,
            serialNumber: device.serialNumber, machine: usb.holder(of: device.id)?.name
        )
    }

    private func snapshots(of machine: VirtualMachine) -> ControlResponse {
        ControlResponse(ok: true, machines: [summary(of: machine)], snapshots: machine.snapshots.map { snapshot in
            SnapshotSummary(id: snapshot.id, name: snapshot.name, createdAt: snapshot.createdAt, includesMemory: snapshot.includesMemory)
        })
    }

    private func details(_ machine: VirtualMachine) -> ControlResponse {
        let configuration = machine.configuration
        var summary = summary(of: machine)
        summary.details = MachineDetails(
            location: machine.bundle.url.path,
            macAddress: configuration.networkInterfaces.first?.macAddress,
            drives: configuration.removableImages.map { .init(path: $0.path, readOnly: $0.readOnly) },
            sharedFolders: configuration.sharedFolders.map { .init(name: $0.name, path: $0.path, readOnly: $0.readOnly) },
            forwards: configuration.networkInterfaces.flatMap(\.portForwards).map { forward in
                let status: String? = switch portForwarder.statuses[forward.id] {
                case .listening: "listening"
                case .starting: "starting"
                case .failed(let reason): reason
                case nil: nil
                }
                return .init(
                    hostPort: forward.hostPort, guestPort: forward.guestPort, udp: forward.transport == .udp,
                    allowsOtherDevices: forward.allowsOtherDevices, status: status
                )
            },
            snapshotCount: machine.snapshots.count,
            guestTools: MachineDetails.GuestTools(version: machine.agent.version, kernel: machine.agent.kernel),
            sharesClipboard: configuration.clipboard.isShared,
            usbDevices: machine.usbDevices.map { self.summary(of: $0) },
            usbAutoConnect: configuration.usb.autoConnect.map { "\($0.name) (\($0.id))" },
            // The step a script ended at says nothing once it has come to its end.
            setup: machine.agent.setup.map { .init(name: $0.name, state: $0.state.rawValue, step: $0.state == .finished ? nil : $0.step) },
            // Of what the agent says it does, the kinds of job this app knows: no other word of a
            // guest's is passed on. And what the app does itself, with or without an agent.
            automation: MachineDetails.Automation(
                isAllowed: configuration.automation.isAllowed,
                features: GuestFeature.jobs.filter(machine.does)
            )
        )
        return ControlResponse(ok: true, machines: [summary])
    }

    private func changeConfiguration(of machine: VirtualMachine, _ body: (inout VMConfiguration) -> Void) {
        do {
            try machine.updateConfiguration(body)
        } catch {
            machine.lastError = VMErrorInfo(title: "Couldn't change “\(machine.name)”", message: error.localizedDescription)
        }
    }

    private func waitForState(of machine: VirtualMachine, timeout: Duration, where condition: (VMState) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(machine.state) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    private func summary(of machine: VirtualMachine) -> MachineSummary {
        machine.refreshDiskUsage()
        let configuration = machine.configuration
        return MachineSummary(
            id: machine.id,
            name: machine.name,
            state: machine.state.rawValue,
            system: configuration.os.summary,
            family: configuration.os.family.rawValue,
            address: address(for: machine),
            sshAlias: configuration.ssh.alias.isEmpty ? nil : configuration.ssh.alias,
            cpuCount: configuration.cpuCount,
            memorySize: configuration.memorySize,
            diskAllocated: machine.allocatedDiskSize,
            diskCapacity: configuration.totalDiskCapacity
        )
    }

    private func success(_ machine: VirtualMachine) -> ControlResponse {
        ControlResponse(ok: true, machines: [summary(of: machine)])
    }

    private func notFound(_ identifier: String) -> ControlResponse {
        let lowered = identifier.lowercased()
        if let away = library.unavailableMachines.first(where: { $0.name.lowercased() == lowered || $0.sshAlias == lowered }) {
            return .failure(away.explanation)
        }
        return .failure("No virtual machine named “\(identifier)”.")
    }
}

/// Writes console output to one `swiftvm console` session without ever holding up the guest: the writes
/// queue up behind a slow terminal instead. A terminal that has stopped taking output altogether (a
/// tool that was stopped or sent to the background) is cut off once too much has piled up.
private nonisolated final class ConsoleClientWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "SwiftVM console session")
    private let lock = NSLock()
    /// Bytes handed to ``write(_:)`` that haven't reached the terminal yet.
    private var backlog = 0
    /// Set when nothing more may be done with the descriptor, either way.
    private var isFinished = false

    static let backlogLimit = 4 << 20

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func write(_ data: Data) {
        let isAccepted = lock.withLock {
            guard !isFinished else { return false }
            backlog += data.count
            if backlog > Self.backlogLimit {
                isFinished = true
                // Ends the read that waits for the terminal's typing, and with it the session.
                shutdown(descriptor, SHUT_RDWR)
                return false
            }
            return true
        }
        guard isAccepted else { return }
        queue.async { [self] in
            defer { lock.withLock { backlog -= data.count } }
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard !lock.withLock({ isFinished }) else { return }
                    let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if errno != EINTR {
                        return
                    }
                }
            }
        }
    }

    /// Returns once nothing more will be written, so that the descriptor can be closed.
    func close() {
        lock.withLock { isFinished = true }
        queue.sync {}
    }
}
