import Foundation

/// A point in a machine's life that it can go back to: its disks, firmware state and, if it was running,
/// its memory.
///
/// A snapshot lives in the bundle under `snapshots/<id>/` as copies of the machine's files. On APFS a copy
/// shares its blocks with the original, so taking one is instant and only what changes afterwards takes
/// up space.
public struct VMSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// The guest was running (or suspended) when the snapshot was taken, and going back to it resumes the
    /// guest where it was instead of booting it.
    public var includesMemory: Bool
    /// The machine's configuration at the time.
    public var configuration: VMConfiguration

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), includesMemory: Bool, configuration: VMConfiguration) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.includesMemory = includesMemory
        self.configuration = configuration
    }

    /// `Snapshot 1`, `Snapshot 2`, …: the first that isn't taken.
    public static func defaultName(avoiding existing: [VMSnapshot]) -> String {
        let taken = Set(existing.map { $0.name.lowercased() })
        var number = existing.count + 1
        while taken.contains("snapshot \(number)") {
            number += 1
        }
        return "Snapshot \(number)"
    }
}

extension VMConfiguration {
    /// The configuration to carry on with after going back to `snapshot`.
    ///
    /// The guest gets back the hardware it had, which its saved memory depends on. What belongs to the host
    /// stays as it is now: the machine's name, how it is reached, what is shared with it.
    public func reverted(to snapshot: VMSnapshot) -> VMConfiguration {
        var result = snapshot.configuration
        result.id = id
        result.name = name
        result.createdAt = createdAt
        result.sharedFolders = sharedFolders
        result.ssh = ssh
        result.keyboard = keyboard
        // Which of this Mac's USB devices the machine takes by itself.
        result.usb = usb
        result.display.automaticallyResizes = display.automaticallyResizes
        // Whether the clipboard is shared is the host's to say as well. Only a Linux guest that comes
        // back with its memory has to find the device it was saved with, shared or not.
        if os.family == .macOS || !snapshot.includesMemory {
            result.clipboard = clipboard
        }
        // The guest only knows an interface by its MAC address. Addresses and forwarded ports are the host's.
        result.networkInterfaces = snapshot.configuration.networkInterfaces.map { old in
            guard var current = networkInterfaces.first(where: { $0.id == old.id }) else { return old }
            current.macAddress = old.macAddress
            return current
        }
        if !snapshot.includesMemory {
            // A guest that boots doesn't care which drives were plugged in back then.
            result.removableImages = removableImages
        }
        return result
    }
}

extension VMBundle {
    private static let snapshotFileName = "snapshot.json"
    /// Prefix of a snapshot directory that is still being written.
    private static let unfinishedPrefix = ".new-"

    public func snapshotURL(for id: UUID) -> URL {
        snapshotsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// The files that change while a machine with `configuration` runs, and so make up a snapshot.
    func stateFileNames(for configuration: VMConfiguration) -> [String] {
        let candidates = configuration.disks.filter { !$0.readOnly }.map(\.fileName) + [
            auxiliaryStorageURL.lastPathComponent,
            efiVariableStoreURL.lastPathComponent,
            savedStateURL.lastPathComponent,
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: url.appending(path: $0).path) }
    }

