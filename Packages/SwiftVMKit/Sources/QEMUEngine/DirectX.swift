import Foundation

/// Where a Windows guest's Direct3D is drawn on the Mac. Windows' 3D driver hands its Direct3D calls to
/// virglrenderer's render server, which replays them on one of these.
public enum DirectXBackend: Sendable, Hashable {
    /// DXMT, which turns Direct3D 11 into Metal, natively. It has no Direct3D 12.
    case dxmt
    /// Apple's D3DMetal, from the Game Porting Toolkit, in the render server's Intel half under Rosetta:
    /// Direct3D 11 and 12, and with Direct3D 12 what Windows maps onto it, OpenGL among it.
    case d3dMetal(framework: URL)

    /// Whether guests get Direct3D 12.
    public var supportsDirect3D12: Bool {
        if case .d3dMetal = self { true } else { false }
    }
}

/// What on this Mac, besides the app's own QEMU, decides a Windows guest's ``DirectXBackend``.
public struct DirectXHost: Sendable, Hashable {
    /// The D3DMetal that was installed with ``D3DMetal/install(from:into:)``, if any.
    public var d3dMetalFramework: URL?
    /// Whether Rosetta is installed, which D3DMetal runs under.
    public var hasRosetta: Bool
    /// Every guest draws with DXMT, even where D3DMetal could be used.
    public var prefersDXMT: Bool

    public init(d3dMetalFramework: URL? = nil, hasRosetta: Bool = false, prefersDXMT: Bool = false) {
        self.d3dMetalFramework = d3dMetalFramework
        self.hasRosetta = hasRosetta
        self.prefersDXMT = prefersDXMT
    }
}

