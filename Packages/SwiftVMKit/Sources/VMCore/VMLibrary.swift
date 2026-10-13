import Foundation
import Observation

/// A machine that is in the library but can't be used right now.
public struct UnavailableMachine: Identifiable, Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// The disk it is kept on isn't connected. With the disk's name, where that is known.
        case diskNotConnected(volumeName: String?)
        /// Its bundle is there but can't be opened, for the reason given.
        case unreadable(String)
    }

    /// Where its bundle was when it was last seen.
    public var url: URL
    public var name: String
    public var reason: Reason
    /// What it holds that no other machine may take while it is away.
    public var sshAlias: String?
    public var ipv4Addresses: [String]

    public var id: URL { url }
}

/// The set of virtual machines the app knows about.
@MainActor
@Observable
public final class VMLibrary {
    public private(set) var machines: [VirtualMachine] = []
    /// Machines that are in the index but can't be opened right now, most often because the disk they are
    /// kept on isn't connected. They stay in the library, and are machines again once they can be opened.
    public private(set) var unavailableMachines: [UnavailableMachine] = []
    /// Bundles that are there but couldn't be opened, with the reason.
    public private(set) var unreadableBundles: [URL: String] = [:]

    /// Application Support directory that holds the index and, by default, the machines.
    public let rootDirectory: URL
    /// Where new machines are created unless another folder is asked for.
    public private(set) var machinesDirectory: URL

    @ObservationIgnored public weak var backendProvider: (any VMBackendProvider)? {
        didSet { machines.forEach { $0.backendProvider = backendProvider } }
    }
    /// Called whenever the set of machines or one of their configurations changes.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// Called when a machine's guest has been resumed from saved memory.
    @ObservationIgnored public var onMachineResume: (@MainActor (VirtualMachine) -> Void)?
    /// Called when a machine's guest has come up, booted or resumed.
    @ObservationIgnored public var onMachineStart: (@MainActor (VirtualMachine) -> Void)?
    /// Called when the agent in a machine's guest reports other addresses than before.
    @ObservationIgnored public var onGuestAddressesChange: (@MainActor (VirtualMachine) -> Void)?
    /// Called when the agent in a machine's guest has connected, and when it is gone again.
    @ObservationIgnored public var onGuestAgentChange: (@MainActor (VirtualMachine) -> Void)?
    /// Called with text that was copied in a machine's guest.
    @ObservationIgnored public var onGuestClipboard: (@MainActor (VirtualMachine, String) -> Void)?
    /// Called when a machine's guest asks for what is on this Mac's clipboard.
    @ObservationIgnored public var onGuestClipboardRequest: (@MainActor (VirtualMachine) -> Void)?
    /// Whether machines may start. The app turns this off once it has agreed to quit: a machine that
    /// came up after that would lose its power with the app, and nobody would have been asked.
    @ObservationIgnored public var allowsStarting = true
    /// The disks that are connected, by their identifiers. A machine that is missing from a disk that
    /// is connected is gone; one on a disk that isn't is only away.
    @ObservationIgnored var mountedVolumeIdentifiers: @MainActor () -> Set<String> = {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        return Set(volumes.compactMap { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString })
    }

