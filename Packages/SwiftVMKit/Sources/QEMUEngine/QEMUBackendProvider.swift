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

    /// Whether this copy of the app's QEMU lets a guest draw with the Mac's GPU.
    public var canAccelerateGraphics: Bool { installation?.acceleratesGraphics ?? false }

    public func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        guard machine.configuration.engine == .qemu else { throw VMError.unsupportedEngine(machine.configuration.engine) }
        guard let installation else { throw QEMUError.notInstalled }

        // Memory that was saved expects the display it was saved with. A guest that starts afresh
        // gets the one that follows the window once it has the driver for it.
        let isRestoring = machine.state == .restoring
        let current = machine.configuration
        let adapter: DisplayAdapter = if isRestoring {
            current.display.adapter ?? .framebuffer
        } else if current.os.family == .linux {
            // Linux brings the driver for a virtio GPU along, whether it draws with the Mac's GPU or not.
            current.display.acceleratesGraphics ? .virtioGPU3D : .virtioGPU
        } else {
            Self.windowsDisplayAdapter(for: current.installation, installation: installation)
        }
        if adapter == .virtioGPU3D {
            guard !isRestoring else {
                throw QEMUError.didNotStart("A machine with graphics acceleration can't resume saved memory.")
            }
            guard installation.acceleratesGraphics else {
                throw QEMUError.didNotStart("This copy of SwiftVM's QEMU was built without graphics acceleration.")
            }
            // Custom builds can leave out Direct3D, which Windows' 3D driver needs.
            guard current.os.family != .windows || installation.supportsDirect3D else {
                throw QEMUError.didNotStart("This copy of SwiftVM's QEMU was built without Direct3D, which Windows' 3D driver needs.")
            }
        }
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

    static func windowsDisplayAdapter(for configuration: InstallationConfiguration, installation: QEMUInstallation) -> DisplayAdapter {
        if configuration.hasAcceleratedDisplayDriver {
            // The 3D installer removes the display-only driver. Without Direct3D in this copy of the
            // app, the firmware's framebuffer still works; a plain virtio GPU may have no driver.
            return installation.acceleratesGraphics && installation.supportsDirect3D ? .virtioGPU3D : .framebuffer
        }
        return configuration.hasDisplayDriver ? .virtioGPU : .framebuffer
    }

    /// Whether the machine is about to start an installer disc: one is plugged in, and nothing has
    /// been written to the disk it would install to. Once the installer has written there, a start goes
    /// to what it wrote, which is where the installation carries on.
    static func bootsInstaller(_ configuration: VMConfiguration, bundle: VMBundle) -> Bool {
        // Only Windows' disc waits for a key. On a Linux disc, a key stops the boot menu's countdown.
        guard configuration.os.family == .windows, let disk = configuration.systemDisk,
              configuration.removableImages.contains(where: { RemovableImage.isDiscImage($0.url) })
        else { return false }
        return bundle.allocatedSize(of: [disk]) < 16 << 20
    }
}
