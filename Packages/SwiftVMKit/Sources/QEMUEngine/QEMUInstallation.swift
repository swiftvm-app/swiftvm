import Foundation

/// The QEMU that runs Windows guests and Linux guests with graphics acceleration, as it comes inside the
/// app: its program with the libraries it loads in `Contents/Helpers/QEMU`, and its firmware in
/// `Contents/Resources/QEMU`. `swiftvm serve` runs it (crates/swiftvm-qemu); the app looks at what it can
/// do, and loads its display library.
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
        FileManager.default.fileExists(atPath: dxmtLibrary.path)
    }

    /// Whether it has d3dmetal-native, with which the render server's Intel half runs Windows' Direct3D
    /// on D3DMetal, once the user has installed that. It comes with Direct3D.
    public var supportsD3DMetal: Bool {
        FileManager.default.fileExists(atPath: d3dMetalLibrary.path)
    }

    /// What a Windows guest that draws with the Mac's GPU replays its Direct3D on: D3DMetal, which has
    /// Direct3D 12, wherever it can run, and DXMT otherwise.
    public func directXBackend(on host: DirectXHost) -> DirectXBackend {
        guard !host.prefersDXMT, supportsD3DMetal, host.hasRosetta, let framework = host.d3dMetalFramework else { return .dxmt }
        return .d3dMetal(framework: framework)
    }

    var libraryDirectory: URL { program.deletingLastPathComponent().deletingLastPathComponent().appending(path: "lib") }
    var displayLibrary: URL { libraryDirectory.appending(path: "libSwiftVMDisplay.dylib") }
    var dxmtLibrary: URL { libraryDirectory.appending(path: "libdxmt-native.dylib") }
    var d3dMetalLibrary: URL { libraryDirectory.appending(path: "libd3dmetal-native.dylib") }

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
