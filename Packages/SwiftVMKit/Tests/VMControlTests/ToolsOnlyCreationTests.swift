import Foundation
import Testing
@testable import VMControl

@Suite struct ToolsOnlyCreationTests {
    @Test func incompatibleCreationRequestsRefuseBeforeBootstrap() {
        for parameters in [
            ControlRequest.CreateParameters(distribution: "debian-13"),
            .init(distribution: "windows"),
            .init(distribution: "macos", installsSSHKey: false),
            .init(distribution: "macos", template: "Existing"),
        ] {
            #expect(parameters.toolsOnlyProblem != nil)
        }
        #expect(ControlRequest.CreateParameters(distribution: "macos").toolsOnlyProblem == nil)
    }

    @Test(arguments: [ControlRequest.Command.createToolsOnly, .createToolsOnlyWithSSHIdentity])
    func toolsOnlyHasItsOwnWireCommand(_ command: ControlRequest.Command) throws {
        let usesExplicitIdentity = command == .createToolsOnlyWithSSHIdentity
        let request = ControlRequest(
            command: command,
            create: .init(distribution: "macos", sshIdentityPath: usesExplicitIdentity ? "/tmp/test-identity" : nil)
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == (usesExplicitIdentity ? "create-tools-only-with-ssh-identity" : "create-tools-only"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
    }
}
