import Foundation
import VMControl

/// The public CLI result for the control commands that support `--json`.
struct ControlJSONResult: Encodable {
    static let commands: Set<String> = [
        "list", "ls", "info", "start", "stop", "restart", "suspend", "pause", "resume", "force-stop", "discard-state", "wait", "network",
    ]

    struct Failure: Encodable {
        enum Kind: String, Encodable { case arguments, connection, server }
        let kind: Kind
        let message: String
    }

    let schemaVersion = 1
    let command: String
    let ok: Bool
    let machines: [MachineSummary]
    let creations: [CreationSummary]?
    let note: String?
    let error: Failure?

    init(command: String, response: ControlResponse) {
        self.command = command == "ls" ? "list" : command
        self.ok = response.ok
        self.machines = response.machines
        self.creations = response.creations
        self.note = response.note
        self.error = response.ok ? nil : Failure(kind: .server, message: response.error ?? "The command failed.")
    }

    init(command: String, kind: Failure.Kind, message: String) {
        self.command = command == "ls" ? "list" : command
        self.ok = false
        self.machines = []
        self.creations = nil
        self.note = nil
        self.error = Failure(kind: kind, message: message)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data([0x0A])
    }
}
