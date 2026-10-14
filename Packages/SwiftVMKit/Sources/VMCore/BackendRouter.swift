import Foundation

/// Hands each machine to the engine its configuration names: the Virtualization framework for macOS
/// and Linux guests, QEMU for Windows guests.
@MainActor
public final class BackendRouter: VMBackendProvider {
    private let providers: [VMEngineKind: any VMBackendProvider]

    public init(providers: [VMEngineKind: any VMBackendProvider]) {
        self.providers = providers
    }

    public func makeBackend(for machine: VirtualMachine, console: SerialConsole.GuestEnd) async throws -> any VMBackend {
        guard let provider = providers[machine.configuration.engine] else {
            throw VMError.unsupportedEngine(machine.configuration.engine)
        }
        return try await provider.makeBackend(for: machine, console: console)
    }

    public func backendDidStop(for machine: VirtualMachine) {
        providers[machine.configuration.engine]?.backendDidStop(for: machine)
    }
}
