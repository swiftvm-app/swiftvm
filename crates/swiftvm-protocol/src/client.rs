//! Talks to `swiftvm serve` over its socket, and starts it when it isn't running.

use std::fmt;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command as Process, Stdio};
use std::time::{Duration, Instant};

use crate::api;
use crate::io;
use crate::paths::ControlPaths;
use crate::wire::{ApiError, Command, ControlRequest, ControlResponse};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientError {
    PathTooLong(String),
    System(&'static str, i32),
    /// Nothing listens on the socket, and the service couldn't be started. Carries where it logs.
    ServiceNotRunning(PathBuf),
    /// The service said no to the handshake: this program isn't allowed, or speaks another version.
    Refused(ApiError),
    ConnectionClosed,
    InvalidMessage,
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ClientError::PathTooLong(path) => write!(f, "The socket path is too long: {path}"),
            ClientError::System(operation, code) => write!(f, "{operation} failed: {}", io::strerror(*code)),
            ClientError::ServiceNotRunning(log) => {
                write!(f, "The SwiftVM service didn't start. What it said is in {}", log.display())
            }
            ClientError::Refused(error) => f.write_str(&error.message),
            ClientError::ConnectionClosed => f.write_str("The service closed the connection before answering."),
            ClientError::InvalidMessage => f.write_str("Received a message that couldn't be understood."),
        }
    }
}

impl std::error::Error for ClientError {}

/// What the app says when it isn't running, and so the service can't pass a request on.
pub fn app_not_running_message(app_name: &str) -> String {
    format!("{app_name} isn't running. Open the app first.")
}

/// The longest path a Unix socket address takes, with room for its terminating zero.
pub const SOCKET_PATH_CAPACITY: usize = if cfg!(target_os = "macos") { 104 } else { 108 };

/// How long a service that was just started gets to listen.
const STARTUP_TIME: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceClient {
    pub paths: ControlPaths,
    /// What the client calls itself in `hello`, with its version: `swiftvm 0.1.0`.
    pub name: String,
    /// The program to start as `<program> serve` when nothing answers. `None` leaves it be.
    pub program: Option<PathBuf>,
}

impl ServiceClient {
    pub fn new(paths: ControlPaths, name: impl Into<String>, program: Option<PathBuf>) -> Self {
        ServiceClient { paths, name: name.into(), program }
    }

    /// Sends `request` and waits for the answer, however long the operation takes.
    pub fn send(&self, request: &ControlRequest) -> Result<ControlResponse, ClientError> {
        let connection = self.connect()?;
        exchange(request, connection.as_raw_fd())
    }

    /// Sends a request that turns the connection into a stream, such as `console` or `watch`.
    ///
    /// If the service agrees, the connection is returned with its answer and carries the stream. If it
    /// refuses, there is no connection and the answer says why.
    pub fn open_stream(&self, request: &ControlRequest) -> Result<(ControlResponse, Option<OwnedFd>), ClientError> {
        let connection = self.connect()?;
        let response = exchange(request, connection.as_raw_fd())?;
        Ok(if response.ok { (response, Some(connection)) } else { (response, None) })
    }

    /// A connection that has been through `hello`, to a service started for it if none was running.
    pub fn connect(&self) -> Result<OwnedFd, ClientError> {
        match self.connect_once() {
            // A service that was stopping as this connected: the next one is started, or about to be.
            Err(ClientError::ConnectionClosed) => self.connect_once(),
            result => result,
        }
    }

    fn connect_once(&self) -> Result<OwnedFd, ClientError> {
        let socket = self.paths.service_socket();
        let connection = match connect(&socket)? {
            Some(connection) => connection,
            None => self.start()?,
        };
        let hello = ControlRequest {
            id: Some(0),
            protocol: Some(api::PROTOCOL),
            client: Some(self.name.clone()),
            ..ControlRequest::new(Command::Hello)
        };
        let answer = exchange(&hello, connection.as_raw_fd())?;
        if !answer.ok {
            return Err(ClientError::Refused(
                answer
                    .error
                    .unwrap_or(ApiError { code: crate::wire::ErrorCode::Failed, message: "The service refused the connection.".into() }),
            ));
        }
        Ok(connection)
    }

