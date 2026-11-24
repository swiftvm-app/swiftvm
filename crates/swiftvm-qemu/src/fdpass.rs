//! Descriptors that ride along with bytes over a Unix socket (`SCM_RIGHTS`): the lines the app hands the
//! service for a machine, and the display's line the service hands QEMU.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// The most descriptors taken from one read. More than that are closed.
pub const MOST_DESCRIPTORS: usize = 16;

/// Sends what of `bytes` fits in one go over `socket`, with copies of `descriptors`. Returns how many
/// bytes went. Fails with `WouldBlock` on a socket that isn't ready.
pub fn send(socket: RawFd, bytes: &[u8], descriptors: &[RawFd]) -> io::Result<usize> {
    let payload = std::mem::size_of_val(descriptors) as u32;
    // SAFETY: CMSG_SPACE only computes a size.
    let space = unsafe { libc::CMSG_SPACE(payload) } as usize;
    let mut control = vec![0u8; space.max(1)];
    let mut vector = libc::iovec { iov_base: bytes.as_ptr() as *mut _, iov_len: bytes.len() };
    // SAFETY: zeroed msghdr is a valid empty message; every pointer set below outlives the call.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    if !descriptors.is_empty() {
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = space as _;
        // SAFETY: the control buffer is CMSG_SPACE(payload) long, enough for one header and its data.
        unsafe {
            let header = libc::CMSG_FIRSTHDR(&message);
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(payload) as _;
            std::ptr::copy_nonoverlapping(descriptors.as_ptr(), libc::CMSG_DATA(header).cast::<RawFd>(), descriptors.len());
        }
    }
    // SAFETY: the message is valid for the call.
    let sent = unsafe { libc::sendmsg(socket, &message, send_flags()) };
    if sent < 0 { Err(io::Error::last_os_error()) } else { Ok(sent as usize) }
}

fn send_flags() -> libc::c_int {
    #[cfg(target_os = "linux")]
    {
        libc::MSG_NOSIGNAL
    }
    #[cfg(not(target_os = "linux"))]
    {
        0
    }
}

/// Reads what has arrived on `socket` into `buffer`, and the descriptors that came with it, each closed
/// when exec'ing another program. Returns how many bytes were read. Fails with `WouldBlock` when nothing
/// is there.
pub fn receive(socket: RawFd, buffer: &mut [u8], descriptors: &mut Vec<OwnedFd>) -> io::Result<usize> {
    let payload = (MOST_DESCRIPTORS * std::mem::size_of::<RawFd>()) as u32;
    // SAFETY: CMSG_SPACE only computes a size.
    let space = unsafe { libc::CMSG_SPACE(payload) } as usize;
    let mut control = vec![0u8; space];
    let mut vector = libc::iovec { iov_base: buffer.as_mut_ptr().cast(), iov_len: buffer.len() };
    // SAFETY: zeroed msghdr is a valid empty message; every pointer set below outlives the call.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = space as _;
    #[cfg(target_os = "linux")]
    let flags = libc::MSG_CMSG_CLOEXEC;
    #[cfg(not(target_os = "linux"))]
    let flags = 0;
    // SAFETY: the message is valid for the call.
    let count = unsafe { libc::recvmsg(socket, &mut message, flags) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the kernel filled in the control buffer that the message points to.
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(&message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                let data = libc::CMSG_DATA(header).cast::<RawFd>();
                let length = (*header).cmsg_len as usize - (data as usize - header as usize);
                for index in 0..length / std::mem::size_of::<RawFd>() {
                    let descriptor = OwnedFd::from_raw_fd(std::ptr::read_unaligned(data.add(index)));
                    set_close_on_exec(descriptor.as_raw_fd());
                    if descriptors.len() < MOST_DESCRIPTORS {
                        descriptors.push(descriptor);
                    }
                }
            }
            header = libc::CMSG_NXTHDR(&message, header);
        }
    }
    Ok(count as usize)
}

pub fn set_close_on_exec(descriptor: RawFd) {
    // SAFETY: fcntl on a descriptor that is open.
    unsafe {
        let flags = libc::fcntl(descriptor, libc::F_GETFD);
        if flags >= 0 {
            libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
}

/// A connected pair of sockets of `kind` (`SOCK_STREAM`, `SOCK_DGRAM`), each closed when exec'ing.
pub fn socket_pair(kind: libc::c_int) -> io::Result<(OwnedFd, OwnedFd)> {
    let mut ends = [0; 2];
    // SAFETY: socketpair writes two descriptors into the array.
    if unsafe { libc::socketpair(libc::AF_UNIX, kind, 0, ends.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: both were just made, and are this function's.
    let ends = unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
    for end in [&ends.0, &ends.1] {
        set_close_on_exec(end.as_raw_fd());
        #[cfg(target_os = "macos")]
        // SAFETY: fcntl on a descriptor that is open.
        unsafe {
            libc::fcntl(end.as_raw_fd(), libc::F_SETNOSIGPIPE, 1);
        }
    }
    Ok(ends)
}
