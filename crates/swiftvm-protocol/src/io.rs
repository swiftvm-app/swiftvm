//! Reading and writing raw descriptors, which a connection, a pipe and a terminal all are. The same
//! descriptor is read on one thread and written on another, so this stays below `std`'s buffered types.

use std::ffi::CStr;
use std::os::fd::RawFd;
use std::time::Instant;

pub fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// What the system says about `code`, as `strerror` puts it.
pub fn strerror(code: i32) -> String {
    // SAFETY: strerror returns a pointer to a NUL-terminated string that stays valid until the next call.
    unsafe { CStr::from_ptr(libc::strerror(code)) }.to_string_lossy().into_owned()
}

/// Reads what is there, up to `buffer.len()` bytes, trying again when a signal interrupts. Returns the
/// count, 0 at the end, or a negative number when the descriptor failed.
pub fn read(descriptor: RawFd, buffer: &mut [u8]) -> isize {
    loop {
        // SAFETY: the buffer is valid for writes of its length.
        let count = unsafe { libc::read(descriptor, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count < 0 && errno() == libc::EINTR {
            continue;
        }
        return count;
    }
}

/// Writes all of `bytes`, however many calls that takes. Returns `false` if the descriptor failed.
pub fn write_all(descriptor: RawFd, bytes: &[u8]) -> bool {
    let mut offset = 0;
    while offset < bytes.len() {
        // SAFETY: the slice is valid for reads of what is left of it.
        let written = unsafe { libc::write(descriptor, bytes[offset..].as_ptr().cast(), bytes.len() - offset) };
        if written > 0 {
            offset += written as usize;
        } else if errno() != libc::EINTR {
            return false;
        }
    }
    true
}

pub fn shutdown(descriptor: RawFd, how: i32) -> i32 {
    // SAFETY: shutdown takes any descriptor and says so when it isn't a socket.
    unsafe { libc::shutdown(descriptor, how) }
}

pub fn close(descriptor: RawFd) {
    // SAFETY: the caller owns the descriptor and doesn't use it again.
    unsafe { libc::close(descriptor) };
}

pub fn is_terminal(descriptor: RawFd) -> bool {
    // SAFETY: isatty takes any descriptor.
    unsafe { libc::isatty(descriptor) == 1 }
}

/// Waits until `descriptor` can be read, for `milliseconds` at most (-1 for as long as it takes).
/// Returns what `poll` does: above zero when it can, zero when the time ran out, below zero on failure.
pub fn poll_readable(descriptor: RawFd, milliseconds: i32) -> i32 {
    let mut waiting = libc::pollfd { fd: descriptor, events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid pollfd.
    unsafe { libc::poll(&mut waiting, 1, milliseconds) }
}

/// The milliseconds to `deadline` for `poll`, at least 1 while any time is left and at most a minute,
/// or `None` once it has passed.
pub fn milliseconds_until(deadline: Instant) -> Option<i32> {
    let remaining = deadline.checked_duration_since(Instant::now())?;
    if remaining.is_zero() {
        return None;
    }
    Some((remaining.as_secs_f64() * 1000.0).ceil().clamp(1.0, 60_000.0) as i32)
}

/// Copies from `source` to `destination` until `source` ends, then tells `destination` that nothing
/// more is coming. Returns `false` if either descriptor failed instead.
pub fn copy(source: RawFd, destination: RawFd) -> bool {
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let count = read(source, &mut buffer);
        if count == 0 {
            // Something that can't be closed in one direction only is left to the caller.
            return shutdown(destination, libc::SHUT_WR) == 0 || matches!(errno(), libc::ENOTSOCK | libc::ENOTCONN);
        }
        if count < 0 {
            return false;
        }
        if !write_all(destination, &buffer[..count as usize]) {
            return false;
        }
    }
}

/// Reads up to and including the next newline, a byte at a time so that nothing after it is taken.
/// Returns the line without it, or `None` at the end of the stream or on failure.
pub fn read_line(descriptor: RawFd) -> Option<Vec<u8>> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        let count = read(descriptor, &mut byte);
        if count == 1 {
            if byte[0] == b'\n' {
                return Some(line);
            }
            line.push(byte[0]);
        } else if count == 0 {
            return if line.is_empty() { None } else { Some(line) };
        } else {
            return None;
        }
    }
}

/// Writes `data` and a newline.
pub fn write_line(descriptor: RawFd, data: &[u8]) -> Result<(), i32> {
    let mut message = Vec::with_capacity(data.len() + 1);
    message.extend_from_slice(data);
    message.push(b'\n');
    if write_all(descriptor, &message) { Ok(()) } else { Err(errno()) }
}
