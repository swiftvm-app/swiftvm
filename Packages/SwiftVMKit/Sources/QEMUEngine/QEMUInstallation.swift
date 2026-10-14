import Foundation

/// The QEMU that runs Windows guests, as it comes inside the app: its program with the libraries it
/// loads in `Contents/Helpers/QEMU`, and its firmware in `Contents/Resources/QEMU`.
///
/// `scripts/build-qemu.sh` builds it and `scripts/bundle-app.sh` puts it there. A copy of the app that
/// was built without it runs every other guest.
public struct QEMUInstallation: Sendable, Hashable {
    /// `qemu-system-aarch64`.
    public var program: URL
    /// The folder QEMU looks for its data in: the firmware and the keyboard layout its VNC server wants.
    public var dataDirectory: URL

    public init(program: URL, dataDirectory: URL) {
        self.program = program
        self.dataDirectory = dataDirectory
    }

    /// The UEFI firmware, without the padding of the machine's flash.
    public var firmware: URL { dataDirectory.appending(path: "edk2-aarch64-code.fd") }
    /// What a machine's own UEFI variables start out as, without padding either.
    public var variablesTemplate: URL { dataDirectory.appending(path: "edk2-arm-vars.fd") }

    /// The QEMU inside `bundle`, or `nil` if that copy of the app was built without it.
    public static func inApp(_ bundle: Bundle = .main) -> QEMUInstallation? {
        let contents = bundle.bundleURL.appending(path: "Contents")
        let installation = QEMUInstallation(
            program: contents.appending(path: "Helpers/QEMU/bin/qemu-system-aarch64"),
            dataDirectory: contents.appending(path: "Resources/QEMU/share")
        )
        return installation.isComplete ? installation : nil
    }

    /// Whether everything a machine needs is there.
    public var isComplete: Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: program.path) && fileManager.fileExists(atPath: firmware.path)
            && fileManager.fileExists(atPath: variablesTemplate.path)
    }

    /// The size of the flash a machine's variables are kept in. QEMU takes nothing else.
    static let variableStoreSize: UInt64 = 64 << 20

    /// Writes a fresh store of UEFI variables for a new machine at `url`. It is as large as the flash,
    /// and as sparse as the file system allows: nearly all of it is never written.
    public func makeVariableStore(at url: URL) throws {
        let template = try Data(contentsOf: variablesTemplate)
        try template.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: Self.variableStoreSize)
    }
}

public enum QEMUError: Error, LocalizedError, Equatable {
    /// This copy of the app was built without QEMU.
    case notInstalled
    /// QEMU couldn't be started, or stopped before it was up.
    case didNotStart(String)
    /// QEMU said no to something it was asked, in its own words.
    case refused(String)
    /// The line to QEMU is gone: it has stopped.
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "This copy of SwiftVM was built without QEMU, which runs Windows guests."
        case .didNotStart(let reason):
            "QEMU couldn't start the virtual machine. \(reason)"
        case .refused(let reason):
            "QEMU refused: \(reason)"
        case .disconnected:
            "QEMU has stopped."
        }
    }
}
