import Darwin
import Foundation
import VMCore

/// The TPM 2.0 of a Windows guest: `swtpm`, in a process of its own next to QEMU, with what it holds in
/// one file in the machine's bundle (``VMBundle/tpmStateURL``).
///
/// QEMU is handed one end of a line and swtpm the other, as its control channel. QEMU starts the TPM
/// over it and hands it a second line, for the guest's commands. Once QEMU is gone the line closes, and
/// swtpm ends.
///
/// swtpm reads its options as `key=value` lists that a comma ends, with no way to escape one, so it runs
/// in the bundle and is given the file by its name there: a comma in the machine's path can't cut it short.
enum TPMEmulator {
    /// The descriptor swtpm finds its control line at.
    static let controlDescriptor: Int32 = QEMUProcess.firstDescriptor

    static func arguments(stateFileName: String) -> [String] {
        [
            "socket", "--tpm2",
            // `terminate`: end when QEMU, the one at the other end, is gone.
            "--ctrl", "type=unixio,clientfd=\(controlDescriptor),terminate",
            // `lock`: two at once would write over each other's state.
            "--tpmstate", "backend-uri=file://\(stateFileName),mode=0600,lock",
            // No `--log`: swtpm writes its errors to standard error by itself, which goes to the log.
            // Given that descriptor as a log, it would close it first, and then fail to start.
        ]
    }

    /// What swtpm says each time QEMU, at the other end, goes away: no news about why.
    static let disconnectNotice = "Data client disconnected"
    /// What swtpm starts each line it writes to standard error with.
    static let linePrefix = "swtpm: "

    /// What swtpm said last that tells why the machine didn't start, if anything did.
    static func complaint(in output: String) -> String? {
        output.split(separator: "\n")
            .map { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                return text.hasPrefix(linePrefix) ? String(text.dropFirst(linePrefix.count)) : text
            }
            .last { !$0.isEmpty && $0 != disconnectNotice }
    }

    static func pidFile(in bundle: VMBundle) -> URL {
        bundle.url.appending(path: "tpm.pid")
    }

    /// Starts the machine's TPM, and gives back QEMU's end of its line.
    static func launch(program: URL, bundle: VMBundle) throws -> (process: QEMUProcess, engineEnd: Int32) {
        var ends: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for end in ends {
            _ = fcntl(end, F_SETNOSIGPIPE, 1)
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        defer { close(ends[0]) }
        do {
            let process = try QEMUProcess.launch(
                program: program, arguments: arguments(stateFileName: bundle.tpmStateURL.lastPathComponent), descriptors: [ends[0]],
                log: bundle.logsDirectory.appending(path: "tpm.log"), pidFile: pidFile(in: bundle), directory: bundle.url
            )
            return (process, ends[1])
        } catch {
            close(ends[1])
            throw error
        }
    }

    /// Ends the TPM that a copy of the app left running for the machine in `bundle`, once its QEMU is
    /// gone, and waits until it has: the next one can't open the state while it holds it. It is told
    /// apart from another machine's by the folder it runs in.
    static func endLeftover(in bundle: VMBundle) async {
        let folder = bundle.url.resolvingSymlinksInPath().path
        await QEMUProcess.endLeftover(pidFile: pidFile(in: bundle)) { pid, arguments in
            guard let program = arguments.first, URL(fileURLWithPath: program).lastPathComponent == "swtpm",
                  let directory = workingDirectory(of: pid)
            else { return false }
            return URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == folder
        }
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
