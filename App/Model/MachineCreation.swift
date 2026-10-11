import DiskTools
import Foundation
import Installers
import Observation
import SSHIntegration
import VMCore
import VMNetworking
import VZEngine

/// A machine that is still being downloaded and prepared; shown in the library with its progress.
@Observable
final class MachineCreation: Identifiable {
    let id = UUID()
    let name: String
    let os: GuestOS
    var status = "Preparing…"
    /// Progress of the current step, or `nil` when it can't be measured.
    var fraction: Double?
    /// Set when creation failed; the row stays until the user dismisses it.
    var errorMessage: String?
    @ObservationIgnored var task: Task<Void, Never>?
    /// Called once with the outcome, for callers that wait for creation to finish.
    @ObservationIgnored var onFinish: ((Result<VirtualMachine, any Error>) -> Void)?

    init(name: String, os: GuestOS) {
        self.name = name
        self.os = os
    }

    func update(_ status: String, fraction: Double? = nil) {
        self.status = status
        self.fraction = fraction
    }
}

/// Everything needed to create a Linux machine from a cloud image without running an installer.
struct LinuxQuickCreateRequest {
    var name: String
    var distribution: LinuxDistribution
    var cpuCount: Int
    var memorySize: UInt64
    var diskCapacity: UInt64
    var userName: String
    var fullName: String
    /// Empty means key-only login.
    var password: String
    var installsSSHKey: Bool
    var rosetta: Bool
}

/// Everything needed to create an empty Linux machine that boots an installer ISO.
struct LinuxInstallerRequest {
    enum Media {
        case localFile(URL)
        case download(LinuxDistribution, LinuxDistribution.Installer)
    }

    var name: String
    var media: Media
    var cpuCount: Int
    var memorySize: UInt64
    var diskCapacity: UInt64
}

/// Everything needed to install macOS from a restore image.
struct MacInstallRequest {
    var name: String
    /// The restore image to install. `nil` looks up the newest macOS this Mac can run and downloads it.
    var image: MacRestoreImage?
    var cpuCount: Int
    var memorySize: UInt64
    var diskCapacity: UInt64
    /// The account macOS creates on its first start. `nil` leaves setup to the guest's own assistant, as
    /// do images older than macOS 27.
    var account: GuestProvisioning?
    /// Add the host's SSH key to the account once the guest is up.
    var installsSSHKey: Bool
}

extension AppModel {
    /// Starts creating a machine from a cloud image. `onReady` runs once it is in the library.
    @discardableResult
    func create(_ request: LinuxQuickCreateRequest, onReady: @escaping (VirtualMachine) -> Void = { _ in }) -> MachineCreation {
        let os = GuestOS(family: .linux, distribution: request.distribution.distribution, productName: request.distribution.name)
        return run(MachineCreation(name: request.name, os: os), onReady: onReady) { creation in
            try await self.performQuickCreate(request, os: os, creation: creation)
        }
    }

    /// Starts creating an empty machine with an installer ISO attached.
    @discardableResult
    func create(_ request: LinuxInstallerRequest, onReady: @escaping (VirtualMachine) -> Void = { _ in }) -> MachineCreation {
        var os = GuestOS(family: .linux)
        if case .download(let distribution, _) = request.media {
            os = GuestOS(family: .linux, distribution: distribution.distribution, productName: distribution.name)
        }
        return run(MachineCreation(name: request.name, os: os), onReady: onReady) { creation in
            try await self.performInstallerCreate(request, os: os, creation: creation)
        }
    }

    /// Starts installing macOS into a new machine.
    @discardableResult
    func create(_ request: MacInstallRequest, onReady: @escaping (VirtualMachine) -> Void = { _ in }) -> MachineCreation {
        let os = request.image?.guestOS ?? GuestOS(family: .macOS)
        return run(MachineCreation(name: request.name, os: os), onReady: onReady) { creation in
            try await self.performMacInstall(request, creation: creation)
        }
    }

    func dismiss(_ creation: MachineCreation) {
        creation.task?.cancel()
        creations.removeAll { $0.id == creation.id }
    }

    // MARK: Steps

