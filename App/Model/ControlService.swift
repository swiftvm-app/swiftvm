import AppKit
import Installers
import VMControl
import VMCore
import VZEngine

/// Handles requests from the `swiftvm` command-line tool.
extension AppModel {
    func handle(_ request: ControlRequest) async -> ControlResponse {
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
        case .console:
            // The stream itself is served by `serveConsole` once this answer has gone out.
            guard let identifier = request.machine else { return .failure("Missing machine name.") }
            guard let machine = findMachine(identifier) else { return notFound(identifier) }
            return success(machine)
        case .create:
            guard let parameters = request.create else { return .failure("Missing creation parameters.") }
            return await createMachine(parameters)
        case .quit:
            // Quitting from the command line never puts up the dialog that asks what to do with machines.
            guard activeMachines.isEmpty else {
                return .failure("Stop or suspend the running virtual machines first.")
            }
            guard creationsInProgress.isEmpty else {
                return .failure("A virtual machine is still being created.")
            }
            guard !isWorkingOnMachineFiles else {
                return .failure("A virtual machine is busy with a snapshot, a copy or a resize. Try again in a moment.")
            }
            Task {
                // Let the answer reach the caller before the app goes away.
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.terminate(nil)
            }
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
            await shutDown(machine)
            // The machine goes back to running when the guest doesn't act on the request.
            _ = await waitForState(of: machine, timeout: .seconds(90), where: { $0 != .stopping })
            guard machine.state == .stopped else {
                if machine.configuration.asksBeforeShuttingDown {
                    return .failure("“\(machine.name)” asks for confirmation on its screen before it shuts down, and nobody answered. Answer it in the machine's window, or use force-stop to stop it immediately.")
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
            await shutDown(machine, thenRestart: true)
            // Wait for the guest to go down and come back up.
            _ = await waitForState(of: machine, timeout: .seconds(90), where: { $0 != .running && $0 != .stopping })
            guard await waitForState(of: machine, timeout: .seconds(60), where: { $0 == .running }) else {
                return .failure("“\(machine.name)” didn't come back up in time.")
            }
        case .open:
            guard let showMachineWindow else { return .failure("The library window isn't available.") }
            showMachineWindow(machine.id)
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
        case .discardState:
            guard machine.state == .suspended else { return .failure("“\(machine.name)” isn't suspended.") }
            machine.discardSavedState()
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
        case .revert, .deleteSnapshot:
            guard let identifier = request.snapshot else { return .failure("Missing snapshot name.") }
            let found = findSnapshot(identifier, of: machine)
            guard case .success(let snapshot) = found else {
                if case .failure(let problem) = found { return .failure(problem.message) }
                return .failure("No such snapshot.")
            }
            do {
                if request.command == .revert {
                    try await machine.revert(to: snapshot)
                } else {
                    try machine.deleteSnapshot(snapshot)
                    return snapshots(of: machine)
                }
            } catch {
                return .failure(error.localizedDescription)
            }
        case .list, .info, .console, .create, .quit:
            break
        }

        // The command-line caller gets the error, so don't also raise an alert in the app.
        if let error = machine.lastError {
            machine.lastError = nil
            return .failure("\(error.title): \(error.message)")
        }
        return success(machine)
    }

    // MARK: Serial console

    /// Connects a `swiftvm console` session to a machine's serial console and returns when the tool hangs
    /// up. Like a cable, the session survives the machine being stopped and started.
    nonisolated func serveConsole(_ request: ControlRequest, connection: Int32) async {
        let target: (console: SerialConsole, name: String)? = await MainActor.run {
            guard let machine = request.machine.flatMap(self.findMachine) else { return nil }
            return (machine.console, machine.name)
        }
        guard let (console, name) = target else { return }

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
        let isMac = parameters.distribution == ControlRequest.CreateParameters.macOS
        let distribution = DistributionCatalog.quickCreate.first { $0.id == parameters.distribution }
        guard isMac || distribution != nil else {
            let available = ([ControlRequest.CreateParameters.macOS] + DistributionCatalog.quickCreate.map(\.id)).joined(separator: ", ")
            return .failure("Unknown system “\(parameters.distribution)”. Available: \(available).")
        }
        let family: GuestFamily = isMac ? .macOS : .linux
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
        let memorySize = parameters.memoryGigabytes.map { UInt64($0) * HostResources.gibibyte }
            ?? HostResources.recommendedMemorySize(for: family)
        let diskCapacity = parameters.diskGigabytes.map { UInt64($0) * HostResources.gibibyte }
            ?? HostResources.recommendedDiskCapacity(for: family)

        let start: () -> MachineCreation
        if let distribution {
            let request = LinuxQuickCreateRequest(
                name: name,
                distribution: distribution,
                cpuCount: cpuCount,
                memorySize: memorySize,
                diskCapacity: diskCapacity,
                userName: parameters.user ?? NSUserName(),
                fullName: NSFullUserName(),
                password: parameters.password ?? "",
                installsSSHKey: true,
                rosetta: false
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
                let provisioning = GuestProvisioning(fullName: NSFullUserName(), userName: userName, password: password)
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
                installsSSHKey: true
            )
            start = { self.create(request) }
        }

        let result: Result<VirtualMachine, any Error> = await withCheckedContinuation { continuation in
            let creation = start()
            creation.onFinish = { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let machine):
            if parameters.start {
                await machine.start()
                if let error = machine.lastError {
                    machine.lastError = nil
                    return .failure("\(error.title): \(error.message)")
                }
            }
            return success(machine)
        case .failure(let error):
            // The caller reports the failure; don't leave a failed row behind in the library.
            creations.removeAll { $0.name == name && $0.errorMessage != nil }
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Helpers

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
            snapshotCount: machine.snapshots.count
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
        .failure("No virtual machine named “\(identifier)”.")
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
