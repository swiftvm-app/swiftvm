import Foundation

/// A virtual machine on disk: a package directory holding the configuration, disks and firmware state.
public struct VMBundle: Sendable, Hashable {
    public static let pathExtension = "swiftvm"

    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    // MARK: Layout

    public var configurationURL: URL { url.appending(path: "config.json") }
    /// macOS guests: auxiliary storage (NVRAM, boot policy).
    public var auxiliaryStorageURL: URL { url.appending(path: "aux.img") }
    /// macOS guests: the hardware model the guest was installed for.
    public var hardwareModelURL: URL { url.appending(path: "hardware-model.bin") }
    public var machineIdentifierURL: URL { url.appending(path: "machine-identifier.bin") }
    /// Linux and Windows guests: UEFI variable store.
    public var efiVariableStoreURL: URL { url.appending(path: "efi-vars.fd") }
    /// Saved state written when the machine is suspended.
    public var savedStateURL: URL { url.appending(path: "state.vzvmsave") }
    /// cloud-init / unattended setup media.
    public var seedImageURL: URL { url.appending(path: "seed.iso") }
    public var thumbnailURL: URL { url.appending(path: "thumbnail.png") }
    public var snapshotsDirectory: URL { url.appending(path: "snapshots", directoryHint: .isDirectory) }
    public var logsDirectory: URL { url.appending(path: "logs", directoryHint: .isDirectory) }
    public var consoleLogURL: URL { logsDirectory.appending(path: "console.log") }

    public func diskURL(for disk: DiskConfiguration) -> URL {
        url.appending(path: disk.fileName)
    }

    // MARK: Configuration

    public func loadConfiguration() throws -> VMConfiguration {
        let data = try Data(contentsOf: configurationURL)
        return try Self.decoder.decode(VMConfiguration.self, from: data)
    }

    public func save(_ configuration: VMConfiguration) throws {
        let data = try Self.encoder.encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
    }

    /// Creates the bundle directory and writes the initial configuration.
    @discardableResult
    public static func create(at url: URL, configuration: VMConfiguration) throws -> VMBundle {
        let bundle = VMBundle(url: url)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: bundle.url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: bundle.url.path])
        }
        try fileManager.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)
        try bundle.save(configuration)
        return bundle
    }

    // MARK: Duplicating

    /// Copies this machine's disks and firmware into a new bundle at `destination`, for the machine that
    /// `configuration` describes. On APFS the copies share their blocks with the originals.
    ///
    /// What makes this machine itself stays behind: its identifier, saved memory, snapshots and logs. The
    /// copy needs an identifier of its own before it starts.
    @discardableResult
    public func duplicate(to destination: URL, configuration: VMConfiguration) throws -> VMBundle {
        let copy = try VMBundle.create(at: destination, configuration: configuration)
        let fileManager = FileManager.default
        let fileNames = configuration.disks.map(\.fileName) + [
            auxiliaryStorageURL, hardwareModelURL, efiVariableStoreURL, seedImageURL,
        ].map(\.lastPathComponent)
        do {
            for fileName in fileNames where fileManager.fileExists(atPath: url.appending(path: fileName).path) {
                try fileManager.copyItem(at: url.appending(path: fileName), to: copy.url.appending(path: fileName))
            }
        } catch {
            try? fileManager.removeItem(at: copy.url)
            throw error
        }
        return copy
    }

    // MARK: State on disk

    public var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: savedStateURL.path)
    }

    public func removeSavedState() {
        try? FileManager.default.removeItem(at: savedStateURL)
    }

    /// Bytes actually occupied on the host by the given disks (sparse files count only what is allocated).
    public func allocatedSize(of disks: [DiskConfiguration]) -> UInt64 {
        disks.reduce(0) { total, disk in
            let values = try? diskURL(for: disk).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            return total + UInt64(max(size, 0))
        }
    }

    // MARK: Coding

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
