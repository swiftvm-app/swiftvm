import DiskTools
import Foundation
import Installers
import Observation
import SSHIntegration
import VMCore

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
        let interface = NetworkInterfaceConfiguration(ipv4Address: allocateAddress()?.description)
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
        let bundle = try VMBundle.create(at: library.availableBundleURL(forName: request.name), configuration: configuration)
        do {
            let diskURL = bundle.diskURL(for: disk)
            let progress = ProgressRelay { fraction in creation.fraction = fraction }
            try await Task.detached(priority: .userInitiated) {
                try LinuxImageInstaller.install(image: imageURL, to: diskURL, capacity: disk.capacity) { progress.report($0) }
                try seed.writeImage(to: bundle.seedImageURL)
            }.value
            try Task.checkCancellation()
            sshWriter.forgetHostKey(for: alias)
            return try library.add(bundle)
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
        let interface = NetworkInterfaceConfiguration(ipv4Address: allocateAddress()?.description)
        let configuration = VMConfiguration(
            name: request.name,
            os: os,
            cpuCount: request.cpuCount,
            memorySize: request.memorySize,
            disks: [disk],
            networkInterfaces: [interface],
            ssh: SSHConfiguration(alias: uniqueAlias(for: request.name)),
            installation: InstallationConfiguration(installMediaPath: mediaURL.path)
        )
        let bundle = try VMBundle.create(at: library.availableBundleURL(forName: request.name), configuration: configuration)
        do {
            try DiskService.createBlankDisk(at: bundle.diskURL(for: disk), capacity: disk.capacity, format: disk.format)
            return try library.add(bundle)
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
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
