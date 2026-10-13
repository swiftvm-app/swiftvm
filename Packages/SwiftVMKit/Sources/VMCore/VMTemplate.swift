import Foundation
import Observation

/// A machine as it was when it was saved, kept to make new machines from: its disks, its firmware and
/// its settings.
///
/// A template is a package of its own, `<name>.swiftvmtemplate`, in the folder for templates. The files
/// in it are those a copy of a machine is made of, under the names they have in a machine's bundle. It
/// never runs, so nothing in it changes after it was saved, and every machine made from it starts out
/// the same.
public struct VMTemplate: Codable, Sendable, Hashable, Identifiable {
    public static let pathExtension = "swiftvmtemplate"
    static let fileName = "template.json"
    /// Prefix of a template's package that is still being written.
    static let unfinishedPrefix = ".new-"

    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// The configuration of the machine it was saved from, as it was then.
    public var configuration: VMConfiguration

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), configuration: VMConfiguration) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.configuration = configuration
    }

    /// The configuration of a new machine made from the template: the template's hardware and disks under
    /// an identity of its own, as for the copy of a machine (``VMConfiguration/duplicated(name:sshAlias:)``).
    ///
    /// - Parameters:
    ///   - cpuCount: Its processors. `nil` is as many as the template has.
    ///   - memorySize: Its memory in bytes. `nil` is as much as the template has.
    ///   - diskCapacity: The size its disk is grown to, in bytes. A disk can't shrink, so less than the
    ///     template's leaves the size as it is.
    public func machineConfiguration(
        name: String, sshAlias: String, cpuCount: Int? = nil, memorySize: UInt64? = nil, diskCapacity: UInt64? = nil
    ) -> VMConfiguration {
        var machine = configuration.duplicated(name: name, sshAlias: sshAlias)
        if let cpuCount {
            machine.cpuCount = cpuCount
        }
        if let memorySize {
            machine.memorySize = memorySize
        }
        if let diskCapacity, let disk = machine.disks.first, diskCapacity > disk.capacity {
            machine.disks[0].capacity = diskCapacity
        }
        return machine
    }

    /// Writes the template's package at `url`, where nothing is yet, from `files`. What was written is
    /// removed again if that doesn't finish.
    ///
    /// The package is on its disk for good when this returns: whoever saved the template may be about to
    /// delete the machine it was saved from.
    func write(
        to url: URL, files: [VMBundle.PortableFile], progress: (@Sendable (Double) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try VMBundle.copy(files, into: url, progress: progress, isCancelled: isCancelled)
            try VMBundle.encoder.encode(self).write(to: url.appending(path: Self.fileName), options: .atomic)
            try VMBundle(url: url).flushToDisk()
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }
}

/// The templates the app knows about: those in one folder, which can be on another disk.
@MainActor
@Observable
public final class VMTemplateLibrary {
    /// The templates in the folder, by name.
    public private(set) var templates: [VMTemplate] = []
    /// The folder templates are kept in.
    public private(set) var directory: URL

    /// Application Support directory that holds what the library writes down and, by default, the templates.
    public let rootDirectory: URL

    /// Where each template's package is.
    @ObservationIgnored private var locations: [UUID: URL] = [:]
    /// The names of the templates that are being saved, in lower case. Each is taken from the moment its
    /// template starts being written, so that two saved side by side can't end up with one name.
    @ObservationIgnored private var namesBeingSaved: Set<String> = []
    /// How many machines are being made from each template right now.
    @ObservationIgnored private var useCounts: [UUID: Int] = [:]
    /// Packages this library is writing, or was. See ``removeUnfinished()``.
    @ObservationIgnored private var unfinished: [URL] = []

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        let saved = try? Data(contentsOf: Self.settingsURL(in: rootDirectory))
        let settings = saved.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        directory = settings?.directory.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? Self.defaultDirectory(in: rootDirectory)
        unfinished = (settings?.unfinished ?? []).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    /// Where templates are kept when nobody has chosen another folder.
    public var defaultDirectory: URL { Self.defaultDirectory(in: rootDirectory) }