    /// The index as it was last read or written: every machine of the library, in its order, also those
    /// that can't be opened right now.
    @ObservationIgnored private var entries: [Entry] = []
    /// Bundles this library is putting together, or was, in folders other than its own. See
    /// ``removeStagedBundles()``.
    @ObservationIgnored private var stagedBundles: [URL] = []
    /// What is in the index file. Nothing is written that is there already.
    @ObservationIgnored private var savedIndex: Data?
    /// Machines whose bundle went from under them while they were in use, which are looked at again
    /// once they are done.
    @ObservationIgnored private var machinesToLookAtAgain: Set<UUID> = []

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        let defaultDirectory = Self.defaultMachinesDirectory(in: rootDirectory)
        let saved = try? Data(contentsOf: Self.indexURL(in: rootDirectory))
        let index = saved.flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
        machinesDirectory = index?.machinesDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL } ?? defaultDirectory
        savedIndex = saved
        stagedBundles = (index?.stagedBundles ?? []).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        entries = (index?.bundles ?? []).map { path in
            Entry(url: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, details: index?.details?[path])
        }
    }

    /// Where new machines are created when nobody has chosen another folder.
    public var defaultMachinesDirectory: URL { Self.defaultMachinesDirectory(in: rootDirectory) }

    /// Has new machines created in `folder` from now on, or in the default folder again with `nil`.
    /// Machines that are there already become part of the library. The others stay where they are.
    public func setMachinesDirectory(_ folder: URL?) throws {
        let folder = folder?.standardizedFileURL ?? defaultMachinesDirectory
        guard folder.path != machinesDirectory.path else { return }
        try prepareFolder(folder)
        machinesDirectory = folder
        load()
    }

    /// Where a machine is put together before it joins the library. Creating one can take a long time
    /// (downloading, installing), and a half-made bundle must never show up as a machine. It is next to
    /// where the machine is going to be, so that it gets there without being copied from one disk to another.
    ///
    /// It has a name that nothing else in a folder of the user's choosing goes by.
    public static func stagingDirectory(in folder: URL) -> URL {
        folder.appending(path: ".swiftvm-staging", directoryHint: .isDirectory)
    }

    private static func defaultMachinesDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appending(path: "Machines", directoryHint: .isDirectory).standardizedFileURL
    }

    private static func indexURL(in rootDirectory: URL) -> URL {
        rootDirectory.appending(path: "library.json")
    }

    // MARK: Loading

    /// Reads the machines of the index and picks up any bundle found in the machines directory. Called
    /// when the app starts, and again whenever a disk is connected or taken away.
    public func load() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: machinesDirectory, withIntermediateDirectories: true)
        let mountedVolumes = mountedVolumeIdentifiers()

        var loaded: [VirtualMachine] = []
        var kept: [Entry] = []
        var unavailable: [UnavailableMachine] = []
        var failures: [URL: String] = [:]

        for var entry in entries {
            let existing = machines.first { $0.bundle.url.path == entry.url.path }
            let presence = Self.presence(of: entry.url)
            if presence != .present {
                if let existing, existing.state.isActive || existing.activity != nil {
                    // Its disk has gone from under a machine that is in use. What comes of that is the
                    // machine's to say; it isn't taken off the list while it is, and is looked at
                    // again when it is done.
                    loaded.append(existing)
                    kept.append(entry)
                    lookAgain(whenIdle: existing)
                    continue
                }
                if case .inaccessible(let reason) = presence {
                    // It may well be there: nothing says that it isn't. A machine is never forgotten
                    // for that.
                    failures[entry.url] = reason
                    unavailable.append(entry.unavailable(.unreadable(reason)))
                    kept.append(entry)
                    continue
                }
                if let found = Self.resolveBookmark(of: entry) {
                    // Moved in the Finder, or on a disk that is connected under another name this time.
                    entry.url = found
                    entry.details?.bookmark = nil
                    existing?.relocate(to: VMBundle(url: found))
                } else if let volumeName = Self.disconnectedVolume(of: entry, mounted: mountedVolumes) {
                    unavailable.append(entry.unavailable(.diskNotConnected(volumeName: volumeName.isEmpty ? nil : volumeName)))
                    kept.append(entry)
                    continue
                } else {
                    // Gone from a disk that is there: deleted, and forgotten as a deleted machine is.
                    continue
                }
            }
            do {
                let machine = try existing ?? VirtualMachine(bundle: VMBundle(url: entry.url))
                guard !loaded.contains(where: { $0.id == machine.id }) else { continue }
                if existing == nil {
                    adopt(machine)
                }
                loaded.append(machine)
                entry.refresh(from: machine)
                kept.append(entry)
            } catch {
                failures[entry.url] = error.localizedDescription
                unavailable.append(entry.unavailable(.unreadable(error.localizedDescription)))
                kept.append(entry)
            }
        }

        let discovered = (try? fileManager.contentsOfDirectory(at: machinesDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in discovered.sorted(by: { $0.path < $1.path }) where url.pathExtension == VMBundle.pathExtension {
            let standardized = url.standardizedFileURL
            guard !kept.contains(where: { $0.url.path == standardized.path }) else { continue }
            do {
                let machine = try VirtualMachine(bundle: VMBundle(url: standardized))
                guard !loaded.contains(where: { $0.id == machine.id }) else { continue }
                adopt(machine)
                loaded.append(machine)
                var entry = Entry(url: standardized)
                entry.refresh(from: machine)
                kept.append(entry)
            } catch {
                failures[standardized] = error.localizedDescription
            }
        }

        machines = loaded
        entries = kept
        unavailableMachines = unavailable
        unreadableBundles = failures
        saveIndex()
        onChange?()
    }

    public func machine(id: UUID) -> VirtualMachine? {
        machines.first { $0.id == id }
    }

    // MARK: Adding and removing

    /// A bundle URL that doesn't exist yet, derived from the machine name: in `folder`, or without one
    /// in the machines directory.
    public func availableBundleURL(forName name: String, in folder: URL? = nil) -> URL {
        let folder = folder ?? machinesDirectory
        let base = Self.fileName(from: name)
        var candidate = folder.appending(path: "\(base).\(VMBundle.pathExtension)", directoryHint: .isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) \(counter).\(VMBundle.pathExtension)", directoryHint: .isDirectory)
            counter += 1
        }
        return candidate
    }

    /// Makes sure machines can be kept in `folder`, which is created if it isn't there. Throws with what
    /// is in the way, in words for whoever chose the folder.
    public func prepareFolder(_ folder: URL) throws {
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        guard !folder.pathComponents.contains(where: { ($0 as NSString).pathExtension == VMBundle.pathExtension }) else {
            throw VMError.invalidConfiguration("“\(shown)” is inside a virtual machine. Choose a folder outside of it.")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw VMError.invalidConfiguration(
                "Virtual machines can't be kept in “\(shown)”: \(error.localizedDescription) If the folder is on an external disk, connect the disk first."
            )
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw VMError.invalidConfiguration("Virtual machines can't be kept in “\(shown)”: you don't have permission to add to that folder.")
        }
    }

    /// A bundle URL in a staging directory for a machine that is about to be created in `folder`, or
    /// without one in the machines directory.
    public func makeStagingBundleURL(in folder: URL? = nil) throws -> URL {
        let folder = (folder ?? machinesDirectory).standardizedFileURL
        let staging = Self.stagingDirectory(in: folder)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let url = staging.appending(path: "\(UUID().uuidString).\(VMBundle.pathExtension)", directoryHint: .isDirectory).standardizedFileURL
        if folder.path != defaultMachinesDirectory.path {
            // Written down before anything is put there, so that what a creation leaves behind when
            // the app is cut off is found the next time.
            stagedBundles.append(url)
            saveIndex()
        }
        return url
    }

    /// Throws away a bundle that was being put together and isn't going to be finished.
    public func discard(staged bundle: VMBundle) {
        let staging = bundle.url.deletingLastPathComponent()
        // Nothing but a bundle in a staging directory is ever removed on this account.
        guard staging.lastPathComponent == Self.stagingDirectory(in: staging).lastPathComponent else { return }
        try? FileManager.default.removeItem(at: bundle.url)
        rmdir(staging.path)
        forgetStagedBundle(at: bundle.url)
    }

    private func forgetStagedBundle(at url: URL) {
        guard stagedBundles.contains(where: { $0.path == url.path }) else { return }
        stagedBundles.removeAll { $0.path == url.path }
        saveIndex()
    }

    /// Moves a finished bundle out of its staging directory, into the folder that directory is in, and
    /// adds it to the library.
    @discardableResult
    public func add(staged bundle: VMBundle) throws -> VirtualMachine {
        let name = try bundle.loadConfiguration().name
        let staging = bundle.url.deletingLastPathComponent()
        let destination = availableBundleURL(forName: name, in: staging.deletingLastPathComponent())
        try FileManager.default.moveItem(at: bundle.url, to: destination)
        do {
            let machine = try add(VMBundle(url: destination))
            forgetStagedBundle(at: bundle.url)
            // Nothing is left in a folder of the user's choosing once the last machine is out of it.
            // A directory that still holds one stays: `rmdir` only takes an empty one.
            rmdir(staging.path)
            return machine
        } catch {
            // Back to where the caller keeps track of it, rather than a bundle in the machines folder
            // that the library refused.
            try? FileManager.default.moveItem(at: destination, to: bundle.url)
            throw error
        }
    }

    /// Deletes bundles left in a staging directory by a creation or a move that never finished, for
    /// example because the app quit in the middle of it. Call before any creation starts.
    public func removeStagedBundles() {
        let fileManager = FileManager.default
        // The library's own folder is nobody else's: whatever was being put together there goes.
        try? fileManager.removeItem(at: Self.stagingDirectory(in: defaultMachinesDirectory))
        // Where versions before this one put machines together.
        try? fileManager.removeItem(at: defaultMachinesDirectory.appending(path: ".staging", directoryHint: .isDirectory))
        // In a folder of the user's, another copy of the app may be at work on a machine of its own.
        // Only what this library wrote down as its own goes.
        let remaining = stagedBundles.filter { bundle in
            let staging = bundle.deletingLastPathComponent()
            try? fileManager.removeItem(at: bundle)
            rmdir(staging.path)
            // What can't be reached may be on a disk that is away, and is seen to another time.
            return fileManager.fileExists(atPath: bundle.path) || !fileManager.fileExists(atPath: staging.deletingLastPathComponent().path)
        }
        if remaining != stagedBundles {
            stagedBundles = remaining
            saveIndex()
        }
    }

    /// Adds an existing bundle to the library.
    @discardableResult
    public func add(_ bundle: VMBundle) throws -> VirtualMachine {
        if let existing = machines.first(where: { $0.bundle.url == bundle.url }) {
            return existing
        }
        let machine = try VirtualMachine(bundle: bundle)
        if machines.contains(where: { $0.id == machine.id }) {
            throw VMError.invalidConfiguration("A virtual machine with the same identifier is already in the library.")
        }
        adopt(machine)
        machines.append(machine)
        // It may have been listed as away, at the place it was in before.
        entries.removeAll { $0.details?.id == machine.id || $0.url.path == bundle.url.path }
        unavailableMachines.removeAll { unavailable in !entries.contains { $0.url.path == unavailable.url.path } }
        var entry = Entry(url: bundle.url)
        entry.refresh(from: machine)
        entries.append(entry)
        saveIndex()
        onChange?()
        return machine
    }

    /// Removes a machine from the library, optionally moving its bundle to the Trash.
    public func remove(_ machine: VirtualMachine, movingToTrash: Bool) throws {
        guard !machine.state.isActive else {
            throw VMError.invalidConfiguration("Stop “\(machine.name)” before deleting it.")
        }
        if let activity = machine.activity {
            throw VMError.busy(name: machine.name, activity)
        }
        if movingToTrash {
            try FileManager.default.trashItem(at: machine.bundle.url, resultingItemURL: nil)
        }
        machines.removeAll { $0.id == machine.id }
        entries.removeAll { $0.details?.id == machine.id || $0.url.path == machine.bundle.url.path }
        saveIndex()
        onChange?()
    }

    /// Takes a machine that can't be opened off the list. Its files, wherever they are, stay as they are.
    public func forget(_ machine: UnavailableMachine) {
        entries.removeAll { $0.url.path == machine.url.path }
        unavailableMachines.removeAll { $0.url.path == machine.url.path }
        saveIndex()
        onChange?()
    }

    // MARK: Moving

    /// Moves a machine that is shut down into `folder`, under its name.
    ///
    /// On the disk it is on already that is a change of name and takes no time. To another disk the
    /// bundle is copied, which takes as long as its disks are full, and the original is only removed once
    /// the copy is complete: a move that is cancelled or fails leaves the machine where it was.
    public func move(_ machine: VirtualMachine, to folder: URL) async throws {
        let folder = folder.standardizedFileURL
        try await machine.whileStopped(.moving) {
            let source = machine.bundle
            guard source.url.deletingLastPathComponent().path != folder.path else { return }
            try prepareFolder(folder)
            let destination = VMBundle(url: availableBundleURL(forName: machine.name, in: folder))

            var isCopied = false
            if rename(source.url.path, destination.url.path) != 0 {
                let code = errno
                guard code == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                try await copy(machine, to: destination.url, in: folder)
                isCopied = true
            }

            // The index is how the machine is found the next time the app starts. Until the new place
            // is in it the original isn't touched, and a move that can't be written down is undone.
            let index = entries.firstIndex { $0.details?.id == machine.id || $0.url.path == source.url.path }
            let previous = index.map { entries[$0] }
            do {
                // Settings can be changed while the copy is under way, and were then saved in the original.
                try destination.save(machine.configuration)
                if let index {
                    entries[index].url = destination.url
                    entries[index].details?.bookmark = nil
                    entries[index].refresh(from: machine)
                }
                try writeIndex()
            } catch {
                if let index, let previous {
                    entries[index] = previous
                }
                if isCopied {
                    try? FileManager.default.removeItem(at: destination.url)
                } else {
                    rename(destination.url.path, source.url.path)
                }
                throw VMError.invalidConfiguration(
                    "“\(machine.name)” was left where it is, because its new place couldn't be written down. \(error.localizedDescription)"
                )
            }
            machine.relocate(to: destination)
            onChange?()

            guard isCopied else { return }
            let original = source.url
            let isRemoved = await Task.detached { (try? FileManager.default.removeItem(at: original)) != nil }.value
            if !isRemoved {
                machine.notice = VMErrorInfo(
                    title: "“\(machine.name)” was moved, but its old files are still there",
                    message: "They couldn't be removed from \((original.path as NSString).abbreviatingWithTildeInPath). The virtual machine no longer uses them, and you can delete them."
                )
            }
        }
    }

    /// Copies a machine's bundle to `destination` on another disk, by way of that folder's staging directory.
    private func copy(_ machine: VirtualMachine, to destination: URL, in folder: URL) async throws {
        let source = machine.bundle
        // Looked up off the main actor: a disk that was asleep takes its time to answer.
        let needed = await Task.detached { source.totalAllocatedSize }.value
        let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeNameKey])
        // Disks that aren't APFS say nothing of the first, so whichever is more counts.
        if let capacity, let free = [capacity.volumeAvailableCapacityForImportantUsage, capacity.volumeAvailableCapacity.map(Int64.init)].compactMap({ $0 }).max(),
           UInt64(max(free, 0)) < needed {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .binary
            throw VMError.invalidConfiguration(
                "“\(machine.name)” takes up \(formatter.string(fromByteCount: Int64(clamping: needed))), and “\(capacity.volumeName ?? folder.lastPathComponent)” only has \(formatter.string(fromByteCount: free)) free."
            )
        }

        let staged = VMBundle(url: try makeStagingBundleURL(in: folder))
        let cancellation = CancellationFlag()
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in machine.reportProgress(fraction, of: .moving) }
        }
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    _ = try source.copy(to: staged.url, progress: report, isCancelled: { cancellation.isSet })
                }.value
            } onCancel: {
                cancellation.set()
            }
            try FileManager.default.moveItem(at: staged.url, to: destination)
        } catch {
            discard(staged: staged)
            throw error
        }
        rmdir(staged.url.deletingLastPathComponent().path)
        forgetStagedBundle(at: staged.url)
    }

    // MARK: Private

    private func adopt(_ machine: VirtualMachine) {
        machine.backendProvider = backendProvider
        machine.onConfigurationChange = { [weak self] machine in self?.configurationDidChange(of: machine) }
        machine.onResume = { [weak self] machine in self?.onMachineResume?(machine) }
        machine.onGuestStart = { [weak self] machine in self?.onMachineStart?(machine) }
        machine.onGuestAddressesChange = { [weak self] machine in self?.onGuestAddressesChange?(machine) }
        machine.onGuestAgentChange = { [weak self] machine in self?.onGuestAgentChange?(machine) }
        machine.onGuestClipboard = { [weak self] machine, text in self?.onGuestClipboard?(machine, text) }
        machine.onGuestClipboardRequest = { [weak self] machine in self?.onGuestClipboardRequest?(machine) }
        machine.isStartAllowed = { [weak self] in self?.allowsStarting ?? true }
    }

    /// What the index says of a machine is what is shown of it while its disk is away, so it is kept
    /// up to date.
    private func configurationDidChange(of machine: VirtualMachine) {
        if let index = entries.firstIndex(where: { $0.details?.id == machine.id }) {
            let before = entries[index].details
            entries[index].refresh(from: machine)
            if entries[index].details != before {
                saveIndex()
            }
        }
        onChange?()
    }

    /// Looks at the library again once `machine`, whose bundle isn't where it was, is no longer in use:
    /// it is then away, moved or gone like any other.
    private func lookAgain(whenIdle machine: VirtualMachine) {
        guard machinesToLookAtAgain.insert(machine.id).inserted else { return }
        withObservationTracking {
            _ = machine.state
            _ = machine.activity
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.machinesToLookAtAgain.remove(machine.id)
                self?.load()
            }
        }
    }

    /// Writes the index. Most of what the library does carries on without it: what is listed is in
    /// memory, and written again with the next change.
    @discardableResult
    private func saveIndex() -> Bool {
        (try? writeIndex()) != nil
    }

    /// Writes the index, for whoever has to know that it is written.
    private func writeIndex() throws {
        var details: [String: Entry.Details] = [:]
        for entry in entries {
            details[entry.url.path] = entry.details
        }
        let index = Index(
            bundles: entries.map(\.url.path),
            details: details,
            machinesDirectory: machinesDirectory.path == defaultMachinesDirectory.path ? nil : machinesDirectory.path,
            stagedBundles: stagedBundles.isEmpty ? nil : stagedBundles.map(\.path)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(index)
        // The library is read again whenever a disk comes or goes, which mostly changes nothing.
        guard data != savedIndex else { return }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.indexURL(in: rootDirectory), options: .atomic)
        savedIndex = data
    }

    /// Whether a bundle is where the index has it.
    private enum Presence: Equatable {
        case present
        case missing
        /// It can't be looked at, for the reason given. That is not the same as gone: macOS keeps an
        /// app from a disk or a folder until the user has allowed it.
        case inaccessible(String)
    }

    private static func presence(of url: URL) -> Presence {
        var status = stat()
        guard stat(url.path, &status) != 0 else { return .present }
        let code = errno
        if code == ENOENT || code == ENOTDIR {
            return .missing
        }
        let reason = String(cString: strerror(code))
        if code == EPERM || code == EACCES {
            return .inaccessible("This Mac doesn't let SwiftVM look at it (\(reason)). Allow it under Privacy & Security, Files and Folders, in System Settings.")
        }
        return .inaccessible(reason)
    }

    /// Where the bundle of `entry` is now, if it isn't where the index has it: a bookmark follows a
    /// bundle that was moved on its disk, and a disk that is connected in another place.
    private static func resolveBookmark(of entry: Entry) -> URL? {
        guard let bookmark = entry.details?.bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return nil }
        let found = url.standardizedFileURL
        // A bundle in the Trash was deleted, however well the bookmark finds it there.
        guard found.pathExtension == VMBundle.pathExtension, FileManager.default.fileExists(atPath: found.path),
              !found.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }),
              (try? VMBundle(url: found).loadConfiguration().id) == entry.details?.id
        else { return nil }
        return found
    }

    /// The name of the disk `entry` is on if that disk isn't connected, empty if its name isn't known.
    /// `nil` if the disk is there, which makes the bundle one that is gone from it.
    private static func disconnectedVolume(of entry: Entry, mounted: Set<String>) -> String? {
        if let bookmark = entry.details?.bookmark,
           let values = URL.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey], fromBookmarkData: bookmark),
           let identifier = values.volumeUUIDString {
            return mounted.contains(identifier) ? nil : values.volumeName ?? ""
        }
        // Without a bookmark there is the path to go by: disks are connected under /Volumes.
        let components = entry.url.pathComponents
        guard components.count > 3, components[1] == "Volumes" else { return nil }
        return FileManager.default.fileExists(atPath: "/Volumes/\(components[2])") ? nil : components[2]
    }

    /// Turns a machine name into a safe file name.
    nonisolated static func fileName(from name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\0").union(.newlines)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let trimmedDots = cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
        return trimmedDots.isEmpty ? "Virtual Machine" : trimmedDots
    }

    /// One machine of the library as the index has it.
    private struct Entry {
        /// What the index knows of a machine besides where it is. It is what there is to go by while the
        /// machine's bundle can't be read.
        struct Details: Codable, Equatable {
            var id: UUID
            var name: String
            var sshAlias: String?
            var ipv4Addresses: [String]?
            /// Finds the bundle again when it isn't at its path, and says which disk it is on.
            var bookmark: Data?
        }

        var url: URL
        var details: Details?

        /// Brings the details up to date with a machine that is open.
        @MainActor mutating func refresh(from machine: VirtualMachine) {
            let configuration = machine.configuration
            var updated = Details(
                id: machine.id,
                name: configuration.name,
                sshAlias: configuration.ssh.alias.isEmpty ? nil : configuration.ssh.alias,
                ipv4Addresses: configuration.networkInterfaces.compactMap(\.ipv4Address),
                bookmark: details?.bookmark
            )
            if let bookmark = updated.bookmark,
               let recorded = URL.resourceValues(forKeys: [.volumeUUIDStringKey], fromBookmarkData: bookmark)?.volumeUUIDString,
               let current = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString, recorded != current {
                // The same path on another disk, as after a restore or a move to a new Mac. The
                // bookmark would go on naming a disk the bundle isn't on.
                updated.bookmark = nil
            }
            if updated.bookmark == nil {
                updated.bookmark = try? url.bookmarkData(
                    options: [], includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey], relativeTo: nil
                )
            }
            details = updated
        }

        func unavailable(_ reason: UnavailableMachine.Reason) -> UnavailableMachine {
            UnavailableMachine(
                url: url,
                name: details?.name ?? url.deletingPathExtension().lastPathComponent,
                reason: reason,
                sshAlias: details?.sshAlias,
                ipv4Addresses: details?.ipv4Addresses ?? []
            )
        }
    }

    private struct Index: Codable {
        /// The path of every machine's bundle, in the library's order.
        var bundles: [String]
        /// What else is known of each, by its path.
        var details: [String: Entry.Details]?
        /// Where new machines are created, if that isn't the default folder.
        var machinesDirectory: String?
        /// Bundles that are being put together in folders other than the library's own.
        var stagedBundles: [String]?
    }
}

/// Says across threads that a copy is to stop.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool { lock.withLock { flag } }

    func set() {
        lock.withLock { flag = true }
    }
}
