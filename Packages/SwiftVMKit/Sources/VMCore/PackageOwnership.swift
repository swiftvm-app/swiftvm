import Darwin
import Foundation
import ResourceLocks
import Synchronization

/// Exclusive use of a package by a controller and its backends. The ownership file is never removed.
public final class PackageOwnership: Sendable {
    public enum Problem: Error, LocalizedError, Equatable {
        case inUse, unsafePackage, unsafeFile, changedConfiguration, resourcesInUse

        public var errorDescription: String? {
            switch self {
            case .inUse: "The virtual machine package is already in use by another controller or backend."
            case .unsafePackage: "The virtual machine package must be owned by this user and not writable by other users."
            case .unsafeFile: "The virtual machine's ownership or resource file is unsafe; exclusive use could not be established."
            case .changedConfiguration: "The virtual machine's files changed in another controller. Reload the machine before trying again."
            case .resourcesInUse: "A backend still holds the virtual machine's files. Wait for it to finish stopping before trying again."
            }
        }
    }

    private let directory: Int32
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private let runtimeResources = Mutex<Set<String>>([])

    /// Checks the saved configuration and native resources only after acquiring the package lock.
    public convenience init(in bundle: VMBundle, configuration: VMConfiguration) throws {
        try self.init(at: bundle.url)
        let data = try Data(contentsOf: bundle.configurationURL)
        var saved = try VMBundle.decoder.decode(VMConfiguration.self, from: data)
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Legacy documents synthesize a new date on each load. Only a persisted date can change.
        if fields?["createdAt"] == nil || fields?["createdAt"] is NSNull {
            saved.createdAt = configuration.createdAt
        }
        // ISO-8601 storage drops subsecond creation dates.
        guard try VMBundle.encoder.encode(saved) == VMBundle.encoder.encode(configuration) else {
            throw Problem.changedConfiguration
        }
        try requireReleasedResources(for: configuration)
        try requireMatches(bundle)
    }

    /// Native objects can release their files after the backend object itself has gone away.
    public func requireReleasedResources(for configuration: VMConfiguration) throws {
        try requireUnchangedLock()
        for disk in configuration.disks {
            try requireReleasedResource(disk.fileName, required: true)
        }
        if configuration.os.family == .macOS {
            try requireReleasedResource("aux.img", required: true)
        } else {
            // Both engines create this on first boot, while holding package ownership.
            try requireReleasedResource("efi-vars.fd", required: false)
        }
        try requireReleasedResource("tpm-state.bin", required: false)
    }

    /// Used after this owner has ended its own installer, while keeping other controllers excluded.
    public func waitForReleasedResources(for configuration: VMConfiguration) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            do {
                try requireReleasedResources(for: configuration)
                return
            } catch Problem.resourcesInUse where ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// A provider that creates first-boot firmware or a TPM must require that evidence thereafter,
    /// including on teardown: a vanished runtime file is not an uninitialized package.
    public func expectRuntimeResource(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw Problem.unsafeFile }
        _ = runtimeResources.withLock { $0.insert(name) }
    }

    /// Only for a newly and exclusively created directory, before its configuration or disks exist.
    static func claimNewBundle(_ bundle: VMBundle) throws -> PackageOwnership {
        try PackageOwnership(at: bundle.url)
    }

    private init(at url: URL) throws {
        guard !url.path.utf8.contains(0) else { throw Problem.unsafePackage }
        let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Self.systemError() }
        var folder = stat()
        guard fstat(directory, &folder) == 0 else {
            let error = Self.systemError()
            close(directory)
            throw error
        }
        guard folder.st_uid == getuid(), folder.st_mode & 0o022 == 0 else {
            close(directory)
            throw Problem.unsafePackage
        }
        // An incidental resource-probe fork must not keep another machine's owner alive. An explicit
        // child handoff duplicates the descriptor with posix_spawn file actions instead.
        let descriptor = openat(directory, "package.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_CLOFORK | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else {
            let error = Self.systemError()
            close(directory)
            throw error
        }
        do {
            var file = stat()
            guard fstat(descriptor, &file) == 0 else { throw Self.systemError() }
            guard file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1,
                  file.st_mode & 0o022 == 0 else { throw Problem.unsafeFile }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw Problem.inUse }
                throw Self.systemError()
            }
            var named = stat()
            guard fstatat(directory, "package.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == file.st_dev, named.st_ino == file.st_ino else { throw Problem.unsafeFile }
        } catch {
            close(descriptor)
            close(directory)
            throw error
        }
        self.directory = directory
        self.descriptor = descriptor
        self.device = folder.st_dev
        self.inode = folder.st_ino
    }

    deinit {
        // A surviving child shares this open-file description. Closing our copy must not unlock its.
        close(descriptor)
        close(directory)
    }

    /// The caller closes this duplicate after handing it to the child. A spawn launcher must make a
    /// temporary handoff copy with close-on-fork cleared before its file actions run.
    public func duplicateDescriptor() throws -> Int32 {
        try requireUnchangedLock()
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 64)
        guard copy >= 0 else { throw Self.systemError() }
        guard fcntl(copy, F_SETFD, FD_CLOEXEC | FD_CLOFORK) == 0 else {
            let error = Self.systemError()
            close(copy)
            throw error
        }
        return copy
    }

    /// Allows a retained runtime owner to perform live changes without reacquiring its own lock.
    public func requireMatches(_ bundle: VMBundle) throws {
        var folder = stat()
        guard stat(bundle.url.path, &folder) == 0, folder.st_dev == device, folder.st_ino == inode,
              folder.st_uid == getuid(), folder.st_mode & 0o022 == 0 else { throw Problem.unsafePackage }
        try requireUnchangedLock()
    }

    private func requireUnchangedLock() throws {
        var file = stat(), named = stat()
        guard fstat(descriptor, &file) == 0, fstatat(directory, "package.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1, file.st_mode & 0o022 == 0,
              file.st_dev == named.st_dev, file.st_ino == named.st_ino else { throw Problem.unsafeFile }
    }

    private func requireReleasedResource(_ name: String, required: Bool) throws {
        guard !name.utf8.contains(0) else { throw Problem.unsafeFile }
        let required = required || runtimeResources.withLock { $0.contains(name) }
        let result = name.withCString { swiftvm_probe_resource(directory, $0, required ? 1 : 0) }
        switch result.state {
        case SWIFTVM_RESOURCE_FREE:
            _ = runtimeResources.withLock { $0.insert(name) }
        case SWIFTVM_RESOURCE_ABSENT: return
        case SWIFTVM_RESOURCE_BUSY:
            _ = runtimeResources.withLock { $0.insert(name) }
            throw Problem.resourcesInUse
        case SWIFTVM_RESOURCE_UNSAFE: throw Problem.unsafeFile
        default: throw POSIXError(POSIXErrorCode(rawValue: result.errorNumber) ?? .EIO)
        }
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
