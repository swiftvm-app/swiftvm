//! `swiftvm vsock`: connects this command's standard input and output to a port in a guest.

use std::os::fd::RawFd;

use swiftvm_protocol::io;

use crate::util::{exit, ignore_broken_pipe_signal};

/// Where a guest's SSH server listens on its socket device. systemd sets that up by itself from version
/// 256 on; the SwiftVM guest agent adds it to older systems.
pub const SSH_PORT: u32 = 22;

/// Relays between standard input and output and the stream until the guest's side has finished.
pub fn run(descriptor: RawFd) -> ! {
    // A reader that has gone away is an ordinary end of the conversation, not a reason to be killed.
    ignore_broken_pipe_signal();
    std::thread::spawn(move || {
        // The end of the input is passed on; what the guest still has to say comes through below.
        if !io::copy(libc::STDIN_FILENO, descriptor) {
            exit(1);
        }
    });
    exit(if io::copy(descriptor, libc::STDOUT_FILENO) { 0 } else { 1 })
}
