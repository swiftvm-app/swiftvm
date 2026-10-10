import Foundation
import Installers
import VMControl
import VMCore

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
        case .create:
            guard let parameters = request.create else { return .failure("Missing creation parameters.") }
            return await createMachine(parameters)
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
            await machine.shutDown()
            guard await waitForState(of: machine, timeout: .seconds(90), where: { $0 == .stopped }) else {
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
            await machine.restart()
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
        case .list, .create:
            break
        }

        // The command-line caller gets the error, so don't also raise an alert in the app.
        if let error = machine.lastError {
            machine.lastError = nil
            return .failure("\(error.title): \(error.message)")
        }
        return success(machine)
    }

    // MARK: Creating

    private func createMachine(_ parameters: ControlRequest.CreateParameters) async -> ControlResponse {
        guard let distribution = DistributionCatalog.quickCreate.first(where: { $0.id == parameters.distribution }) else {
            let available = DistributionCatalog.quickCreate.map(\.id).joined(separator: ", ")
            return .failure("Unknown distribution “\(parameters.distribution)”. Available: \(available).")
        }
        var name = parameters.name ?? distribution.name.replacingOccurrences(of: " LTS", with: "")
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

        let request = LinuxQuickCreateRequest(
            name: name,
            distribution: distribution,
            cpuCount: parameters.cpuCount ?? HostResources.recommendedCPUCount(for: .linux),
            memorySize: parameters.memoryGigabytes.map { UInt64($0) * HostResources.gibibyte }
                ?? HostResources.recommendedMemorySize(for: .linux),
            diskCapacity: parameters.diskGigabytes.map { UInt64($0) * HostResources.gibibyte }
                ?? HostResources.recommendedDiskCapacity(for: .linux),
            userName: parameters.user ?? NSUserName(),
            fullName: NSFullUserName(),
            password: parameters.password ?? "",
            installsSSHKey: true,
            rosetta: false
        )

        let result: Result<VirtualMachine, any Error> = await withCheckedContinuation { continuation in
            let creation = create(request)
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
    private func findMachine(_ identifier: String) -> VirtualMachine? {
        if let id = UUID(uuidString: identifier), let machine = library.machine(id: id) {
            return machine
        }
        let lowered = identifier.lowercased()
        return library.machines.first { $0.name.lowercased() == lowered }
            ?? library.machines.first { $0.configuration.ssh.alias == lowered }
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
