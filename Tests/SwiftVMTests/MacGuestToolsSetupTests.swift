import Testing
@testable import SwiftVM

@MainActor
@Suite struct MacGuestToolsSetupTests {
    private enum Failure: Error { case install, allow }

    @Test(arguments: [false, true])
    func installationRunsBeforeOptionalPermissionSetup(_ setsUpDesktopPermissions: Bool) async throws {
        var steps: [String] = []
        let result = await MacGuestToolsSetup.run(
            setsUpDesktopPermissions: setsUpDesktopPermissions,
            install: { steps.append("install") }, allow: { steps.append("allow") }
        )
        try result.get()
        #expect(steps == (setsUpDesktopPermissions ? ["install", "allow"] : ["install"]))
    }

    @Test func failedInstallationNeverAttemptsDesktopSetup() async {
        var wasAsked = false
        let result = await MacGuestToolsSetup.run(
            setsUpDesktopPermissions: true,
            install: { throw Failure.install }, allow: { wasAsked = true }
        )
        guard case .failure(.installation(let error)) = result else { Issue.record("The installation failure was lost."); return }
        #expect(error as? Failure == .install)
        #expect(!wasAsked)
    }

    @Test func permissionRefusalKeepsInstallationSuccessful() async {
        var wasInstalled = false
        let result = await MacGuestToolsSetup.run(
            setsUpDesktopPermissions: true,
            install: { wasInstalled = true }, allow: { throw Failure.allow }
        )
        guard case .failure(.permissions(let error)) = result else { Issue.record("The permission failure was lost."); return }
        #expect(error as? Failure == .allow)
        #expect(wasInstalled)
    }
}