    /// The machine's snapshots, oldest first.
    public func loadSnapshots() -> [VMSnapshot] {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil)) ?? []
        return directories
            .compactMap { directory -> VMSnapshot? in
                guard let data = try? Data(contentsOf: directory.appending(path: Self.snapshotFileName)),
                      let snapshot = try? Self.decoder.decode(VMSnapshot.self, from: data),
                      snapshot.id.uuidString == directory.lastPathComponent
                else { return nil }
                return snapshot
            }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Copies the machine's current state into a new snapshot. The machine must not be running.
    public func takeSnapshot(named name: String, of configuration: VMConfiguration) throws -> VMSnapshot {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        // Whatever an earlier attempt left behind when it was cut short.
        for leftover in (try? fileManager.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix(Self.unfinishedPrefix) {
            try? fileManager.removeItem(at: leftover)
        }

        let snapshot = VMSnapshot(name: name, includesMemory: hasSavedState, configuration: configuration)
        let unfinished = snapshotsDirectory.appending(path: Self.unfinishedPrefix + snapshot.id.uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: unfinished, withIntermediateDirectories: false)
        do {
            for fileName in stateFileNames(for: configuration) {
                try fileManager.copyItem(at: url.appending(path: fileName), to: unfinished.appending(path: fileName))
            }
            try Self.encoder.encode(snapshot).write(to: unfinished.appending(path: Self.snapshotFileName), options: .atomic)
            // Only a complete snapshot gets its real name, so a half-written one is never listed.
            try fileManager.moveItem(at: unfinished, to: snapshotURL(for: snapshot.id))
        } catch {
            try? fileManager.removeItem(at: unfinished)
            throw error
        }
        return snapshot
    }

    /// Copies of a snapshot's files, waiting next to the files they are going to replace.
    public struct StagedRestore: Sendable {
        public let snapshot: VMSnapshot
        /// Names of the files in the bundle that will be replaced.
        let fileNames: [String]
    }

    /// Prefix of a copy that is waiting to replace the machine's file of the same name.
    private static let restorePrefix = ".reverting-"

    /// First half of going back to a snapshot: copies its files into the bundle under temporary names.
    /// Nothing the machine uses is touched, so this can be done while it is still running, and a snapshot
    /// that turns out to be unusable costs the guest nothing.
    public func stageRestore(of snapshot: VMSnapshot) throws -> StagedRestore {
        let fileManager = FileManager.default
        removeRestoreLeftovers()
        let source = snapshotURL(for: snapshot.id)
        let saved = try fileManager.contentsOfDirectory(atPath: source.path)
            .filter { $0 != Self.snapshotFileName && !$0.hasPrefix(".") }
        guard snapshot.configuration.disks.filter({ !$0.readOnly }).allSatisfy({ saved.contains($0.fileName) }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "The snapshot “\(snapshot.name)” is missing a disk.",
            ])
        }
        do {
            for fileName in saved {
                try fileManager.copyItem(at: source.appending(path: fileName), to: url.appending(path: Self.restorePrefix + fileName))
            }
        } catch {
            removeRestoreLeftovers()
            throw error
        }
        return StagedRestore(snapshot: snapshot, fileNames: saved)
    }

    /// Second half: puts the staged copies in place of the machine's disks, firmware state and saved
    /// memory. The machine must not be running, and `configuration` is the one it has now. The snapshot
    /// itself is kept. The caller goes on with ``VMConfiguration/reverted(to:)``.
    ///
    /// Saved memory only makes sense with the disk it was saved next to. So the machine's own saved memory
    /// goes first and the snapshot's comes back last: if this is cut short, the machine is left shut down
    /// with whatever disk it has by then, never ready to resume memory against the wrong disk.
    public func commitRestore(_ staged: StagedRestore, replacing configuration: VMConfiguration) throws {
        let fileManager = FileManager.default
        removeSavedState()
        // What the machine has now and the snapshot doesn't.
        for fileName in stateFileNames(for: configuration) where !staged.fileNames.contains(fileName) {
            try? fileManager.removeItem(at: url.appending(path: fileName))
        }
        let memory = savedStateURL.lastPathComponent
        let ordered = staged.fileNames.filter { $0 != memory } + staged.fileNames.filter { $0 == memory }
        defer { removeRestoreLeftovers() }
        for fileName in ordered {
            // rename(2) puts the copy in the old file's place in one step, so there is no moment at which
            // the machine has no disk.
            guard rename(url.appending(path: Self.restorePrefix + fileName).path, url.appending(path: fileName).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Removes copies left behind by a restore that didn't finish.
    public func removeRestoreLeftovers() {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasPrefix(Self.restorePrefix) {
            try? fileManager.removeItem(at: url.appending(path: name))
        }
    }

    /// Writes a snapshot's description again, after its name has changed.
    public func saveSnapshot(_ snapshot: VMSnapshot) throws {
        let url = snapshotURL(for: snapshot.id).appending(path: Self.snapshotFileName)
        try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func removeSnapshot(_ id: UUID) throws {
        try FileManager.default.removeItem(at: snapshotURL(for: id))
    }
}
