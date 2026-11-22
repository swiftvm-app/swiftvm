import Darwin
import Foundation

/// Finds the process that Virtualization.framework runs a machine in.
///
/// The framework runs each machine in an XPC service of its own, which the app has no handle on. What
/// tells one machine's apart from another's is the files it holds open: those of the machine's bundle,
/// such as its firmware variables or its auxiliary storage.
enum VirtualizationProcess {
    /// The name of the service's program.
    static let programName = "com.apple.Virtualization.VirtualMachine"

    /// The process of the machine whose bundle is `folder`, or `nil` if none holds a file of it open.
    /// It looks through every process of this user, so it isn't for the main thread.
    static func find(holdingFilesIn folder: URL) -> pid_t? {
        // The way the system reports open files: `resolvingSymlinksInPath()` would leave `/private` off
        // a folder in /tmp or /var, which the system's paths have.
        guard let resolved = realpath(folder.path, nil) else { return nil }
        let folderPath = String(cString: resolved)
        free(resolved)
        return candidates().first { pid in
            holdsFile(in: folderPath, openPaths: openFilePaths(of: pid))
        }
    }

    /// Whether one of `openPaths` is inside `folder`. Both are paths from the root as `realpath(3)` has
    /// them, which is how the system reports open files.
    static func holdsFile(in folder: String, openPaths: [String]) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return openPaths.contains { $0.hasPrefix(prefix) }
    }

    /// The processes that run the framework's service, newest first: a machine that has just started is
    /// likelier to be one of the last.
    private static func candidates() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Room for processes that start while they are listed.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let user = getuid()
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, programPath(of: pid).map({ URL(fileURLWithPath: $0).lastPathComponent }) == programName else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size && info.pbsi_uid == user
        }.sorted(by: >)
    }

    private static func programPath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func openFilePaths(of pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for files it opens while they are listed.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return descriptors.prefix(Int(filled) / stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
            var info = vnode_fdinfowithpath()
            let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
    }
}
