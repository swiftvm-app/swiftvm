//! The frames a guest job travels in once the agent has taken it on: one byte for the kind, four for
//! the length of what follows, most significant first, and then that many bytes.

use std::os::fd::RawFd;
use std::time::{Duration, Instant};

use crate::io;
use crate::wire::JobEnd;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum JobFrameKind {
    /// From this side: bytes for the command's input. An empty one says there is no more to come.
    Input = 0,
    /// From the agent: what the command printed, or what the job is for.
    Output = 1,
    /// From the agent: what the command printed as errors.
    ErrorOutput = 2,
    /// From the agent, last: a `JobEnd` in JSON.
    End = 3,
}

impl JobFrameKind {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Input),
            1 => Some(Self::Output),
            2 => Some(Self::ErrorOutput),
            3 => Some(Self::End),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobFrame {
    pub kind: JobFrameKind,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    /// The other side hung up inside a frame, or sent something that isn't one.
    Malformed,
    /// The frame didn't arrive in the time given.
    TimedOut,
}

impl JobFrame {
    /// No frame is sent with more in it than this. What is longer goes in several.
    pub const MAXIMUM_PAYLOAD_LENGTH: usize = 64 * 1024;
    /// A frame that claims to be longer than this isn't one.
    const LONGEST_ACCEPTED_PAYLOAD: usize = 1024 * 1024;

    pub fn new(kind: JobFrameKind, payload: Vec<u8>) -> Self {
        JobFrame { kind, payload }
    }

    /// The frame as it travels.
    pub fn encoded(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(5 + self.payload.len());
        data.push(self.kind as u8);
        data.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        data.extend_from_slice(&self.payload);
        data
    }

    /// What an `End` frame says. A frame that can't be read says that much.
    pub fn end(&self) -> Option<JobEnd> {
        if self.kind != JobFrameKind::End {
            return None;
        }
        Some(serde_json::from_slice(&self.payload).unwrap_or_else(|_| JobEnd::failure("The guest ended the job without saying how.")))
    }

    /// Writes `payload` as frames of `kind`, as many as it takes, and at least one. Returns `false` when
    /// the connection failed. Whoever shares a connection between threads takes turns at this.
    pub fn write(kind: JobFrameKind, payload: &[u8], descriptor: RawFd) -> bool {
        let mut rest = payload;
        loop {
            let piece = &rest[..rest.len().min(Self::MAXIMUM_PAYLOAD_LENGTH)];
            rest = &rest[piece.len()..];
            if !io::write_all(descriptor, &JobFrame::new(kind, piece.to_vec()).encoded()) {
                return false;
            }
            if rest.is_empty() {
                return true;
            }
        }
    }

    /// Reads the next frame. Returns `Ok(None)` when the other side hung up between two frames. Frames
    /// of a kind this build doesn't know are passed over. When given, `timeout` covers the whole frame
    /// and any passed over before it.
    pub fn read(descriptor: RawFd, timeout: Option<Duration>) -> Result<Option<JobFrame>, FrameError> {
        let deadline = timeout.map(|timeout| Instant::now() + timeout);
        loop {
            let Some(header) = read_exactly(descriptor, 5, true, deadline)? else { return Ok(None) };
            let length = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
            if length > Self::LONGEST_ACCEPTED_PAYLOAD {
                return Err(FrameError::Malformed);
            }
            let payload = read_exactly(descriptor, length, false, deadline)?.ok_or(FrameError::Malformed)?;
            if let Some(kind) = JobFrameKind::from_byte(header[0]) {
                return Ok(Some(JobFrame::new(kind, payload)));
            }
        }
    }
}

fn read_exactly(descriptor: RawFd, count: usize, allowing_end: bool, deadline: Option<Instant>) -> Result<Option<Vec<u8>>, FrameError> {
    let mut data = vec![0u8; count];
    let mut offset = 0;
    while offset < count {
        if let Some(deadline) = deadline {
            let milliseconds = io::milliseconds_until(deadline).ok_or(FrameError::TimedOut)?;
            let ready = io::poll_readable(descriptor, milliseconds);
            if ready < 0 && io::errno() != libc::EINTR {
                return Err(FrameError::Malformed);
            }
            if ready <= 0 {
                continue;
            }
        }
        let received = io::read(descriptor, &mut data[offset..]);
        if received > 0 {
            offset += received as usize;
        } else if received == 0 {
            if offset == 0 && allowing_end {
                return Ok(None);
            }
            return Err(FrameError::Malformed);
        } else {
            return Err(FrameError::Malformed);
        }
    }
    Ok(Some(data))
}
