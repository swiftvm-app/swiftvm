import DiskTools
import Foundation
import Installers
import VMCore
import VZEngine

/// Operations on a machine's disks: making a copy of the machine, moving it and growing its disk.
extension AppModel {
    /// A name for a copy of `machine` that nothing else uses: `Name copy`, `Name copy 2`, …
    func nameForCopy(of machine: VirtualMachine) -> String {
        let base = "\(machine.name) copy"
        var candidate = base
        var counter = 2
        while isNameTaken(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// Makes a copy of a machine that is shut down. The copy is a machine of its own: it gets a new
    /// identifier, network card, address and SSH name, and shares disk space with the original for as long
    /// as their contents are the same.
    @discardableResult
    func duplicate(_ machine: VirtualMachine, named requestedName: String? = nil) async throws -> VirtualMachine {
        // One copy at a time. Each picks a name and an SSH alias that are free when it starts, and two
        // running side by side could pick the same.
        let previous = lastDuplication
        let duplication = Task {
            await previous?.value
            return try await performDuplicate(machine, named: requestedName)
        }
        lastDuplication = Task { _ = try? await duplication.value }
        return try await duplication.value
    }

    private func performDuplicate(_ machine: VirtualMachine, named requestedName: String?) async throws -> VirtualMachine {
        let name = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, isNameTaken(name) {
            throw VMError.invalidConfiguration("A virtual machine named “\(name)” already exists.")
        }
        return try await machine.whileStopped(.duplicating) {
            let copyName = name.isEmpty ? nameForCopy(of: machine) : name
            let alias = reserveAlias(for: copyName)
            defer { reservedAliases.remove(alias) }
            let configuration = machine.configuration.duplicated(name: copyName, sshAlias: alias)
            // Next to the original, wherever that is: on its disk the copy shares the original's space,
            // and on another one it would be written out in full.
            return try await makeCopy(of: machine.bundle, configuration: configuration, in: machine.bundle.url.deletingLastPathComponent())
        }
    }

    /// Makes a machine of its own from the disks and firmware in `source`, which is a machine's bundle
    /// or a template's: copies them into a new bundle, gives the copy what tells it from the original,
    /// and adds it to the library. Cancelling the task stops the copying, and leaves nothing behind.
    ///
    /// - Parameters:
    ///   - configuration: The copy's, with an identifier, a name and an SSH alias of its own.
    ///   - folder: Where to keep the copy. `nil` is the folder for new machines.
    ///   - diskCapacity: The size to grow the copy's disk to, which `configuration` has for it already.
    ///   - progress: Called with how far the copying has come, from 0 to 1, where it takes time.
    func makeCopy(
        of source: VMBundle, configuration: VMConfiguration, in folder: URL?, growingDiskTo diskCapacity: UInt64? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VirtualMachine {
        let alias = configuration.ssh.alias
        let destination = try library.makeStagingBundleURL(in: folder)

        // On APFS this takes no time; on another file system it copies every byte of the disks.
        let copying = Task.detached(priority: .userInitiated) {
            let copy = try source.duplicate(
                to: destination, configuration: configuration, progress: progress, isCancelled: { Task.isCancelled }
            )
            do {
                if let diskCapacity, let disk = configuration.systemDisk {
                    try DiskService.growDisk(at: copy.diskURL(for: disk), format: disk.format, to: diskCapacity)
                }
                switch configuration.os.family {
                case .macOS:
                    try MacOSInstaller.assignNewMachineIdentifier(to: copy)
                case .linux where configuration.installation.attachesSeedImage:
                    // Without this the copy would come up with the original's host name and wait for
                    // a network card that isn't there.
                    if FileManager.default.fileExists(atPath: copy.seedImageURL.path) {
                        try CloudInitSeed.reissue(
                            at: copy.seedImageURL,
                            hostName: alias,
                            macAddress: configuration.networkInterfaces.first?.macAddress
                        )
                    }
                case .linux, .windows:
                    // A new identifier is made when the copy first starts.
                    break
                }
            } catch {
                try? FileManager.default.removeItem(at: copy.url)
                throw error
            }
            return copy
        }
        let copy: VMBundle
        do {
            copy = try await withTaskCancellationHandler {
                try await copying.value
            } onCancel: {
                copying.cancel()
            }
            try Task.checkCancellation()
        } catch {
            library.discard(staged: VMBundle(url: destination))
            throw error
        }

        sshWriter.forgetHostKey(for: alias)
        do {
            return try addToLibrary(staged: copy)
        } catch {
            library.discard(staged: copy)
            throw error
        }
    }

    /// Duplicates a machine for a menu command. A failure is shown wherever the machine's errors are: in
    /// its own window if that is open, otherwise in the menu bar panel.
    func duplicateReportingErrors(_ machine: VirtualMachine) {
        Task {
            do {
                try await duplicate(machine)
            } catch {
                machine.lastError = VMErrorInfo(title: "Couldn't duplicate “\(machine.name)”", message: error.localizedDescription)
            }
        }
    }

    /// Moves a machine that is shut down into `folder`, which may be on another disk: then its files
    /// are copied there, which takes a while, and can be called off with ``cancelMove(of:)``.
    func move(_ machine: VirtualMachine, to folder: URL) async throws {
        if moves[machine.id] != nil {
            throw VMError.busy(name: machine.name, .moving)
        }
        // A task of its own, so that the move can be called off whoever is waiting for it.
        let task = Task { try await library.move(machine, to: folder) }
        moves[machine.id] = task
        defer { moves[machine.id] = nil }
        try await task.value
    }

    /// Calls off a move that is still copying. The machine stays where it was.
    func cancelMove(of machine: VirtualMachine) {
        moves[machine.id]?.cancel()
    }

    func cancelMoves() {
        moves.values.forEach { $0.cancel() }
    }

    /// Moves a machine for a button in its settings. A failure is shown wherever the machine's errors are.
    func moveReportingErrors(_ machine: VirtualMachine, to folder: URL) {
        Task {
            do {
                try await move(machine, to: folder)
            } catch is CancellationError {
                // Called off by whoever started it.
            } catch {
                machine.lastError = VMErrorInfo(title: "Couldn't move “\(machine.name)”", message: error.localizedDescription)
            }
        }
    }

    /// Takes a snapshot for a menu command, under the next free name.
    func takeSnapshotReportingErrors(of machine: VirtualMachine) {
        Task {
            do {
                try await machine.takeSnapshot()
            } catch {
                machine.lastError = VMErrorInfo(title: "Couldn't take a snapshot of “\(machine.name)”", message: error.localizedDescription)
            }
        }
    }

    /// Grows the disk of a machine that is shut down. The guest has to grow its own partition into the new
    /// space; systems set up by SwiftVM from a cloud image do that at their next start.
    func resizeDisk(of machine: VirtualMachine, to capacity: UInt64) async throws {
        try await machine.whileStopped(.resizingDisk) {
            guard let disk = machine.configuration.systemDisk else {
                throw VMError.invalidConfiguration("“\(machine.name)” has no disk.")
            }
            guard capacity > disk.capacity else {
                throw VMError.invalidConfiguration(
                    "The disk is \(Formatting.bytes(disk.capacity)) already. A disk can grow, but it can't shrink."
                )
            }
            let url = machine.bundle.diskURL(for: disk)
            try await Task.detached(priority: .userInitiated) {
                try DiskService.growDisk(at: url, format: disk.format, to: capacity)
            }.value
            try machine.updateConfiguration { configuration in
                guard let index = configuration.disks.firstIndex(where: { $0.id == disk.id }) else { return }
                configuration.disks[index].capacity = capacity
            }
        }
    }
}