    /// Whether the folder that was chosen for templates isn't there: most often it is on a disk that
    /// isn't connected. Its templates are listed again once it is.
    public var isDirectoryMissing: Bool {
        directory.path != defaultDirectory.path && !FileManager.default.fileExists(atPath: directory.path)
    }

    private static func defaultDirectory(in rootDirectory: URL) -> URL {
        rootDirectory.appending(path: "Templates", directoryHint: .isDirectory).standardizedFileURL
    }

    private static func settingsURL(in rootDirectory: URL) -> URL {
        rootDirectory.appending(path: "templates.json")
    }

    // MARK: Loading

    /// Keeps templates in `folder` from now on, or in the default folder again with `nil`. Templates that
    /// are there already are listed. Those in the folder before stay where they are, and are listed no more.
    public func setDirectory(_ folder: URL?) throws {
        let folder = folder?.standardizedFileURL ?? defaultDirectory
        guard folder.path != directory.path else { return }
        // A template that is being saved is on its way to the folder there is now.
        guard namesBeingSaved.isEmpty else {
            throw VMError.invalidConfiguration("A template is being saved. Choose another folder once that is done.")
        }
        try prepare(folder)
        directory = folder
        saveSettings()
        load()
    }

    /// Reads the templates in the folder. Called when the app starts, and again whenever what is there
    /// may have changed: a disk was connected or taken away, or someone put a template there by hand.
    public func load() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var found: [VMTemplate] = []
        var locations: [UUID: URL] = [:]
        for url in items.sorted(by: { $0.path < $1.path }) where url.pathExtension == VMTemplate.pathExtension {
            guard let data = try? Data(contentsOf: url.appending(path: VMTemplate.fileName)),
                  let template = try? VMBundle.decoder.decode(VMTemplate.self, from: data),
                  // A package that was copied in the Finder is the same template a second time.
                  locations[template.id] == nil
            else { continue }
            found.append(template)
            locations[template.id] = url.standardizedFileURL
        }
        found.sort(by: Self.isInOrder)
        self.locations = locations
        // The folder is read often, and mostly nothing in it has changed.
        if found != templates {
            templates = found
        }
    }

    /// Deletes what was left of a template that was being saved when the app was cut off. Call before
    /// any template is saved.
    public func removeUnfinished() {
        guard !unfinished.isEmpty else { return }
        unfinished = unfinished.filter { url in
            try? FileManager.default.removeItem(at: url)
            return Self.mayBeLeft(at: url)
        }
        saveSettings()
    }

    /// Whether what was being written at `url` may still be there: it is, or its folder can't be looked
    /// at, as on a disk that is away. That is seen to another time.
    private static func mayBeLeft(at url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path) || !fileManager.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    /// The template's package, laid out as a machine's bundle is. `nil` for a template that isn't listed.
    public func bundle(of template: VMTemplate) -> VMBundle? {
        locations[template.id].map { VMBundle(url: $0) }
    }

    /// Bytes the template's disks occupy on the host. On APFS a template shares what it has in common
    /// with the machine it was saved from, and with the machines made from it.
    public func allocatedSize(of template: VMTemplate) -> UInt64 {
        bundle(of: template)?.allocatedSize(of: template.configuration.disks) ?? 0
    }

    // MARK: Names

    /// Whether a template, or one that is being saved, goes by `name`.
    ///
    /// - Parameter id: A template whose own name doesn't count.
    public func isNameTaken(_ name: String, besides id: UUID? = nil) -> Bool {
        let lowered = name.lowercased()
        return namesBeingSaved.contains(lowered) || templates.contains { $0.id != id && $0.name.lowercased() == lowered }
    }

    /// `base`, or `base` with a number after it if a template goes by that name already: `Web`, `Web 2`, …
    public func availableName(from base: String) -> String {
        var candidate = base
        var counter = 2
        while isNameTaken(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: Saving

    /// Saves a machine as a template: as it is now, for which it has to be shut down, or as it was at
    /// `snapshot`. The machine itself stays as it is.
    ///
    /// Only what a machine has on its disk when it is shut down makes a template. A guest's memory
    /// belongs to the one machine it was saved in, so a snapshot that holds memory can't be one.
    ///
    /// On the disk the machine is on, the template shares the machine's space and is there at once. On
    /// another one its disks are copied, which takes as long as they are full. Cancelling the task stops
    /// that, and leaves nothing behind.
    ///
    /// - Parameter requestedName: The template's name. Without one it is named after the machine.
    @discardableResult
    public func save(
        _ machine: VirtualMachine, at snapshot: VMSnapshot? = nil, named requestedName: String? = nil
    ) async throws -> VMTemplate {
        // One may have been put in the folder by hand since it was read, and its name is taken too.
        load()
        let trimmed = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, isNameTaken(trimmed) {
            throw VMError.invalidConfiguration("A template named “\(trimmed)” already exists.")
        }
        if let snapshot {
            guard machine.snapshots.contains(where: { $0.id == snapshot.id }) else {
                throw VMError.invalidConfiguration("“\(machine.name)” has no snapshot named “\(snapshot.name)”.")
            }
            guard !snapshot.includesMemory else {
                throw VMError.invalidConfiguration(
                    "The snapshot “\(snapshot.name)” was taken while “\(machine.name)” was running, and a template is made from a machine that is shut down. Go back to the snapshot, shut “\(machine.name)” down, and save it as a template then."
                )
            }
        }
        let base = snapshot.map { "\(machine.name) (\($0.name))" } ?? machine.name
        let name = trimmed.isEmpty ? availableName(from: base) : trimmed
        namesBeingSaved.insert(name.lowercased())
        defer { namesBeingSaved.remove(name.lowercased()) }

        let work = { try await self.write(machine, at: snapshot, named: name) }
        // A snapshot is a copy that nothing writes to, so the machine it is of can be up meanwhile.
        return snapshot == nil
            ? try await machine.whileStopped(.savingTemplate, work)
            : try await machine.whileClaimed(.savingTemplate, work)
    }

    /// Writes the template for ``save(_:at:named:)``, on a machine that is claimed for it.
    private func write(_ machine: VirtualMachine, at snapshot: VMSnapshot?, named name: String) async throws -> VMTemplate {
        // From a snapshot, the template is what the machine would be after going back to it.
        let configuration = snapshot.map { machine.configuration.reverted(to: $0) } ?? machine.configuration
        let files = machine.bundle.portableFiles(for: configuration, at: snapshot)
        guard configuration.disks.allSatisfy({ disk in files.contains { $0.name == disk.fileName } }) else {
            throw VMError.invalidConfiguration(
                snapshot.map { "The snapshot “\($0.name)” is missing a disk." } ?? "“\(machine.name)” is missing a disk."
            )
        }
        // Where the template is written and where it ends up are one folder, on one disk.
        let folder = directory
        try prepare(folder)

        let template = VMTemplate(name: name, configuration: configuration)
        let package = folder.appending(
            path: "\(VMTemplate.unfinishedPrefix)\(template.id.uuidString).\(VMTemplate.pathExtension)", directoryHint: .isDirectory
        ).standardizedFileURL
        // Written down before anything is put there, so that what is left of it when the app is cut
        // off is found the next time.
        unfinished.append(package)
        saveSettings()
        defer {
            // What couldn't be removed, on a disk that was taken away for one, stays written down.
            if !Self.mayBeLeft(at: package) {
                unfinished.removeAll { $0.path == package.path }
            }
            saveSettings()
        }

        let cancellation = CancellationFlag()
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in machine.reportProgress(fraction, of: .savingTemplate) }
        }
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try template.write(to: package, files: files, progress: report, isCancelled: { cancellation.isSet })
            }.value
        } onCancel: {
            cancellation.set()
        }
        // Only a complete template gets its real name, so a half-written one is never listed.
        let destination = Self.availableURL(forName: name, in: folder)
        do {
            // A save that is called off as its copy comes to an end is called off all the same.
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: package, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
        locations[template.id] = destination
        templates = (templates + [template]).sorted(by: Self.isInOrder)
        return template
    }

    // MARK: Using, renaming and deleting

    /// Runs `operation`, which reads the template's files to make a machine from them. The template can't
    /// be deleted until it is over.
    public func whileUsing<T>(_ template: VMTemplate, _ operation: () async throws -> T) async rethrows -> T {
        useCounts[template.id, default: 0] += 1
        defer {
            let count = (useCounts[template.id] ?? 1) - 1
            useCounts[template.id] = count > 0 ? count : nil
        }
        return try await operation()
    }

    /// Gives a template another name. An empty name leaves it as it is.
    public func rename(_ template: VMTemplate, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = templates.firstIndex(where: { $0.id == template.id }),
              templates[index].name != trimmed, let url = locations[template.id]
        else { return }
        guard !isNameTaken(trimmed, besides: template.id) else {
            throw VMError.invalidConfiguration("A template named “\(trimmed)” already exists.")
        }
        var renamed = templates[index]
        renamed.name = trimmed
        try VMBundle.encoder.encode(renamed).write(to: url.appending(path: VMTemplate.fileName), options: .atomic)
        templates[index] = renamed
        templates.sort(by: Self.isInOrder)
    }

    /// Deletes a template. The machines that were made from it have disks of their own and stay as
    /// they are.
    ///
    /// - Parameter movingToTrash: Move its package to the Trash rather than remove it for good.
    public func remove(_ template: VMTemplate, movingToTrash: Bool) throws {
        guard let url = locations[template.id] else { return }
        guard useCounts[template.id] == nil else {
            throw VMError.invalidConfiguration("A virtual machine is being made from “\(template.name)”. Try again in a moment.")
        }
        if movingToTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
        locations[template.id] = nil
        templates.removeAll { $0.id == template.id }
    }

    // MARK: Private

    private static func isInOrder(_ first: VMTemplate, _ second: VMTemplate) -> Bool {
        let comparison = first.name.localizedStandardCompare(second.name)
        return comparison == .orderedSame ? first.id.uuidString < second.id.uuidString : comparison == .orderedAscending
    }

    /// A package URL in `folder` that doesn't exist yet, derived from the template's name.
    private static func availableURL(forName name: String, in folder: URL) -> URL {
        let base = VMLibrary.fileName(from: name)
        var candidate = folder.appending(path: "\(base).\(VMTemplate.pathExtension)", directoryHint: .isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) \(counter).\(VMTemplate.pathExtension)", directoryHint: .isDirectory)
            counter += 1
        }
        return candidate.standardizedFileURL
    }

    /// Makes sure templates can be kept in `folder`, which is created if it isn't there. Throws with what
    /// is in the way, in words for whoever chose the folder.
    private func prepare(_ folder: URL) throws {
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        let packages = [VMBundle.pathExtension, VMTemplate.pathExtension]
        guard !folder.pathComponents.contains(where: { packages.contains(($0 as NSString).pathExtension) }) else {
            throw VMError.invalidConfiguration("“\(shown)” is inside a virtual machine or a template. Choose a folder outside of it.")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw VMError.invalidConfiguration(
                "Templates can't be kept in “\(shown)”: \(error.localizedDescription) If the folder is on an external disk, connect the disk first."
            )
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw VMError.invalidConfiguration("Templates can't be kept in “\(shown)”: you don't have permission to add to that folder.")
        }
    }

    /// Writes down where templates are kept and which are being written. The library carries on without
    /// it: both are in memory, and written again with the next change.
    private func saveSettings() {
        let settings = Settings(
            directory: directory.path == defaultDirectory.path ? nil : directory.path,
            unfinished: unfinished.isEmpty ? nil : unfinished.map(\.path)
        )
        guard settings.directory != nil || settings.unfinished != nil else {
            // With nothing to write down, no file says the same.
            try? FileManager.default.removeItem(at: Self.settingsURL(in: rootDirectory))
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.settingsURL(in: rootDirectory), options: .atomic)
    }

    private struct Settings: Codable {
        /// Where templates are kept, if that isn't the default folder.
        var directory: String?
        /// The packages of templates that are being written.
        var unfinished: [String]?
    }
}
