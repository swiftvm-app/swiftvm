import Foundation
import Testing
import VMControl
@testable import SwiftVMCLI

@Suite struct ControlJSONResultTests {
    private func object(_ result: ControlJSONResult) throws -> [String: Any] {
        let data = try result.encoded()
        #expect(data.last == 0x0A)
        #expect(data.filter { $0 == 0x0A }.count == 1)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func emptyLibraryHasOneVersionedResultAndAnArray() throws {
        let result = try object(ControlJSONResult(command: "ls", response: ControlResponse(ok: true)))
        #expect(result["schemaVersion"] as? Int == 1)
        #expect(result["command"] as? String == "list")
        #expect(result["ok"] as? Bool == true)
        #expect((result["machines"] as? [Any])?.isEmpty == true)
        #expect(Set(result.keys) == ["schemaVersion", "command", "ok", "machines"])
    }

    @Test func identitiesConfigurationAndByteUnitsSurviveRendering() throws {
        let first = UUID(), second = UUID()
        let details = MachineDetails(location: "/tmp/Box.swiftvm", macAddress: nil, drives: [], sharedFolders: [], snapshotCount: 2)
        let machines = [first, second].map { id in
            MachineSummary(
                id: id, name: "Same name", state: "stopped", system: "Linux", address: nil, sshAlias: nil,
                cpuCount: 2, memorySize: 4 << 30, diskAllocated: 512, diskCapacity: 16 << 30, details: details
            )
        }
        let result = try object(ControlJSONResult(command: "info", response: ControlResponse(ok: true, machines: machines)))
        let rendered = try #require(result["machines"] as? [[String: Any]])
        #expect(rendered.map { $0["id"] as? String } == [first.uuidString, second.uuidString])
        #expect(rendered[0]["memorySize"] as? UInt64 == 4 << 30)
        #expect(rendered[1]["diskCapacity"] as? UInt64 == 16 << 30)
        #expect((rendered[0]["details"] as? [String: Any])?["snapshotCount"] as? Int == 2)
    }

    @Test(arguments: [ControlJSONResult.Failure.Kind.arguments, .connection, .server])
    func failuresUseTheSameEnvelope(_ kind: ControlJSONResult.Failure.Kind) throws {
        let result = try object(ControlJSONResult(command: "start", kind: kind, message: "couldn't start\ntry later"))
        #expect(result["ok"] as? Bool == false)
        #expect((result["machines"] as? [Any])?.isEmpty == true)
        let failure = try #require(result["error"] as? [String: String])
        #expect(failure == ["kind": kind.rawValue, "message": "couldn't start\ntry later"])
    }

    @Test func serverRefusalAndRemainingActionsArePreserved() throws {
        let result = try object(ControlJSONResult(command: "stop", response: ControlResponse(ok: false, error: "not stopped", note: "answer in the guest")))
        #expect(result["ok"] as? Bool == false)
        #expect(result["note"] as? String == "answer in the guest")
        #expect(result["error"] as? [String: String] == ["kind": "server", "message": "not stopped"])
    }

    @Test func creationProgressSurvivesButUnrelatedProtocolResultsStayOut() throws {
        let creation = CreationSummary(name: "Box", system: "Linux", status: "downloading", fraction: 0.5, error: nil)
        let response = ControlResponse(ok: true, snapshots: [], note: "still installing", templates: [], creations: [creation])
        let result = try object(ControlJSONResult(command: "list", response: response))
        let creations = try #require(result["creations"] as? [[String: Any]])
        #expect(creations[0]["fraction"] as? Double == 0.5)
        #expect(result["note"] as? String == "still installing")
        #expect(result["templates"] == nil && result["snapshots"] == nil)
    }
}