    private func run(
        _ creation: MachineCreation,
        onReady: @escaping (VirtualMachine) -> Void,
        operation: @escaping (MachineCreation) async throws -> VirtualMachine
    ) -> MachineCreation {
        creations.append(creation)
        creation.task = Task {
            do {
                let machine = try await operation(creation)
                creations.removeAll { $0.id == creation.id }
                creation.onFinish?(.success(machine))
                onReady(machine)
            } catch {
                let isCancellation = error is CancellationError || (error as? URLError)?.code == .cancelled
                if isCancellation {
                    creations.removeAll { $0.id == creation.id }
                } else {
                    creation.fraction = nil
                    creation.errorMessage = error.localizedDescription
                }
                creation.onFinish?(.failure(error))
            }
        }
        return creation
    }

    private func performQuickCreate(_ request: LinuxQuickCreateRequest, os: GuestOS, creation: MachineCreation) async throws -> VirtualMachine {
        guard let image = request.distribution.cloudImage else {
            throw VMError.invalidConfiguration("\(request.distribution.name) has no ready-made image.")
        }
        let imageURL = try await download(image, named: request.distribution.name, creation: creation)
        try Task.checkCancellation()

        let alias = uniqueAlias(for: request.name)
        let keyPair = request.installsSSHKey ? try keyManager.preferredKeyPair() : nil
        let disk = DiskConfiguration(fileName: "disk.img", capacity: request.diskCapacity, bus: .virtio, format: .raw)
        let interface = NetworkInterfaceConfiguration()
        let configuration = VMConfiguration(
            name: request.name,
            os: os,
            cpuCount: request.cpuCount,
            memorySize: request.memorySize,
            disks: [disk],
            networkInterfaces: [interface],
            boot: BootConfiguration(rosetta: request.rosetta),
            ssh: SSHConfiguration(alias: alias, user: request.userName, identityFile: keyPair?.privateKeyPath),
            installation: InstallationConfiguration(attachesSeedImage: true)
        )
        let seed = CloudInitSeed(
            hostName: alias,
            userName: request.userName,
            fullName: request.fullName.isEmpty ? nil : request.fullName,
            password: request.password.isEmpty ? nil : request.password,
            authorizedKeys: keyPair.map { [$0.publicKey] } ?? [],
            macAddress: interface.macAddress,
            rosettaTag: request.rosetta ? GuestIntegration.rosettaTag : nil
        )

        creation.update("Preparing disk…", fraction: 0)
        let bundle = try VMBundle.create(at: library.makeStagingBundleURL(), configuration: configuration)
        do {
            let diskURL = bundle.diskURL(for: disk)
            let progress = ProgressRelay { fraction in creation.fraction = fraction }
            try await Task.detached(priority: .userInitiated) {
                try LinuxImageInstaller.install(image: imageURL, to: diskURL, capacity: disk.capacity) { progress.report($0) }
                try seed.writeImage(to: bundle.seedImageURL)
            }.value
            try Task.checkCancellation()
            sshWriter.forgetHostKey(for: alias)
            return try addToLibrary(staged: bundle)
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    private func performInstallerCreate(_ request: LinuxInstallerRequest, os: GuestOS, creation: MachineCreation) async throws -> VirtualMachine {
        let mediaURL: URL
        switch request.media {
        case .localFile(let url):
            mediaURL = url
        case .download(let distribution, let installer):
            mediaURL = try await download(installer.image, named: "\(distribution.name) \(installer.name)", creation: creation)
        }
        try Task.checkCancellation()

        creation.update("Creating disk…")
        let disk = DiskConfiguration(fileName: "disk.asif", capacity: request.diskCapacity, bus: .virtio, format: .asif)
        let configuration = VMConfiguration(
            name: request.name,
            os: os,
            cpuCount: request.cpuCount,
            memorySize: request.memorySize,
            disks: [disk],
            removableImages: [RemovableImage(url: mediaURL, readOnly: true)],
            networkInterfaces: [NetworkInterfaceConfiguration()],
            ssh: SSHConfiguration(alias: uniqueAlias(for: request.name))
        )
        let bundle = try VMBundle.create(at: library.makeStagingBundleURL(), configuration: configuration)
        do {
            try DiskService.createBlankDisk(at: bundle.diskURL(for: disk), capacity: disk.capacity, format: disk.format)
            return try addToLibrary(staged: bundle)
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    private func performMacInstall(_ request: MacInstallRequest, creation: MachineCreation) async throws -> VirtualMachine {
        var image: MacRestoreImage
        if let requested = request.image {
            image = requested
        } else {
            creation.update("Checking for the latest macOS…")
            image = try await MacRestoreImage.latestSupported()
        }
        if image.isRemote {
            let file = try await download(RemoteImage(url: image.url), named: image.productName, creation: creation)
            try Task.checkCancellation()
            creation.update("Checking \(image.productName)…")
            // From here on, go by what the downloaded file says about itself.
            do {
                image = try await MacRestoreImage.load(from: file)
            } catch {
                // Nothing checks an image against a published checksum, so a damaged one would otherwise
                // sit in the cache and fail the same way every time.
                try? FileManager.default.removeItem(at: file)
                throw VMError.invalidConfiguration(
                    "The downloaded restore image is damaged and was removed (\(error.localizedDescription)) Try again to download it anew."
                )
            }
        }
        guard let requirements = image.requirements else {
            throw MacOSInstaller.InstallError.unsupportedImage(image.productName)
        }
        try Task.checkCancellation()

        let alias = uniqueAlias(for: request.name)
        let account = image.supportsProvisioning ? request.account : nil
        try account?.validateForMacOS()
        let keyPair = request.installsSSHKey && account?.enablesRemoteLogin == true ? try keyManager.preferredKeyPair() : nil
        let disk = DiskConfiguration(fileName: "disk.asif", capacity: request.diskCapacity, bus: .virtio, format: .asif)
        let configuration = VMConfiguration(
            name: request.name,
            os: image.guestOS,
            cpuCount: max(request.cpuCount, requirements.minimumCPUCount),
            memorySize: max(request.memorySize, requirements.minimumMemorySize),
            disks: [disk],
            display: .macOS,
            networkInterfaces: [NetworkInterfaceConfiguration()],
            ssh: SSHConfiguration(alias: alias, user: account?.userName ?? "", identityFile: keyPair?.privateKeyPath)
        )

        creation.update("Creating disk…")
        let bundle = try VMBundle.create(at: library.makeStagingBundleURL(), configuration: configuration)
        do {
            try MacOSInstaller.prepare(bundle, for: requirements)
            try DiskService.createBlankDisk(at: bundle.diskURL(for: disk), capacity: disk.capacity, format: disk.format)
            creation.update("Installing \(image.productName)…", fraction: 0)
            try await MacOSInstaller.install(image, into: bundle, configuration: configuration) { fraction in
                creation.fraction = fraction
            }
            sshWriter.forgetHostKey(for: alias)
            let machine = try addToLibrary(staged: bundle)
            machine.pendingProvisioning = account
            if let account, let keyPair {
                finishSetup(of: machine, account: account, keyPair: keyPair)
            }
            return machine
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    /// Moves a finished bundle into the library and gives its network interface a free address.
    ///
    /// The address is picked here rather than when creation starts: creations run side by side, and two of
    /// them must not end up with the same one.
    func addToLibrary(staged bundle: VMBundle) throws -> VirtualMachine {
        var configuration = try bundle.loadConfiguration()
        if let index = configuration.networkInterfaces.firstIndex(where: { $0.ipv4Address == nil }) {
            configuration.networkInterfaces[index].ipv4Address = allocateAddress()?.description
            try bundle.save(configuration)
        }
        return try library.add(staged: bundle)
    }

    /// Finishes setting up a macOS guest over SSH once its first start has created the account: adds the
    /// host's SSH key and installs the guest tools, through which the guest then gets the host's time zone.
    ///
    /// macOS turns on Remote Login for password sign-in only, so the key is installed by signing in once
    /// with the password as soon as the guest answers. Installing the guest tools takes the password
    /// too, for `sudo`. It stays in memory until then, and nowhere else.
    private func finishSetup(of machine: VirtualMachine, account: GuestProvisioning, keyPair: SSHKeyManager.KeyPair) {
        Task {
            // The first start may be a while off if the machine isn't started right away.
            while !machine.configuration.installation.isProvisioned {
                guard library.machine(id: machine.id) != nil else { return }
                try? await Task.sleep(for: .seconds(1))
            }

            let alias = machine.configuration.ssh.alias
            let configURL = sshWriter.generatedConfigURL
            let deadline = ContinuousClock.now + .seconds(600)
            while machine.state.isActive, ContinuousClock.now < deadline {
                if let address = address(for: machine).flatMap(IPv4Address.init),
                   await Reachability.canConnect(to: address, port: machine.configuration.ssh.port) {
                    // Refused sign-ins are expected until the guest has finished creating the account.
                    let isInstalled = await Task.detached {
                        (try? SSHKeyInstaller.install(
                            publicKey: keyPair.publicKey, on: alias, configURL: configURL, password: account.password
                        )) != nil
                    }.value
                    if isInstalled {
                        await installGuestTools(afterSetupOf: machine, password: account.password)
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
            // A machine that was stopped before it finished setting up has nothing to report.
            guard machine.state.isActive else { return }
            machine.lastError = VMErrorInfo(
                title: "Couldn't add your SSH key to “\(machine.name)”",
                message: "The virtual machine didn't accept an SSH sign-in in time. You can still connect with the account's password."
            )
        }
    }

    /// Installs the guest tools in a macOS guest whose key has just been installed, with the password the
    /// app still holds from creating it. Nothing here is worth failing the setup over: a guest that ends
    /// up without the tools works as macOS guests did before there were any, and says so.
    private func installGuestTools(afterSetupOf machine: VirtualMachine, password: String) async {
        do {
            try await installGuestTools(on: machine, password: password)
            // From here on the machine sees to the rest by itself, through the agent.
        } catch {
            guard machine.state.isActive else { return }
            // Nobody was asked where this Mac is, so the guest would stay on Pacific time. Without the
            // agent the time zone is set the way it was before there was one.
            let alias = machine.configuration.ssh.alias
            let configURL = sshWriter.generatedConfigURL
            let isSet = await Task.detached {
                (try? GuestTimeZone.set(on: alias, configURL: configURL, password: password)) != nil
            }.value
            if isSet {
                try? machine.updateConfiguration { $0.installation.hasHostTimeZone = true }
            }
            var reason = error.localizedDescription
            if let failure = error as? ProcessRunner.Failure, let complaint = LinuxGuestAgent.installerComplaint(in: failure) {
                reason = Self.sentence(complaint)
            }
            machine.notice = VMErrorInfo(
                title: "The guest tools couldn't be installed in “\(machine.name)”",
                message: "\(reason)\n\nThe virtual machine works without them, but it asks on its screen before it shuts down and doesn't share the clipboard. Install Guest Tools… in the Virtual Machine menu tries again."
            )
        }
    }

    private func download(_ image: RemoteImage, named name: String, creation: MachineCreation) async throws -> URL {
        let isCached = FileManager.default.fileExists(atPath: downloader.cachedURL(for: image).path)
        creation.update(isCached ? "Preparing…" : "Downloading \(name)…", fraction: isCached ? nil : 0)
        let progress = ProgressRelay { fraction in creation.fraction = fraction }
        let url = try await downloader.fetch(image) { update in
            if let fraction = update.fraction {
                progress.report(fraction)
            }
        }
        return url
    }
}

/// Forwards progress from a background thread to the main actor, at most a few times per second.
private nonisolated final class ProgressRelay: @unchecked Sendable {
    private let handler: @MainActor (Double) -> Void
    private let lock = NSLock()
    private var lastReport = Date.distantPast

    init(handler: @escaping @MainActor (Double) -> Void) {
        self.handler = handler
    }

    func report(_ fraction: Double) {
        let now = Date()
        let shouldReport = lock.withLock {
            guard fraction >= 1 || now.timeIntervalSince(lastReport) > 0.1 else { return false }
            lastReport = now
            return true
        }
        guard shouldReport else { return }
        Task { @MainActor in handler(fraction) }
    }
}
