import Foundation

/// Hands each machine to the engine its configuration names: the Virtualization framework for macOS
/// and Linux guests, QEMU for Windows guests.
@MainActor
public final class BackendRouter: VMBackendProvider {
    private let providers: [VMEngineKind: any VMBackendProvider]
    /// Updates files the guest reads before either engine opens them, including after a snapshot restore.
    public var prepareMachine: (@MainActor (VirtualMachine) async throws -> Void)?

    public init(providers: [VMEngineKind: any VMBackendProvider]) {
        self.providers = providers
    }

    public func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        guard let provider = providers[machine.configuration.engine] else {
            throw VMError.unsupportedEngine(machine.configuration.engine)
        }
        try await prepareMachine?(machine)
        return try await provider.makeBackend(for: machine, console: console)
    }

    public func backendDidStop(for machine: VirtualMachine) {
        providers[machine.configuration.engine]?.backendDidStop(for: machine)
    }
}
