import Darwin
import Foundation

extension VMBundle {
    /// Only absence in an accessible package permits a cold boot. `fileExists` would also say no
    /// for an inaccessible path or a dangling symlink, neither of which proves memory is absent.
    func requireNoSavedState() throws {
        let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            throw VMError.invalidConfiguration("Can't check the virtual machine's saved state: \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)")
        }
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, savedStateURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw VMError.invalidConfiguration("The virtual machine has saved state. Use start to resume it, or explicitly discard its saved state before requesting a cold boot.")
        }
        guard errno == ENOENT else {
            throw VMError.invalidConfiguration("Can't check the virtual machine's saved state: \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)")
        }
    }
}
