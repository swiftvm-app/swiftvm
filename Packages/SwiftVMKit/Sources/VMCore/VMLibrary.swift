import Foundation
import Observation

/// The set of virtual machines the app knows about.
@MainActor
@Observable
public final class VMLibrary {
    public private(set) var machines: [VirtualMachine] = []
    /// Bundles that are listed in the index but couldn't be opened, with the reason.
    public private(set) var unreadableBundles: [URL: String] = [:]

    /// Application Support directory that holds the index and, by default, the machines.
    public let rootDirectory: URL

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

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Where new machines are created.
    public var machinesDirectory: URL {
        rootDirectory.appending(path: "Machines", directoryHint: .isDirectory)
    }

    /// Where a machine is put together before it joins the library. Creating one can take a long time
    /// (downloading, installing), and a half-made bundle must never show up as a machine.
    public var stagingDirectory: URL {
        machinesDirectory.appending(path: ".staging", directoryHint: .isDirectory)
    }

    private var indexURL: URL { rootDirectory.appending(path: "library.json") }

    // MARK: Loading

    /// Loads the index and picks up any bundle found in the machines directory.
    public func load() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: machinesDirectory, withIntermediateDirectories: true)

        var urls: [URL] = []
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            urls = index.bundles.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        }
        let discovered = (try? fileManager.contentsOfDirectory(at: machinesDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in discovered.sorted(by: { $0.path < $1.path }) where url.pathExtension == VMBundle.pathExtension {
            let standardized = url.standardizedFileURL
            if !urls.contains(standardized) {
                urls.append(standardized)
            }
        }

        var loaded: [VirtualMachine] = []
        var failures: [URL: String] = [:]
        for url in urls {
            if let existing = machines.first(where: { $0.bundle.url == url }) {
                loaded.append(existing)
                continue
            }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                let machine = try VirtualMachine(bundle: VMBundle(url: url))
                guard !loaded.contains(where: { $0.id == machine.id }) else { continue }
                adopt(machine)
                loaded.append(machine)
            } catch {
                failures[url] = error.localizedDescription
            }
        }
        machines = loaded
        unreadableBundles = failures
        saveIndex()
        onChange?()
    }

    public func machine(id: UUID) -> VirtualMachine? {
        machines.first { $0.id == id }
    }

    // MARK: Adding and removing

    /// A bundle URL in the machines directory that doesn't exist yet, derived from the machine name.
    public func availableBundleURL(forName name: String) -> URL {
        let base = Self.fileName(from: name)
        var candidate = machinesDirectory.appending(path: "\(base).\(VMBundle.pathExtension)", directoryHint: .isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = machinesDirectory.appending(path: "\(base) \(counter).\(VMBundle.pathExtension)", directoryHint: .isDirectory)
            counter += 1
        }
        return candidate
    }

    /// A bundle URL in the staging directory for a machine that is about to be created.
    public func makeStagingBundleURL() throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        return stagingDirectory.appending(path: "\(UUID().uuidString).\(VMBundle.pathExtension)", directoryHint: .isDirectory)
    }

    /// Moves a finished bundle out of the staging directory and adds it to the library.
    @discardableResult
    public func add(staged bundle: VMBundle) throws -> VirtualMachine {
        let name = try bundle.loadConfiguration().name
        let destination = availableBundleURL(forName: name)
        try FileManager.default.moveItem(at: bundle.url, to: destination)
        do {
            return try add(VMBundle(url: destination))
        } catch {
            // Back to where the caller keeps track of it, rather than a bundle in the machines folder
            // that the library refused.
            try? FileManager.default.moveItem(at: destination, to: bundle.url)
            throw error
        }
    }

    /// Deletes bundles left in the staging directory by a creation that never finished, for example because
    /// the app quit in the middle of it. Call before any creation starts.
    public func removeStagedBundles() {
        try? FileManager.default.removeItem(at: stagingDirectory)
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
        saveIndex()
        onChange?()
    }

    // MARK: Private

    private func adopt(_ machine: VirtualMachine) {
        machine.backendProvider = backendProvider
        machine.onConfigurationChange = { [weak self] _ in self?.onChange?() }
        machine.onResume = { [weak self] machine in self?.onMachineResume?(machine) }
        machine.onGuestStart = { [weak self] machine in self?.onMachineStart?(machine) }
        machine.onGuestAddressesChange = { [weak self] machine in self?.onGuestAddressesChange?(machine) }
        machine.onGuestAgentChange = { [weak self] machine in self?.onGuestAgentChange?(machine) }
        machine.onGuestClipboard = { [weak self] machine, text in self?.onGuestClipboard?(machine, text) }
        machine.onGuestClipboardRequest = { [weak self] machine in self?.onGuestClipboardRequest?(machine) }
        machine.isStartAllowed = { [weak self] in self?.allowsStarting ?? true }
    }

    private func saveIndex() {
        let index = Index(bundles: machines.map(\.bundle.url.path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Turns a machine name into a safe file name.
    nonisolated static func fileName(from name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\0").union(.newlines)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let trimmedDots = cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
        return trimmedDots.isEmpty ? "Virtual Machine" : trimmedDots
    }

    private struct Index: Codable {
        var bundles: [String]
    }
}
