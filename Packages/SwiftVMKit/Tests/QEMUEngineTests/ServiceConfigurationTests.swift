import Foundation
import Testing
import VMCore

/// `swiftvm serve` reads a QEMU machine's `config.json` as the app writes it. The fixture is shared with
/// crates/swiftvm-qemu/tests/engine.rs.
@Suite struct ServiceConfigurationTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "crates/swiftvm-protocol/tests/fixtures/machine/config.json")

    @Test func theAppReadsAndWritesTheConfigurationTheServiceReads() throws {
        let data = try Data(contentsOf: Self.fixture)
        let configuration = try JSONDecoder().decode(VMConfiguration.self, from: data)
        #expect(configuration.engine == .qemu && configuration.os.family == .windows)
        #expect(configuration.display.adapter == .virtioGPU)
        #expect(configuration.networkInterfaces.map(\.isConnected) == [true, false])
        #expect(configuration.removableImages.count == 2 && configuration.disks.first?.format == .raw)
        // What the app writes back has every field the service reads, by the same names.
        let written = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        let original = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["id", "name", "os", "engine", "cpuCount", "memorySize", "disks", "removableImages", "display", "networkInterfaces", "sharedFolders", "audio", "boot", "installation"] {
            #expect((written[key] as AnyObject).isEqual(original[key]), "\(key)")
        }
    }
}
