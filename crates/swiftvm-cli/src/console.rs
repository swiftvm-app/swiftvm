//! `swiftvm console`: connects this terminal to a machine's serial console.

use std::os::fd::RawFd;

use swiftvm_protocol::io;

use crate::util::exit;

/// The key that ends the session: Control-], as in telnet. Everything else, Control-C included, goes to
/// the guest.
const ESCAPE_BYTE: u8 = 0x1D;

/// Relays between the terminal and the console until the user leaves or the app goes away.
///
/// - `idle_timeout`: when input is piped in rather than typed, how long to keep printing output after the
///   input has ended and the guest has gone quiet. `None` picks a short while for piped input, and no
///   limit for a job in the background, which is there to record.
pub fn run(descriptor: RawFd, name: &str, idle_timeout: Option<f64>) -> ! {
    let stdin = libc::STDIN_FILENO;
    // A job in the background of a terminal may neither change the terminal's settings nor read from it
    // (it would be stopped for trying). It only listens.
    // SAFETY: tcgetpgrp and getpgrp only read.
    let is_background_job = io::is_terminal(stdin) && unsafe { libc::tcgetpgrp(stdin) != libc::getpgrp() };
    let is_interactive = io::is_terminal(stdin) && !is_background_job;
    let idle_timeout = idle_timeout.or(if is_background_job { None } else { Some(1.5) });
    // SAFETY: an all-zero termios is a valid value for tcgetattr to fill in.
    let mut original: libc::termios = unsafe { std::mem::zeroed() };
    if is_interactive {
        // SAFETY: valid pointers to termios values.
        unsafe {
            libc::tcgetattr(stdin, &mut original);
            let mut raw = original;
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(stdin, libc::TCSANOW, &raw);
        }
        note(&format!("Connected to the serial console of “{name}”. Press Return for a prompt, Control-] to leave."), true);
    }
    let leave = |message: Option<&str>, status: i32| -> ! {
        if is_interactive {
            // SAFETY: puts back the settings read above.
            unsafe { libc::tcsetattr(stdin, libc::TCSANOW, &original) };
            note(message.unwrap_or("Disconnected."), false);
        }
        exit(status)
    };

    let mut descriptors =
        [libc::pollfd { fd: descriptor, events: libc::POLLIN, revents: 0 }, libc::pollfd { fd: stdin, events: libc::POLLIN, revents: 0 }];
    let mut input_has_ended = is_background_job;
    let mut buffer = vec![0u8; 16 * 1024];
    loop {
        // Once piped input has run out, stay only until the guest stops answering.
        let timeout = if input_has_ended { idle_timeout.map_or(-1, |seconds| (seconds * 1000.0) as i32) } else { -1 };
        let count = if input_has_ended { 1 } else { 2 };
        // SAFETY: the array holds at least `count` pollfds.
        let ready = unsafe { libc::poll(descriptors.as_mut_ptr(), count, timeout) };
        if ready == 0 {
            leave(None, 0);
        }
        if ready < 0 {
            if io::errno() == libc::EINTR {
                continue;
            }
            leave(Some("The connection to SwiftVM was lost."), 1);
        }

        if descriptors[0].revents != 0 {
            let count = io::read(descriptor, &mut buffer);
            if count <= 0 {
                leave(Some("SwiftVM closed the console."), if input_has_ended { 0 } else { 1 });
            }
            io::write_all(libc::STDOUT_FILENO, &buffer[..count as usize]);
        }
        if !input_has_ended && descriptors[1].revents != 0 {
            let count = io::read(stdin, &mut buffer);
            if count <= 0 {
                input_has_ended = true;
                continue;
            }
            let mut bytes = &buffer[..count as usize];
            let mut wants_to_leave = false;
            if is_interactive && let Some(index) = bytes.iter().position(|&byte| byte == ESCAPE_BYTE) {
                bytes = &bytes[..index];
                wants_to_leave = true;
            }
            io::write_all(descriptor, bytes);
            if wants_to_leave {
                leave(None, 0);
            }
        }
    }
}

/// A line from this tool rather than from the guest. In raw mode a new line needs its own return.
fn note(text: &str, raw: bool) {
    let line = if raw { format!("\r\n[{text}]\r\n") } else { format!("\n[{text}]\n") };
    io::write_all(libc::STDERR_FILENO, line.as_bytes());
}
