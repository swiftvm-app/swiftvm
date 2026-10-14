import Foundation
import VMCore
import VMNetworking

/// Starts the machines that run on QEMU, on the same network as every other machine.
@MainActor
public final class QEMUBackendProvider: VMBackendProvider {
    private let networkManager: NetworkManager
    /// The QEMU inside the app. `nil` in a copy of the app that was built without it.
    private let installation: QEMUInstallation?

    public init(networkManager: NetworkManager, installation: QEMUInstallation?) {
        self.networkManager = networkManager
        self.installation = installation
    }

    /// Whether this copy of the app can run machines on QEMU.
    public var isAvailable: Bool { installation != nil }

    public func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        guard machine.configuration.engine == .qemu else { throw VMError.unsupportedEngine(machine.configuration.engine) }
        guard let installation else { throw QEMUError.notInstalled }

        // Memory that was saved expects the display it was saved with. A guest that starts afresh
        // gets the one that follows the window once it has the driver for it.
        let isRestoring = machine.state == .restoring
        let adapter: DisplayAdapter = isRestoring
            ? machine.configuration.display.adapter ?? .framebuffer
            : machine.configuration.installation.hasDisplayDriver ? .virtioGPU : .framebuffer
        if machine.configuration.display.adapter != adapter {
            try machine.updateConfiguration { $0.display.adapter = adapter }
        }

        let configuration = machine.configuration
        let network = try await networkManager.acquireDefaultNetwork(for: machine.id)
        do {
            return try QEMUBackend(
                configuration: configuration, bundle: machine.bundle, installation: installation, adapter: adapter,
                network: network, console: console,
                pressesKeyToBootInstaller: Self.bootsInstaller(configuration, bundle: machine.bundle)
            )
        } catch {
            networkManager.release(user: machine.id)
            throw error
        }
    }

    public func backendDidStop(for machine: VirtualMachine) {
        networkManager.release(user: machine.id)
    }

    /// Whether the machine is about to start an installer disc: one is plugged in, and nothing has
    /// been written to the disk it would install to. Once the installer has written there, a start goes
    /// to what it wrote, which is where the installation carries on.
    static func bootsInstaller(_ configuration: VMConfiguration, bundle: VMBundle) -> Bool {
        guard let disk = configuration.systemDisk,
              configuration.removableImages.contains(where: { RemovableImage.isDiscImage($0.url) })
        else { return false }
        return bundle.allocatedSize(of: [disk]) < 16 << 20
    }
}
