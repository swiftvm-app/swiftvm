import Foundation

/// The QEMU that runs Windows guests and Linux guests with graphics acceleration, as it comes inside the
/// app: its program with the libraries it loads in `Contents/Helpers/QEMU`, and its firmware in
/// `Contents/Resources/QEMU`.
///
/// `scripts/build-qemu.sh` builds it and `scripts/bundle-app.sh` puts it there. A copy of the app that
/// was built without it runs every other guest.
public struct QEMUInstallation: Sendable, Hashable {
    /// `qemu-system-aarch64`.
    public var program: URL
    /// The folder QEMU looks for its data in: the firmware and the keyboard layout its VNC server wants.
    public var dataDirectory: URL
    /// Whether it has what lets a guest draw with the Mac's GPU: SPICE with OpenGL, and the library the
    /// app shows such a guest's screen with.
    public var acceleratesGraphics: Bool

    public init(program: URL, dataDirectory: URL, acceleratesGraphics: Bool = false) {
        self.program = program
        self.dataDirectory = dataDirectory
        self.acceleratesGraphics = acceleratesGraphics
    }

    /// Whether it has DXMT, which Windows' Direct3D goes through. Custom builds can leave it out.
    public var supportsDirect3D: Bool {
        FileManager.default.fileExists(atPath: libraryDirectory.appending(path: "libdxmt-native.dylib").path)
    }

    var libraryDirectory: URL { program.deletingLastPathComponent().deletingLastPathComponent().appending(path: "lib") }
    var displayLibrary: URL { libraryDirectory.appending(path: "libSwiftVMDisplay.dylib") }

    func environment(in directory: URL) -> [String: String] {
        guard acceleratesGraphics else { return [:] }
        let dxmt = libraryDirectory.appending(path: "libdxmt-native.dylib").path
        return [
            "ANGLE_DEFAULT_PLATFORM": "metal", "NPT_BACKEND": "dxmt",
            "NPT_D3D11_LIBRARY_PATH": dxmt, "NPT_D3D12_LIBRARY_PATH": dxmt, "NPT_DXGI_LIBRARY_PATH": dxmt,
            "RENDER_SERVER_EXEC_PATH": program.deletingLastPathComponent().appending(path: "virgl_render_server").path,
            "XDG_RUNTIME_DIR": directory.path,
        ]
    }

    /// The UEFI firmware, without the padding of the machine's flash.
    public var firmware: URL { dataDirectory.appending(path: "edk2-aarch64-code.fd") }
    /// What a machine's own UEFI variables start out as, without padding either.
    public var variablesTemplate: URL { dataDirectory.appending(path: "edk2-arm-vars.fd") }

    /// The QEMU inside `bundle`, or `nil` if that copy of the app was built without it.
    public static func inApp(_ bundle: Bundle = .main) -> QEMUInstallation? {
        let contents = bundle.bundleURL.appending(path: "Contents")
        var installation = QEMUInstallation(
            program: contents.appending(path: "Helpers/QEMU/bin/qemu-system-aarch64"),
            dataDirectory: contents.appending(path: "Resources/QEMU/share")
        )
        installation.acceleratesGraphics = FileManager.default.fileExists(atPath: installation.displayLibrary.path)
        return installation.isComplete ? installation : nil
    }

    /// Whether everything a machine needs is there.
    public var isComplete: Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: program.path) && fileManager.fileExists(atPath: firmware.path)
            && fileManager.fileExists(atPath: variablesTemplate.path)
            && (!acceleratesGraphics || fileManager.fileExists(atPath: displayLibrary.path))
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
            "This copy of SwiftVM was built without QEMU, which runs Windows guests and Linux guests with graphics acceleration."
        case .didNotStart(let reason):
            "QEMU couldn't start the virtual machine. \(reason)"
        case .refused(let reason):
            "QEMU refused: \(reason)"
        case .disconnected:
            "QEMU has stopped."
        }
    }
}
