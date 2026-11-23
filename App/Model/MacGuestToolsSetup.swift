/// Keeps tool installation distinct from the optional desktop permission step and its failures.
@MainActor
enum MacGuestToolsSetup {
    enum Failure: Error {
        case installation(any Error)
        case permissions(any Error)
    }

    static func run(
        setsUpDesktopPermissions: Bool,
        install: () async throws -> Void,
        allow: () async throws -> Void
    ) async -> Result<Void, Failure> {
        do {
            try await install()
        } catch {
            return .failure(.installation(error))
        }
        if setsUpDesktopPermissions {
            do {
                try await allow()
            } catch {
                return .failure(.permissions(error))
            }
        }
        return .success(())
    }
}
