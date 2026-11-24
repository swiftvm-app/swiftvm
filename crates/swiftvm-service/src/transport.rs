//! Where clients reach the service, and who they are: a Unix socket, and the program at its other end.
//! On Windows this would be a named pipe.

use std::fs::{DirBuilder, File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use std::os::fd::OwnedFd;
use std::pin::Pin;
use std::task::{Context, Poll, ready};

use tokio::io::{AsyncRead, Interest, ReadBuf};
use tokio::net::unix::OwnedReadHalf;
use tokio::net::{UnixListener, UnixStream};

/// Makes `folder` and those above it that are missing, which only this user can open.
pub fn make_private_folder(folder: &Path) -> std::io::Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(folder)
}

/// Takes the lock at `path`, held for as long as the file stays open. `None` when another holds it.
pub fn lock(path: &Path) -> std::io::Result<Option<File>> {
    let file = OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(path)?;
    // SAFETY: flock on a descriptor this function owns.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(Some(file));
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::EWOULDBLOCK) { Ok(None) } else { Err(error) }
}

/// Which file a path is: changed when the file is replaced or written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileIdentity(Option<(u64, u64, u64, i64, i64)>);

impl FileIdentity {
    pub fn of(path: &Path) -> Self {
        FileIdentity(std::fs::metadata(path).ok().map(|data| (data.dev(), data.ino(), data.size(), data.mtime(), data.mtime_nsec())))
    }
}

pub struct Listener {
    listener: UnixListener,
    path: PathBuf,
    /// The socket file this listener made, so that one another service has put there since stays.
    file: FileIdentity,
}

impl Listener {
    /// Listens at `path`, in place of whatever is there: the caller holds the lock, so a socket there is
    /// left from a service that ended without taking it away.
    pub fn bind(path: &Path) -> std::io::Result<Self> {
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        Ok(Listener { listener, path: path.to_path_buf(), file: FileIdentity::of(path) })
    }

    pub async fn accept(&self) -> std::io::Result<UnixStream> {
        self.listener.accept().await.map(|(stream, _)| stream)
    }

    /// Stops listening, and takes the socket away if it is still this listener's.
    pub fn remove(self) {
        let Listener { listener, path, file } = self;
        drop(listener);
        let now = FileIdentity::of(&path);
        if now.0.map(|identity| (identity.0, identity.1)) == file.0.map(|identity| (identity.0, identity.1)) {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// Who is at the other end of a connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Peer {
    pub uid: Option<u32>,
    /// The program it runs, when that can be told.
    pub program: Option<PathBuf>,
}

impl Peer {
    pub fn of(stream: &UnixStream) -> Self {
        let Ok(credentials) = stream.peer_cred() else { return Peer { uid: None, program: None } };
        Peer { uid: Some(credentials.uid()), program: credentials.pid().and_then(program_of) }
    }

    /// Whether it runs as the same user as the service.
    pub fn is_this_user(&self) -> bool {
        // SAFETY: getuid can't fail.
        self.uid == Some(unsafe { libc::getuid() })
    }
}

/// The program the process `pid` runs.
#[cfg(target_os = "macos")]
fn program_of(pid: i32) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: the buffer is valid for writes of its length.
    let length = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    (length > 0).then(|| PathBuf::from(std::ffi::OsStr::from_bytes(&buffer[..length as usize])))
}

#[cfg(not(target_os = "macos"))]
fn program_of(pid: i32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/exe")).ok()
}

/// A connection's read half that keeps the descriptors that come with what it reads, for a request that
/// hands some over. They are closed on exec, and when nobody takes them.
pub struct DescriptorReader {
    half: OwnedReadHalf,
    pub descriptors: Vec<OwnedFd>,
}

impl DescriptorReader {
    pub fn new(half: OwnedReadHalf) -> Self {
        DescriptorReader { half, descriptors: Vec::new() }
    }

    pub fn into_inner(self) -> OwnedReadHalf {
        self.half
    }
}

impl AsyncRead for DescriptorReader {
    fn poll_read(self: Pin<&mut Self>, context: &mut Context<'_>, buffer: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let DescriptorReader { half, descriptors } = self.get_mut();
        let stream: &UnixStream = half.as_ref();
        loop {
            ready!(stream.poll_read_ready(context))?;
            let unfilled = buffer.initialize_unfilled();
            match stream.try_io(Interest::READABLE, || swiftvm_qemu::fdpass::receive(stream.as_raw_fd(), unfilled, descriptors)) {
                Ok(count) => {
                    buffer.advance(count);
                    return Poll::Ready(Ok(()));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(error) => return Poll::Ready(Err(error)),
            }
        }
    }
}
