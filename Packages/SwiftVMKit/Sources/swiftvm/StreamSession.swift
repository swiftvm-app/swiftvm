import Foundation
import GuestChannel
import VMControl

/// `swiftvm vsock`: connects this command's standard input and output to a port in a guest.
enum StreamSession {
    /// Where a guest's SSH server listens on its socket device. systemd sets that up by itself from
    /// version 256 on; the SwiftVM guest agent adds it to older systems.
    static let sshPort: UInt32 = 22

    /// Relays between standard input and output and the stream until the guest's side has finished.
    static func run(descriptor: Int32) -> Never {
        // A reader that has gone away is an ordinary end of the conversation, not a reason to be killed.
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread {
            // The end of the input is passed on; what the guest still has to say comes through below.
            if !ByteRelay.copy(from: STDIN_FILENO, to: descriptor) {
                exit(1)
            }
        }
        exit(ByteRelay.copy(from: descriptor, to: STDOUT_FILENO) ? 0 : 1)
    }
}
