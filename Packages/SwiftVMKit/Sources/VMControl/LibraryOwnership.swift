import Foundation

/// One controller owns a data folder, independently of the app's identity. This is not a VM resource lock.
public final class LibraryOwnership: Sendable {
    public enum Problem: Error, LocalizedError, Equatable {
        case inUse, unsafeDirectory, unsafeFile, wrongDirectory

        public var errorDescription: String? {
            switch self {
            case .inUse: "This SwiftVM data folder is already in use by another controller. Use the app already managing this folder, or choose a separate SWIFTVM_HOME."
            case .unsafeDirectory: "The SwiftVM data folder must be owned by this user and not writable by other users."
            case .unsafeFile: "The SwiftVM library ownership file is unsafe; exclusive ownership could not be established."
            case .wrongDirectory: "The control socket and library ownership belong to different data folders."
            }
        }
    }

    public let directory: URL
    private let descriptor: Int32

    public init(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let endpoint = directory.appending(path: "control.sock")
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        var folder = stat()
        guard stat(directory.path, &folder) == 0 else { throw ControlSocketError.system("inspect data folder", errno) }
        guard folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid(), folder.st_mode & 0o022 == 0 else {
            throw Problem.unsafeDirectory
        }
        let file = directory.appending(path: "library.lock")
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw ControlSocketError.system("open library ownership", errno) }
        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else { throw ControlSocketError.system("read library ownership", errno) }
            guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid(),
                  information.st_nlink == 1, information.st_mode & 0o022 == 0 else { throw Problem.unsafeFile }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw Problem.inUse }
                throw ControlSocketError.system("lock library ownership", errno)
            }
            var named = stat()
            guard lstat(file.path, &named) == 0, named.st_dev == information.st_dev,
                  named.st_ino == information.st_ino else { throw Problem.unsafeFile }
            // An older controller may have no library lock. A live or ambiguous endpoint is not stale.
            try ControlSocket.requireStaleEndpoint(at: endpoint)
        } catch {
            close(descriptor)
            throw error
        }
        self.directory = directory
        self.descriptor = descriptor
    }

    deinit {
        // Never unlink: another owner must lock this same inode, including after a process exits.
        close(descriptor)
    }
}
