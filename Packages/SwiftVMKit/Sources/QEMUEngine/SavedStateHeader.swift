import Foundation

/// What a restore needs to know besides what QEMU saved of a machine: the USB port each drive was in,
/// which QEMU tells USB devices apart by.
///
/// A snapshot copies the saved state's one file, so this is at the start of that file, and QEMU's own
/// part comes after it, from ``size`` on: a line that says what the file is, this as JSON, and zeros.
struct SavedStateHeader: Equatable {
    /// Where QEMU's part of the file starts.
    static let size = 4096
    private static let signature = Data("SwiftVM QEMU machine state 1\n".utf8)

    /// The USB port of each drive and disk on USB, by its identifier.
    var usbPorts: [UUID: Int]

    private struct Contents: Codable {
        var usbPorts: [String: Int]
    }

    /// Writes this over the start of a saved state that QEMU has written the rest of.
    func write(into url: URL) throws {
        let contents = Contents(usbPorts: Dictionary(uniqueKeysWithValues: usbPorts.map { ($0.key.uuidString, $0.value) }))
        let data = Self.signature + (try JSONEncoder().encode(contents))
        guard data.count < Self.size else { throw QEMUError.refused("The machine has too many drives to save its state.") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
    }

    static func read(from url: URL) throws -> SavedStateHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: size) ?? Data()
        guard data.starts(with: signature),
              let contents = try? JSONDecoder().decode(Contents.self, from: data.dropFirst(signature.count).prefix { $0 != 0 })
        else {
            throw QEMUError.didNotStart("Its saved state isn't one that SwiftVM can resume.")
        }
        var ports: [UUID: Int] = [:]
        for (key, port) in contents.usbPorts {
            if let id = UUID(uuidString: key) { ports[id] = port }
        }
        return SavedStateHeader(usbPorts: ports)
    }
}
