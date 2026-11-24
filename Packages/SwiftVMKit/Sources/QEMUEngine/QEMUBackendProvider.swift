import AppKit
import VMControl
import VMCore
import VMNetworking

/// Hands the machines that run on QEMU to `swiftvm serve`, on the same network as every other machine.
@MainActor
public final class QEMUBackendProvider: VMBackendProvider {
    private let networkManager: NetworkManager
    /// The QEMU inside the app. `nil` in a copy of the app that was built without it.
    private let installation: QEMUInstallation?
    /// The service that runs the machines.
    public let service: QEMUService
    /// What on this Mac decides where Windows' Direct3D is drawn, as it is when a machine starts.
    public var directXHost: @MainActor () -> DirectXHost

    public init(
        networkManager: NetworkManager, installation: QEMUInstallation?, service: QEMUService,
        directXHost: @escaping @MainActor () -> DirectXHost = { DirectXHost() }
    ) {
        self.networkManager = networkManager
        self.installation = installation
        self.service = service
        self.directXHost = directXHost
    }

    /// Whether this copy of the app can run machines on QEMU.
    public var isAvailable: Bool { installation != nil }

    /// Whether this copy of the app's QEMU lets a guest draw with the Mac's GPU.
    public var canAccelerateGraphics: Bool { installation?.acceleratesGraphics ?? false }
    /// Whether it lets a Windows guest do so, which takes Direct3D besides.
    public var canAccelerateWindowsGraphics: Bool { canAccelerateGraphics && installation?.supportsDirect3D == true }
    /// Whether it can run Windows' Direct3D on D3DMetal, once that and Rosetta are installed.
    public var canUseD3DMetal: Bool { canAccelerateWindowsGraphics && installation?.supportsD3DMetal == true }

    /// What a Windows guest would draw its Direct3D with on `host`, or `nil` if it can't use the Mac's
    /// GPU at all.
    public func directXBackend(on host: DirectXHost) -> DirectXBackend? {
        guard canAccelerateWindowsGraphics, let installation else { return nil }
        return installation.directXBackend(on: host)
    }

    public func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        guard machine.configuration.engine == .qemu else { throw VMError.unsupportedEngine(machine.configuration.engine) }
        guard let installation else { throw QEMUError.notInstalled }
        let configuration = machine.configuration
        // The service draws a Windows guest's Direct3D where this says, if the guest draws with the GPU.
        let directX: QEMURequest.DirectX? = switch configuration.os.family == .windows ? directXBackend(on: directXHost()) : nil {
        case .d3dMetal(let framework)?: QEMURequest.DirectX(backend: "d3dmetal", framework: framework.path)
        case .dxmt?: QEMURequest.DirectX(backend: "dxmt")
        case nil: nil
        }
        let network = configuration.networkInterfaces.contains(where: \.usesSharedNetwork)
            ? try await networkManager.acquireDefaultNetwork(for: machine.id) : nil
        do {
            let backend = try await QEMUBackend.launch(
                configuration: configuration, bundle: machine.bundle,
                savedState: machine.state == .restoring ? machine.bundle.savedStateURL : nil, installation: installation,
                network: network, console: console, directX: directX,
                refreshRate: Self.displayRefreshRate(forScreens: NSScreen.screens.map(\.maximumFramesPerSecond)), service: service
            )
            // Memory that is saved expects the display it was saved with: the one the service chose.
            if machine.configuration.display.adapter != backend.adapter {
                try? machine.updateConfiguration { $0.display.adapter = backend.adapter }
            }
            return backend
        } catch {
            networkManager.release(user: machine.id)
            throw error
        }
    }

    public func backendDidStop(for machine: VirtualMachine) {
        networkManager.release(user: machine.id)
    }

    /// The most frames a second a guest is asked for: what a Mac's own screen shows at its fastest.
    public static let highestDisplayRefreshRate = 120

    /// The frames a second a guest draws on a Mac whose screens show `rates`: as many as the fastest of
    /// them shows, up to ``highestDisplayRefreshRate``, and 60 on a Mac without a screen. The guest
    /// keeps it for as long as QEMU runs: Windows' 3D driver reads it once, as it starts.
    public static func displayRefreshRate(forScreens rates: [Int]) -> Int {
        guard let fastest = rates.max(), fastest > 0 else { return 60 }
        return min(fastest, highestDisplayRefreshRate)
    }
}
