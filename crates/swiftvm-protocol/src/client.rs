//! Sends requests to the running app over its control socket.

use std::fmt;
use std::os::fd::{OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use crate::io;
use crate::wire::{ControlRequest, ControlResponse};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientError {
    PathTooLong(String),
    System(&'static str, i32),
    /// Nothing listens on the socket. Carries the name of the app that should.
    AppNotRunning(String),
    ConnectionClosed,
    InvalidMessage,
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ClientError::PathTooLong(path) => write!(f, "The control socket path is too long: {path}"),
            ClientError::System(operation, code) => write!(f, "{operation} failed: {}", io::strerror(*code)),
            ClientError::AppNotRunning(app) => write!(f, "{app} isn't running. Open the app first."),
            ClientError::ConnectionClosed => f.write_str("The app closed the connection before answering."),
            ClientError::InvalidMessage => f.write_str("Received a message that couldn't be understood."),
        }
    }
}

impl std::error::Error for ClientError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlClient {
    pub socket: PathBuf,
    /// What the app is called, for when it isn't running.
    pub app_name: String,
}

/// The longest path a Unix socket address takes, with room for its terminating zero.
const SOCKET_PATH_CAPACITY: usize = if cfg!(target_os = "macos") { 104 } else { 108 };

impl ControlClient {
    pub fn new(socket: impl Into<PathBuf>, app_name: impl Into<String>) -> Self {
        ControlClient { socket: socket.into(), app_name: app_name.into() }
    }

    /// Sends `request` and waits for the app's answer, however long the operation takes.
    pub fn send(&self, request: &ControlRequest) -> Result<ControlResponse, ClientError> {
        let connection = self.connect()?;
        exchange(request, raw(&connection))
    }

    /// Sends a request that turns the connection into a byte stream, such as `console`.
    ///
    /// If the app agrees, the connection is returned with its answer and carries the stream. If it
    /// refuses, there is no connection and the answer says why.
    pub fn open_stream(&self, request: &ControlRequest) -> Result<(ControlResponse, Option<OwnedFd>), ClientError> {
        let connection = self.connect()?;
        let response = exchange(request, raw(&connection))?;
        Ok(if response.ok { (response, Some(connection)) } else { (response, None) })
    }

    fn connect(&self) -> Result<OwnedFd, ClientError> {
        let path = self.socket.to_string_lossy().into_owned();
        if path.len() >= SOCKET_PATH_CAPACITY {
            return Err(ClientError::PathTooLong(path));
        }
        match UnixStream::connect(&self.socket) {
            Ok(stream) => Ok(stream.into()),
            Err(error) => match error.raw_os_error() {
                Some(libc::ENOENT | libc::ECONNREFUSED) => Err(ClientError::AppNotRunning(self.app_name.clone())),
                Some(code) => Err(ClientError::System("connect", code)),
                None => Err(ClientError::System("connect", libc::EINVAL)),
            },
        }
    }
}

fn raw(descriptor: &OwnedFd) -> RawFd {
    use std::os::fd::AsRawFd;
    descriptor.as_raw_fd()
}

fn exchange(request: &ControlRequest, descriptor: RawFd) -> Result<ControlResponse, ClientError> {
    let data = serde_json::to_vec(request).map_err(|_| ClientError::InvalidMessage)?;
    io::write_line(descriptor, &data).map_err(|code| ClientError::System("write", code))?;
    let line = io::read_line(descriptor).ok_or(ClientError::ConnectionClosed)?;
    serde_json::from_slice(&line).map_err(|_| ClientError::InvalidMessage)
}
