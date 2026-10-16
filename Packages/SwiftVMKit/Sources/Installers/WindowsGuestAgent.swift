import Foundation
import VMCore

/// The guest agent for Windows and the ways it gets into a guest.
///
/// The agent is C# source (`Resources/GuestAgentWindows`) that the guest compiles itself, with the
/// compiler that comes with Windows: the Mac that builds SwiftVM needs nothing to build it, as with the
/// Python agent for Linux. A new machine's setup installs it. A machine that was installed from a disc
/// of its own gets it from the guest tools disc, together with the drivers on the virtio-win disc.
public enum WindowsGuestAgent {
    /// The volume label of the guest tools disc.
    public static let toolsVolumeName = "SWIFTVM"

    /// What a person does in the guest to install from the guest tools disc.
    public static let toolsInstallCommand = "Open the SWIFTVM disc in File Explorer and run install.cmd."

    /// The files the agent is made of, by the names they have in a guest, and the resources they are.
    static let files: [(name: String, resource: String)] = [
        ("swiftvm-agent.cs", "swiftvm-agent.cs"),
        ("install.ps1", "windows-install.ps1"),
    ]

    static func resource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: name)
        guard let found = Bundle.module.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension),
              let text = try? String(contentsOf: found, encoding: .utf8)
        else { throw LinuxGuestAgent.AgentError.missingResource(name) }
        return text
    }

    /// The version of the agent this build carries, as the agent reports it when it connects.
    public static let version: String? = (try? resource("swiftvm-agent.cs")).flatMap(version(ofSource:))

    static func version(ofSource source: String) -> String? {
        for line in source.split(separator: "\n") where line.contains("const string Version") {
            let parts = line.split(separator: "\"")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    /// The files a new machine's setup disc carries in its `swiftvm` folder: the agent, its installer,
    /// and the runner that Windows Setup starts.
    static func setupFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for file in Self.files + [("setup.ps1", "windows-setup.ps1")] {
            files[file.name] = Data(windowsLines(try resource(file.resource)).utf8)
        }
        try addGraphicsDriver(to: &files)
        return files
    }

    /// The files on the guest tools disc.
    static func toolsFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for file in Self.files + [("install.cmd", "windows-install.cmd"), ("README.txt", "windows-readme.txt")] {
            files[file.name] = Data(windowsLines(try resource(file.resource)).utf8)
        }
        try addGraphicsDriver(to: &files)
        return files
    }

    private static func addGraphicsDriver(to files: inout [String: Data]) throws {
        guard let resources = Bundle.main.resourceURL else { return }
        let driver = resources.appending(path: "QEMU/share/viogpu3d-arm64x-signed.zip")
        if FileManager.default.fileExists(atPath: driver.path) {
            files["graphics-driver.zip"] = try Data(contentsOf: driver)
        }
    }

    /// Text with the line breaks Windows' own tools expect, whichever it was written with.
    static func windowsLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Makes sure the guest tools disc for this build's agent is in `directory` and returns it. Discs
    /// of other builds are cleared away unless they are among `inUse`.
    public static func toolsImage(in directory: URL, inUse: Set<String> = []) throws -> URL {
        try GuestToolsDisc.image(prefix: toolsImagePrefix, volumeName: toolsVolumeName, files: toolsFiles(), in: directory, inUse: inUse)
    }

    static let toolsImagePrefix = "SwiftVM Windows Guest Tools "

    /// Whether `path` is a guest tools disc made by ``toolsImage(in:inUse:)``.
    public static func isToolsImage(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix(toolsImagePrefix) && name.hasSuffix(".iso")
    }
}
