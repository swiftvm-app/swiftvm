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

    /// A file that goes into a copy of a machine, and where it is taken from.
    struct PortableFile: Sendable {
        /// Its name in a bundle.
        let name: String
        let url: URL
    }

    /// The files a copy of this machine is made of: its disks, its firmware and its first-boot data, as
    /// they are now or, with `snapshot`, as they were then. What makes this machine itself is not among
    /// them: its identifier, saved memory, snapshots and logs.
    func portableFiles(for configuration: VMConfiguration, at snapshot: VMSnapshot? = nil) -> [PortableFile] {
        // What a snapshot holds of the machine. The rest never changes, and is in the bundle itself.
        let state = Set(
            configuration.disks.filter { !$0.readOnly }.map(\.fileName)
                + [auxiliaryStorageURL, efiVariableStoreURL].map(\.lastPathComponent)
        )
        let names = configuration.disks.map(\.fileName) + [
            auxiliaryStorageURL, hardwareModelURL, efiVariableStoreURL, seedImageURL,
        ].map(\.lastPathComponent)
        return names
            .map { name in
                let folder = snapshot.flatMap { state.contains(name) ? snapshotURL(for: $0.id) : nil } ?? url
                return PortableFile(name: name, url: folder.appending(path: name))
            }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Copies this machine's disks and firmware into a new bundle at `destination`, for the machine that
    /// `configuration` describes. On APFS the copies share their blocks with the originals.
    ///
    /// What makes this machine itself stays behind: its identifier, saved memory, snapshots and logs. The
    /// copy needs an identifier of its own before it starts.
    ///
    /// - Parameters:
    ///   - progress: Called on the copying thread with how far the copy has come, from 0 to 1, where
    ///     the files have to be written out.
    ///   - isCancelled: Asked while copying. Once it says yes the copy stops with a `CancellationError`.
    @discardableResult
    public func duplicate(
        to destination: URL, configuration: VMConfiguration, progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> VMBundle {
        let copy = try VMBundle.create(at: destination, configuration: configuration)
        do {
            try Self.copy(portableFiles(for: configuration), into: copy.url, progress: progress, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: copy.url)
            throw error
        }
        return copy
    }

    /// Copies `files` into `folder`, which has none of them yet. On a disk that can, a copy shares its
    /// blocks with the original and takes no time. Anywhere else the files are written out, which takes
    /// as long as they are full: a disk image's empty space stays empty, as it does when a machine moves
    /// (``copy(to:cloning:progress:isCancelled:)``).
    static func copy(
        _ files: [PortableFile], into folder: URL, progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws {
        let total = files.reduce(UInt64(0)) { total, file in
            let values = try? file.url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return total + UInt64(max(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0, 0))
        }
        let tracker = CopyTracker(total: total, progress: progress, isCancelled: isCancelled)
        let flags = COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_DATA_SPARSE
        for file in files {
            // A file that shares its blocks is there at once, with nobody asked in between.
            let code = isCancelled()
                ? ECANCELED
                : copyItem(at: file.url, to: folder.appending(path: file.name), flags: flags, tracker: tracker)
            if let code {
                throw code == ECANCELED ? CancellationError() : POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            tracker.finishFile()
        }
        progress?(1)
    }

    // MARK: Moving to another disk

    /// Bytes everything in the bundle occupies on the host: its disks, its snapshots and the rest.
    public var totalAllocatedSize: UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += UInt64(max(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0, 0))
        }
        return total
    }

    /// Copies the whole bundle to `destination`, where nothing may be yet, for a machine that is going to
    /// another disk. What was copied is removed again if the copy doesn't finish.
    ///
    /// A disk image is mostly empty space that takes up none. `FileManager` writes all of that out on a
    /// disk it can't clone to, so this copies with `copyfile`, which leaves the empty space empty.
    ///
    /// The copy is on its disk for good when this returns, not on its way there: whoever asked may be
    /// about to remove the original, and an external disk can be pulled out a moment later.
    ///
    /// - Parameters:
    ///   - cloning: Share blocks with the original where the disk can, which then takes no time.
    ///   - progress: Called on the copying thread with how far the copy has come, from 0 to 1.
    ///   - isCancelled: Asked while copying. Once it says yes the copy stops with a `CancellationError`.
    @discardableResult
    public func copy(
        to destination: URL, cloning: Bool = true, progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> VMBundle {
        let copy = VMBundle(url: destination)
        guard !FileManager.default.fileExists(atPath: copy.url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: copy.url.path])
        }
        let tracker = CopyTracker(total: totalAllocatedSize, progress: progress, isCancelled: isCancelled)
        var flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_DATA_SPARSE
        if cloning {
            flags |= COPYFILE_CLONE
        }
        if let code = Self.copyItem(at: url, to: copy.url, flags: flags, tracker: tracker) {
            try? FileManager.default.removeItem(at: copy.url)
            if code == ECANCELED {
                throw CancellationError()
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        do {
            try copy.flushToDisk()
        } catch {
            try? FileManager.default.removeItem(at: copy.url)
            throw error
        }
        progress?(1)
        return copy
    }

    /// Copies the file or folder at `source` to `destination` with `copyfile`, which tells `tracker` how
    /// far it has come and asks it whether to go on.
    ///
    /// - Returns: What went wrong, as an `errno`, or `nil`.
    private static func copyItem(at source: URL, to destination: URL, flags: Int32, tracker: CopyTracker) -> Int32? {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let tracker = Unmanaged<CopyTracker>.fromOpaque(context).takeUnretainedValue()
            if stage == COPYFILE_ERR {
                // Left to itself, a copy of a folder carries on past a file it couldn't copy and
                // reports success.
                tracker.fail(with: errno)
                return COPYFILE_QUIT
            }
            if tracker.isCancelled() {
                tracker.fail(with: ECANCELED)
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                tracker.report(bytesOfCurrentFile: UInt64(max(copied, 0)))
            } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                tracker.finishFile()
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(tracker).toOpaque())
        let result = withExtendedLifetime(tracker) { copyfile(source.path, destination.path, state, copyfile_flags_t(flags)) }
        return tracker.failure ?? (result == 0 ? nil : errno)
    }

    /// Has every file of the bundle written out to its disk, rather than waiting in memory to be.
    func flushToDisk() throws {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let descriptor = open(file.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            // Asks the disk itself. A file system that doesn't know how is asked the ordinary way.
            if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
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

/// Keeps count for a copy that ``VMBundle`` makes with `copyfile`. Only the copying thread uses it.
private final class CopyTracker {
    /// What the bundle occupies, which is about what there is to copy: empty space is skipped.
    private let total: UInt64
    private let progress: (@Sendable (Double) -> Void)?
    let isCancelled: @Sendable () -> Bool
    private var finishedBytes: UInt64 = 0
    private var currentBytes: UInt64 = 0
    private var lastReported = 0.0
    /// The first thing that went wrong, as an `errno`.
    private(set) var failure: Int32?

    init(total: UInt64, progress: (@Sendable (Double) -> Void)?, isCancelled: @escaping @Sendable () -> Bool) {
        self.total = total
        self.progress = progress
        self.isCancelled = isCancelled
    }

    /// A file's count starts over with every file, and comes thousands of times for a large one. Whoever
    /// listens only hears of every hundredth of the whole.
    func report(bytesOfCurrentFile bytes: UInt64) {
        currentBytes = bytes
        guard let progress, total > 0 else { return }
        let fraction = min(Double(finishedBytes + currentBytes) / Double(total), 1)
        guard fraction - lastReported >= 0.01 else { return }
        lastReported = fraction
        progress(fraction)
    }

    func finishFile() {
        finishedBytes += currentBytes
        currentBytes = 0
    }

    func fail(with code: Int32) {
        if failure == nil {
            failure = code
        }
    }
}
