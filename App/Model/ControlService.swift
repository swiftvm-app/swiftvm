import AppKit
import AgentControl
import GuestChannel
import Installers
import QEMUEngine
import SSHIntegration
import VMControl
import VMCore
import VMNetworking
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
            // A machine being created holds its name, so it is listed too, with how far it has got.
            return ControlResponse(
                ok: true, machines: library.machines.map { summary(of: $0) }, creations: creations.map { summary(of: $0) }
            )
        case .info:
            guard let identifier = request.machine else { return .failure("Missing machine name.") }
            guard let machine = findMachine(identifier) else { return notFound(identifier) }
            return details(machine)
        case .networkInterfaces:
            return ControlResponse(
                ok: true,
                note: BridgedNetworking.isEntitled ? nil : BridgedNetworking.Failure.notEntitled.localizedDescription,
                networkInterfaces: BridgedNetworking.interfaces.map { .init(identifier: $0.id, name: $0.name) }
            )
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
        // `wait` right after `create`, which was cut short or ran in the background, finds a machine
        // that is still being installed: it waits for that too.
        let startedWaiting = ContinuousClock.now
        if request.command == .wait, let creation = creationRatherThanMachine(identifier) {
            guard creation.errorMessage == nil else { return notFound(identifier) }
            if let problem = await waitForCreation(creation, timeout: request.waitTimeout) {
                return .failure(problem)
            }
        }
        // Deleting a machine that is still being created calls the creation off, as its row's button in
        // the menu bar panel does, and one that failed is cleared away. Either way its name is free again.
        if request.command == .delete, let creation = creationRatherThanMachine(identifier) {
            let note = creation.errorMessage == nil
                ? "Cancelled creating “\(creation.name)”."
                : "Cleared “\(creation.name)”, which couldn't be created."
            dismiss(creation)
            return ControlResponse(ok: true, note: note)
        }
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
        case .network:
            do {
                if request.networkMode != "mac", request.macAddress != nil {
                    return .failure("Use swiftvm network <machine> mac <address> to change the MAC address.")
                }
                switch request.networkMode {
                case "shared":
                    guard request.bridgedInterfaceIdentifier == nil else {
                        return .failure("Shared networking doesn't take a host interface.")
                    }
                    try setNetwork(of: machine, bridgedTo: nil)
                case "bridged":
                    guard let host = request.bridgedInterfaceIdentifier, !host.isEmpty else {
                        return .failure("Choose a host interface from swiftvm network-interfaces.")
                    }
                    try setNetwork(of: machine, bridgedTo: host)
                case "mac":
                    guard let address = request.macAddress, request.bridgedInterfaceIdentifier == nil else {
                        return .failure("Give a MAC address, without a host interface.")
                    }
                    try setMACAddress(address, for: machine)
                default:
                    return .failure("Choose shared or bridged networking, or mac to set the MAC address.")
                }
                return details(machine)
            } catch {
                return .failure(error.localizedDescription)
            }
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
                    let disc = try await guestToolsInstallation.perform(for: machine.id, named: machine.name) {
                        try await attachGuestToolsDisc(to: machine)
                    }
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
                // The password that installed them also lets them read the desktop.
                if machine.configuration.os.family == .macOS, let password = request.password, !password.isEmpty {
                    do {
                        try await allowAutomation(on: machine, password: password, sessionPatience: .seconds(120))
                    } catch {
                        // The tools are in. What they may do on the desktop is for later.
                        var response = details(machine)
                        response.note = "macOS in “\(machine.name)” doesn't let the guest tools read its desktop yet: \(Self.explanation(of: error, for: machine)) `swiftvm control \(machine.configuration.ssh.alias) allow --password <password>` tries again."
                        return response
                    }
                }
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
            // Linux on Apple's backend shares through a device, which must be there from the start.
            // On QEMU the guest agent is simply told, or no longer told, like macOS and Windows.
            guard machine.configuration.os.family != .linux || machine.configuration.engine == .qemu || machine.state == .stopped
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
                try await allowAutomation(on: machine, password: password)
            } catch {
                return .failure(Self.explanation(of: error, for: machine))
            }
            return details(machine)
        case .wait:
            let left = request.waitTimeout - (ContinuousClock.now - startedWaiting)
            if let problem = await waitUntilReady(machine, timeout: max(left, .zero)) {
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
        case .list, .info, .console, .vsock, .job, .control, .create, .quit, .usbList, .networkInterfaces, .scripts, .templates, .deleteTemplate, .renameTemplate:
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
        case .control:
            guard let call = request.control, !call.steps.isEmpty else { return (.failure("Missing what to do on the machine's desktop."), nil) }
            guard machine.configuration.automation.isAllowed else {
                return (.failure(Self.explanation(of: GuestJobError.notAllowed(name: machine.name), for: machine)), nil)
            }
            guard machine.state == .running else { return (.failure(VMError.notRunning(name: machine.name).localizedDescription), nil) }
            return (success(machine), { connection in await self.serveControl(call, of: machine, connection: connection) })
        default:
            return (.failure("This command doesn't open a stream."), nil)
        }
    }

    /// How long a guest's agent gets to end a job that was called off, before the app closes the line.
    private static let jobCallOffPatience: TimeInterval = 15

    /// Does what `swiftvm control` asked, and sends how it went as frames, the way a job's output comes.
    private func serveControl(_ call: ControlCall, of machine: VirtualMachine, connection: Int32) async {
        let controller = controller(of: machine)
        let work = Task { await controller.perform(call) }
        // The tool says nothing after its request, so that what shows on the connection is that it has
        // gone. What it asked for is called off then: a wait of ten minutes has nobody to wait for.
        let watch = ControlHangUp.watch(connection) { work.cancel() }
        let outcome = await work.value
        watch.cancel()
        let data = ControlOutcomeCoding.data(for: outcome)
        // Writing waits for the tool to read, and holds a thread of its own for that.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                if JobFrame.write(.output, data, to: connection) {
                    JobFrame.write(.end, JobFrame.end(.success).payload, to: connection)
                }
                // The tool hangs up once it has read how it ended. Closing before that could take the
                // end with it. The connection itself is closed by whoever handed it over.
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

    /// What remembers a machine's desktop from one call to the next.
    ///
    /// Only for as long as the guest runs: what it had on its screen means nothing after it has started
    /// anew. Nothing is remembered of machines that aren't there any more.
    private func controller(of machine: VirtualMachine) -> MachineController {
        if let known = machineControllers[machine.id], known.run == machine.startCount { return known.controller }
        machineControllers = machineControllers.filter { library.machine(id: $0.key) != nil }
        let controller = MachineController(machine: machine)
        machineControllers[machine.id] = (machine.startCount, controller)
        return controller
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
        return [error.localizedDescription, advice].compactMap { $0 }.joined(separator: " ")
    }

    /// How far a machine is from being ready for `exec`, `cp` and `control`.
    private enum Readiness {
        case ready
        /// Still on its way, busy with what is said.
        case waiting(String)
        /// It won't get there by itself, for the reason that is said.
        case failed(String)
    }

    /// Waits until a machine that is up, or coming up, is ready to be worked by scripts and agents: its
    /// guest tools answer, the setup it was created with has come to its end, restarts included, and a
    /// desktop it logs in to by itself is logged in, so that `swiftvm control` knows what is on it. Returns what is in
    /// the way if it doesn't get there in time.
    private func waitUntilReady(_ machine: VirtualMachine, timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        var hasDesktop: Bool?
        while true {
            // A machine that is down isn't on its way to anything. One that restarts at the end of its
            // setup is down for a moment, on its way back up.
            let isUp = machine.state.isActive && machine.state != .stopping && machine.state != .suspending
            guard isUp || machine.isRestartPending else { return "“\(machine.name)” isn't running." }
            switch await readiness(of: machine, hasDesktop: &hasDesktop) {
            case .ready:
                return nil
            case .failed(let reason):
                return reason
            case .waiting(let what):
                guard ContinuousClock.now < deadline else {
                    let alias = machine.configuration.ssh.alias.isEmpty ? machine.id.uuidString : machine.configuration.ssh.alias
                    return "“\(machine.name)” isn't ready yet: \(what). `swiftvm wait \(alias)` waits on."
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Says `yes` in a macOS or Linux guest whose desktop logs in to an account by itself when the
    /// system starts: macOS's automatic login, or that of GDM, SDDM or LightDM, the login screens of
    /// SwiftVM's desktops.
    private static let logsInByItself = """
        if [ "$(uname -s)" = Darwin ]; then
            defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser > /dev/null 2>&1 && echo yes || echo no
        elif [ -e /etc/systemd/system/display-manager.service ] && {
            grep -qsi '^ *AutomaticLoginEnable *= *true' /etc/gdm3/custom.conf /etc/gdm/custom.conf ||
            grep -rqs '^ *User *= *[^ ]' /etc/sddm.conf /etc/sddm.conf.d ||
            grep -rqs '^ *autologin-user *= *[^ ]' /etc/lightdm; }; then
            echo yes
        else
            echo no
        fi
        """

    private func readiness(of machine: VirtualMachine, hasDesktop: inout Bool?) async -> Readiness {
        let isWindowsBeingInstalled = machine.configuration.os.family == .windows && machine.configuration.installation.attachesSeedImage
        guard machine.state == .running, machine.agent.isConnected else {
            if isWindowsBeingInstalled { return .waiting("Windows is being installed") }
            if machinesBeingSetUp.contains(machine.id) { return .waiting("macOS is setting up its account") }
            return .waiting("its guest tools haven't answered. If they aren't installed, `swiftvm install-tools` installs them")
        }
        if let setup = machine.agent.setup {
            let step = setup.step.map { ": \($0)" } ?? ""
            switch setup.state {
            case .pending, .running:
                return .waiting("\(setup.title)\(step)")
            case .failed:
                let what = setup.name ?? "The setup script"
                let place = setup.step.map { ", at “\($0)”" } ?? ""
                guard machine.configuration.os.family == .linux else {
                    return .failed("\(what) couldn't be set up in “\(machine.name)”\(place).")
                }
                let alias = machine.configuration.ssh.alias.isEmpty ? machine.id.uuidString : machine.configuration.ssh.alias
                return .failed("\(what) couldn't be set up in “\(machine.name)”\(place). What it printed is in \(GuestIntegration.setupLogPath) in the guest. To run it again: swiftvm exec \(alias) --root -- systemctl start swiftvm-setup")
            case .finished:
                break
            }
        }
        // Windows starts once more at the end of its setup, which the app finishes as it stops.
        if isWindowsBeingInstalled { return .waiting("Windows is finishing its setup, and restarts") }
        // A new macOS machine is ready once the app has finished setting it up: until then it may still
        // be clicking through the guest's System Settings and typing the password there.
        if machinesBeingSetUp.contains(machine.id) {
            return .waiting("the guest tools are being installed and allowed to read the desktop")
        }
        // Said once: whoever waits next has been told, or has seen to it.
        if let problem = automationSetupProblems.removeValue(forKey: machine.id) {
            return .failed("“\(machine.name)” is running, but its setup didn't let the guest tools read its desktop: \(problem)")
        }
        guard machine.configuration.automation.isAllowed, machine.agent.offers(GuestFeature.accessibility),
              machine.agent.offers(GuestFeature.exec)
        else { return .ready }
        // A desktop is waited for only where it logs in by itself, as SwiftVM sets them up: one that
        // waits for someone at its login screen would be waited for in vain.
        if hasDesktop == nil {
            switch machine.configuration.os.family {
            case .windows:
                // Windows Setup is told to log in by itself, for good.
                hasDesktop = true
            case .macOS, .linux:
                let probe = GuestJob.exec(.init(arguments: ["/bin/sh", "-c", Self.logsInByItself], user: "root"))
                guard let said = try? await machine.collect(probe, patience: 10) else {
                    return .waiting("its guest tools are starting")
                }
                hasDesktop = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
            }
        }
        guard hasDesktop == true else { return .ready }
        do {
            let said = try await machine.collect(.tree(.init(depth: 1)), patience: 20)
            // A session that has only just begun lists nothing yet, and doesn't take much.
            let tree = try? JSONSerialization.jsonObject(with: said) as? [String: Any]
            guard (tree?["applications"] as? [Any])?.isEmpty == false else { return .waiting("its desktop is still starting") }
            return .ready
        } catch GuestJobError.refused(let reason) where !reason.contains("logged in") {
            // There is a desktop, whose parts can't be told: macOS not letting them be read, a locked
            // Windows, missing packages. `control` works from the pixels, and says why.
            return .ready
        } catch {
            return .waiting("its desktop isn't logged in yet")
        }
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
            return .failure(nameTakenProblem(name))
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

        let usesNestedVirtualization = parameters.nestedVirtualization ?? false
        if usesNestedVirtualization {
            guard !isMac else { return .failure("--nested-virt is for Linux guests.") }
            guard VZGenericPlatformConfiguration.isNestedVirtualizationSupported else {
                return .failure("This Mac can't run virtual machines inside a virtual machine: that takes an M3 or later. Leave out --nested-virt.")
            }
        }

        if isMac, parameters.acceleratesGraphics != nil {
            return .failure("--gpu and --no-gpu are for Linux guests. A macOS guest draws with this Mac's GPU by itself.")
        }
        let acceleratesGraphics = parameters.acceleratesGraphics ?? false
        if acceleratesGraphics {
            guard !usesRosetta else { return .failure("A machine with --gpu runs on QEMU, which has no Rosetta. Use --no-gpu to use Rosetta, or leave out --rosetta to use the GPU.") }
            guard !usesNestedVirtualization else { return .failure("A machine with --gpu runs on QEMU, which can't run virtual machines inside it. Use --no-gpu with --nested-virt, or leave out --nested-virt to use the GPU.") }
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
                nestedVirtualization: usesNestedVirtualization,
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
        guard parameters.nestedVirtualization == nil else { return .failure("--nested-virt is for Linux guests.") }
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
            return .failure(nameTakenProblem(name))
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
            acceleratesGraphics: parameters.acceleratesGraphics ?? false,
            location: location
        )
        return await finishCreating(named: name, starting: parameters.start) { self.create(request) }
    }

    /// Makes a machine from a template, which brings its system, its account and whatever was set up
    /// in it. Its name, its hardware and where it is kept are the new machine's own.
    private func createMachine(fromTemplate identifier: String, _ parameters: ControlRequest.CreateParameters) async -> ControlResponse {
        guard parameters.user == nil, parameters.password == nil, parameters.restoreImagePath == nil,
              parameters.installerPath == nil, parameters.scripts == nil, parameters.rosetta == nil,
              parameters.nestedVirtualization == nil,
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
            return .failure(nameTakenProblem(name))
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
            // Machines made from the command line are often worked by scripts and AI agents, which
            // shouldn't be handed whatever was copied on this Mac. `swiftvm share-clipboard` turns it on.
            var note: String?
            if machine.configuration.clipboard.isShared {
                do {
                    try machine.updateConfiguration { $0.clipboard.isShared = false }
                } catch {
                    note = "“\(machine.name)” shares this Mac's clipboard, because turning that off failed: \(error.localizedDescription) `swiftvm share-clipboard \(machine.configuration.ssh.alias) off` tries again."
                }
            }
            if startsMachine {
                guard !isQuittingUnattended else {
                    return .failure("“\(machine.name)” was created but not started, because \(AppIdentity.current.name) is quitting.")
                }
                await machine.start()
                if let error = machine.lastError {
                    machine.lastError = nil
                    return .failure("\(error.title): \(error.message)" + (note.map { " " + $0 } ?? ""))
                }
            }
            var response = success(machine)
            response.note = note
            return response
        case .failure(let error):
            // The caller reports the failure; don't leave a failed row behind in the menu bar panel.
            creations.removeAll { $0.name == name && $0.errorMessage != nil }
            // Called off from the menu bar panel, or by `swiftvm delete` in another terminal.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .failure("Creating “\(name)” was cancelled.")
            }
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// What to add to the news that a guest asked on its screen instead of shutting down: with the
    /// guest tools it wouldn't have. Nothing for a guest that has them and whose agent didn't answer.
    private func guestToolsHint(for machine: VirtualMachine) -> String {
        machine.agent.isConnected ? "" : " With the guest tools it does so without asking: swiftvm install-tools."
    }

    /// The machine being created, or that failed to be, that `identifier` names, by its name or the SSH
    /// name it is going to get.
    private func creation(named identifier: String) -> MachineCreation? {
        let lowered = identifier.lowercased()
        return creations.first { $0.name.lowercased() == lowered } ?? creations.first { SSHAlias.slug(from: $0.name) == lowered }
    }

    /// The creation that `identifier` names, where a machine could be named by it too. A name goes before
    /// an SSH name: a machine that was renamed keeps its SSH name, which can be a new machine's name, and
    /// `swiftvm delete` of the new one mustn't delete the old.
    private func creationRatherThanMachine(_ identifier: String) -> MachineCreation? {
        let lowered = identifier.lowercased()
        if let id = UUID(uuidString: identifier), library.machine(id: id) != nil { return nil }
        if library.machines.contains(where: { $0.name.lowercased() == lowered }) { return nil }
        if let creation = creations.first(where: { $0.name.lowercased() == lowered }) { return creation }
        if library.machines.contains(where: { $0.configuration.ssh.alias == lowered }) { return nil }
        return creations.first { SSHAlias.slug(from: $0.name) == lowered }
    }

    /// Why `name`, which ``isNameTaken(_:)``, can't be given to a new machine, and what frees it when a
    /// creation holds it.
    private func nameTakenProblem(_ name: String) -> String {
        guard let creation = creation(named: name), creation.name.lowercased() == name.lowercased() else {
            return "A virtual machine named “\(name)” already exists."
        }
        let identifier = shellWord(creation.name)
        guard let error = creation.errorMessage else {
            return "“\(creation.name)” is being created already: \(progress(of: creation)). `swiftvm wait \(identifier)` waits until it is ready, `swiftvm delete \(identifier)` cancels it."
        }
        return "“\(creation.name)” couldn't be created: \(Self.sentence(error)) `swiftvm delete \(identifier)` clears it, so that the name can be used again."
    }

    /// `Downloading… (42%)`
    private func progress(of creation: MachineCreation) -> String {
        creation.status + (creation.fraction.map { " (\(Int(($0 * 100).rounded()))%)" } ?? "")
    }

    private func summary(of creation: MachineCreation) -> CreationSummary {
        CreationSummary(
            name: creation.name, system: creation.os.summary,
            status: creation.status, fraction: creation.fraction, error: creation.errorMessage
        )
    }

    /// Waits until `creation` has put its machine in the library. Returns why not, if it doesn't.
    private func waitForCreation(_ creation: MachineCreation, timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while creations.contains(where: { $0.id == creation.id }) {
            if let message = creation.errorMessage {
                return "“\(creation.name)” couldn't be created: \(message)"
            }
            guard ContinuousClock.now < deadline else {
                let progress = creation.fraction.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
                return "“\(creation.name)” isn't ready yet: it is still being created, \(creation.status)\(progress). `swiftvm wait \(shellWord(creation.name))` waits on."
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
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
            // guest's is passed on.
            automation: MachineDetails.Automation(
                isAllowed: configuration.automation.isAllowed,
                features: GuestFeature.jobs.filter(machine.agent.offers)
            ),
            networkMode: configuration.networkInterfaces.first.map { $0.usesSharedNetwork ? "shared" : "bridged" },
            bridgedInterfaceIdentifier: configuration.networkInterfaces.first?.bridgedInterfaceIdentifier
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
        if let creation = creation(named: identifier) {
            let name = shellWord(creation.name)
            guard let error = creation.errorMessage else {
                return .failure("“\(creation.name)” is still being created: \(progress(of: creation)). `swiftvm wait \(name)` waits until it is ready, `swiftvm delete \(name)` cancels it.")
            }
            return .failure("“\(creation.name)” couldn't be created: \(Self.sentence(error)) `swiftvm delete \(name)` clears it, so that the name can be used again.")
        }
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