/// Apple's D3DMetal.framework, which comes with the Game Porting Toolkit. Apple's licence keeps the app
/// from bringing it: the user downloads the toolkit, and the app keeps a copy of the framework they
/// point it at, in the folder they choose with it.
public enum D3DMetal {
    public enum Failure: Error, LocalizedError, Equatable {
        case notFound(String)
        /// What was chosen holds the disk image that has D3DMetal, named here, rather than D3DMetal.
        case insideDiskImage(String)
        case notForIntel(String)
        /// macOS's software update couldn't install Rosetta, in its own words.
        case rosetta(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path):
                "There's no D3DMetal.framework in “\(path)”. Open the Game Porting Toolkit's “Evaluation environment for Windows games” disk image, and choose it."
            case .insideDiskImage(let name):
                "D3DMetal is in “\(name)”, inside this disk image. Open that one too, and choose it."
            case .notForIntel(let path):
                "“\(path)” isn't the D3DMetal that the Game Porting Toolkit brings: it has no code for Intel processors."
            case .rosetta(let reason):
                "Rosetta couldn't be installed. \(reason)"
            }
        }
    }

    /// Where the framework can be in what the user chooses: the framework itself, the toolkit's
    /// "Evaluation environment for Windows games" disk image, or a folder of it, such as its `redist`
    /// folder or a copy of `lib/external`.
    static let candidates = [
        "", "D3DMetal.framework", "redist/lib/external/D3DMetal.framework", "lib/external/D3DMetal.framework",
        "external/D3DMetal.framework",
    ]

    /// The framework in `chosen`, if there is one.
    ///
    /// - Throws: ``Failure/notForIntel(_:)`` for a framework of that name without the code D3DMetal
    ///   has, which runs only on Intel.
    public static func locate(in chosen: URL) throws -> URL? {
        for path in candidates {
            let framework = path.isEmpty ? chosen : chosen.appending(path: path, directoryHint: .isDirectory)
            guard framework.lastPathComponent == "D3DMetal.framework", let binary = binary(of: framework) else { continue }
            guard architectures(of: binary).contains(cpuTypeX86_64) else { throw Failure.notForIntel(framework.path) }
            return framework
        }
        return nil
    }

    /// The framework's program, which the render server loads.
    static func binary(of framework: URL) -> URL? {
        let fileManager = FileManager.default
        return [framework.appending(path: "D3DMetal"), framework.appending(path: "Versions/A/D3DMetal")]
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Copies the framework in `chosen` into `directory`, in place of one that is there already, and
    /// returns the copy. What came from a download loses its quarantine: the render server loads it
    /// without asking anyone.
    @discardableResult
    public static func install(from chosen: URL, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        guard let source = try locate(in: chosen) else {
            // The toolkit comes as a disk image with the one that has D3DMetal inside it.
            let inner = (try? fileManager.contentsOfDirectory(atPath: chosen.path))?
                .first { $0.hasPrefix("Evaluation environment") && $0.hasSuffix(".dmg") }
            throw inner.map(Failure.insideDiskImage) ?? Failure.notFound(chosen.path)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".D3DMetal-\(UUID().uuidString).framework", directoryHint: .isDirectory)
        do {
            // A copy that stops halfway, when the disk is full or the image is ejected, goes too.
            try fileManager.copyItem(at: source, to: staging)
            removeQuarantine(from: staging)
            let destination = framework(in: directory)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// The framework installed in `directory`, if it is there and whole.
    public static func installed(in directory: URL) -> URL? {
        let framework = framework(in: directory)
        guard let binary = binary(of: framework), architectures(of: binary).contains(cpuTypeX86_64) else { return nil }
        return framework
    }

    public static func remove(from directory: URL) throws {
        let framework = framework(in: directory)
        if FileManager.default.fileExists(atPath: framework.path) {
            try FileManager.default.removeItem(at: framework)
        }
    }

    /// The version of the framework, as the toolkit names it, such as 3.0.
    public static func version(of framework: URL) -> String? {
        for path in ["Resources/version.plist", "Resources/Info.plist", "Versions/A/Resources/Info.plist"] {
            guard let data = try? Data(contentsOf: framework.appending(path: path)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = plist["CFBundleShortVersionString"] as? String
            else { continue }
            return version
        }
        return nil
    }

    static func framework(in directory: URL) -> URL {
        directory.appending(path: "D3DMetal.framework", directoryHint: .isDirectory)
    }

    private static func removeQuarantine(from url: URL) {
        let fileManager = FileManager.default
        var paths = [url.path]
        if let items = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
            paths += items.compactMap { ($0 as? URL)?.path }
        }
        for path in paths {
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    // MARK: Rosetta

    /// Whether this Mac runs programs for Intel processors, as D3DMetal is, with Rosetta. The
    /// Virtualization framework's availability of Rosetta doesn't say: that is the Rosetta for Linux
    /// guests, which macOS installs apart from the one for the Mac's own programs. So a program for
    /// Intel is run, one that does nothing. It takes a moment.
    public static func isRosettaInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    /// Installs Rosetta with macOS's software update, which takes an administrator: macOS asks for
    /// one's password. Whoever asks for this agrees to Apple's licence for Rosetta, which software
    /// update otherwise asks for in Terminal. Cancelling the password is no failure.
    public static func installRosetta() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges",
        ]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status != 0 else { return }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // -128: the password was cancelled.
        guard !said.contains("(-128)") else { return }
        throw Failure.rosetta(said)
    }

    // MARK: Mach-O

    static let cpuTypeX86_64: Int32 = 0x0100_0007
    static let cpuTypeARM64: Int32 = 0x0100_000C

    /// The processors the Mach-O file at `url` has code for: one for a thin file, each half's for a
    /// universal one. Nothing for anything else.
    static func architectures(of url: URL) -> Set<Int32> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        return architectures(ofHeader: (try? handle.read(upToCount: 4096)) ?? Data())
    }

    static func architectures(ofHeader data: Data) -> Set<Int32> {
        let bytes = [UInt8](data)
        func little(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        func big(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return (0..<4).reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
        }
        switch big(0) {
        case 0xCFFA_EDFE?:
            // A thin 64-bit file, little-endian as the Mac's processors are.
            return little(4).map { [Int32(bitPattern: $0)] } ?? []
        case 0xCAFE_BABE?, 0xCAFE_BABF?:
            // A universal file: big-endian, with a record for each half. The 64-bit kind's are larger.
            let size = big(0) == 0xCAFE_BABE ? 20 : 32
            guard let count = big(4), count < 32 else { return [] }
            return Set((0..<Int(count)).compactMap { big(8 + $0 * size).map { Int32(bitPattern: $0) } })
        default:
            return []
        }
    }
}