    /// Starts the service, and waits until it listens.
    fn start(&self) -> Result<OwnedFd, ClientError> {
        let log = self.paths.service_log();
        let Some(program) = &self.program else { return Err(ClientError::ServiceNotRunning(log)) };
        let _ = std::fs::create_dir_all(&self.paths.data);
        let output = std::fs::OpenOptions::new().create(true).append(true).open(&log).ok();
        let mut command = Process::new(program);
        command.arg("serve").stdin(Stdio::null());
        match output.as_ref().and_then(|file| Some((file.try_clone().ok()?, file.try_clone().ok()?))) {
            Some((out, err)) => command.stdout(out).stderr(err),
            None => command.stdout(Stdio::null()).stderr(Stdio::null()),
        };
        // In a session of its own, so that a terminal's Control-C or hang-up doesn't end it with this tool.
        // And without the descriptors this tool was given: a pipe that the service kept open, such as the
        // one `exec --result-fd` writes to, would never reach its end for whoever reads it.
        // SAFETY: setsid, getdtablesize and fcntl are safe to call between fork and exec.
        unsafe {
            use std::os::unix::process::CommandExt;
            command.pre_exec(|| {
                libc::setsid();
                for descriptor in 3..libc::getdtablesize() {
                    let flags = libc::fcntl(descriptor, libc::F_GETFD);
                    if flags >= 0 {
                        libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC);
                    }
                }
                Ok(())
            });
        }
        let mut child = command.spawn().map_err(|_| ClientError::ServiceNotRunning(log.clone()))?;
        let deadline = Instant::now() + STARTUP_TIME;
        let socket = self.paths.service_socket();
        let result = loop {
            if let Some(connection) = connect(&socket)? {
                break Ok(connection);
            }
            // One that quits at once found another service holding the lock, which is about to listen.
            if Instant::now() >= deadline {
                break Err(ClientError::ServiceNotRunning(log));
            }
            std::thread::sleep(Duration::from_millis(25));
        };
        // Its end is collected wherever this goes on to, so that it doesn't linger as a zombie.
        std::thread::spawn(move || child.wait());
        result
    }
}

/// A connection to the socket at `path`, or `None` when nothing listens there.
pub fn connect(path: &Path) -> Result<Option<OwnedFd>, ClientError> {
    let text = path.to_string_lossy().into_owned();
    if text.len() >= SOCKET_PATH_CAPACITY {
        return Err(ClientError::PathTooLong(text));
    }
    match UnixStream::connect(path) {
        Ok(stream) => Ok(Some(stream.into())),
        Err(error) => match error.raw_os_error() {
            Some(libc::ENOENT | libc::ECONNREFUSED) => Ok(None),
            Some(code) => Err(ClientError::System("connect", code)),
            None => Err(ClientError::System("connect", libc::EINVAL)),
        },
    }
}

/// Sends `request`, with an `id` if it has none, and reads the answer.
fn exchange(request: &ControlRequest, descriptor: RawFd) -> Result<ControlResponse, ClientError> {
    let data = if request.id.is_some() {
        serde_json::to_vec(request)
    } else {
        serde_json::to_vec(&ControlRequest { id: Some(1), ..request.clone() })
    }
    .map_err(|_| ClientError::InvalidMessage)?;
    io::write_line(descriptor, &data).map_err(|code| ClientError::System("write", code))?;
    let line = io::read_line(descriptor).ok_or(ClientError::ConnectionClosed)?;
    serde_json::from_slice(&line).map_err(|_| ClientError::InvalidMessage)
}
