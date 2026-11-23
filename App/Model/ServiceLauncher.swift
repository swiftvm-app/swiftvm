import Foundation
import VMControl

/// Starts `swiftvm serve`, the service that the `swiftvm` tool, AI agents and other apps talk to. It runs
/// on its own: it outlives the app, and stops by itself when its program is replaced by an update.
extension AppModel {
    /// Starts the service from the tool in the app, unless one already answers. A service the app starts
    /// has the app as the one responsible for it, so macOS asks about what it does in SwiftVM's name.
    func startService() {
        guard let tool = commandLineToolURL else { return }
        if let connection = try? ControlSocket.connect(to: ControlPaths.serviceSocket) {
            close(connection)
            return
        }
        do {
            try FileManager.default.createDirectory(at: ControlPaths.applicationSupport, withIntermediateDirectories: true)
            let pid = try ServiceLauncher.spawn(tool: tool, log: ControlPaths.serviceLog)
            // Collected when it ends, so that it doesn't linger as a zombie while the app runs.
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        } catch {
            NSLog("SwiftVM: the service couldn't be started: \(error.localizedDescription)")
        }
    }
}

nonisolated enum ServiceLauncher {
    /// Runs `<tool> serve` in a session of its own, so that what ends the app's doesn't end it, with what
    /// it says added to `log`.
    static func spawn(tool: URL, log: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = [tool.path, "serve"]
        var pointers = arguments.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, tool.path, &actions, &attributes, &pointers, environ)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return pid
    }
}
