//! The processes that run a machine, QEMU and its TPM: starting them, and finding those left behind.
//!
//! A process gets the descriptors it is handed as 3, 4, 5 and so on, and nothing else of the service's.
//! It runs in a session of its own, and writes what it says straight to its log file: neither its
//! signals nor its output go through the service, so it outlives a service that stops.
//!
//! Each writes down its process ID in its machine's bundle, so that the next start of that machine finds
//! one that was left behind and ends it first.

use std::collections::BTreeMap;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::process::{Child, Command};

/// The first descriptor number the handed-over lines get.
pub const FIRST_DESCRIPTOR: RawFd = 3;

/// How much of what a process wrote last is read back, to say why it stopped.
const KEPT_OUTPUT: u64 = 8 * 1024;

pub struct Launch<'a> {
    pub program: &'a Path,
    pub arguments: &'a [String],
    /// Handed over as 3, 4, 5 and so on.
    pub descriptors: Vec<OwnedFd>,
    pub log: &'a Path,
    pub pid_file: &'a Path,
    pub directory: &'a Path,
    pub environment: BTreeMap<String, String>,
}

/// Starts a process. Its standard output and error go to `log`, written anew, and its ID to `pid_file`.
pub fn launch(launch: Launch<'_>) -> io::Result<Child> {
    if launch.descriptors.len() > 64 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Too many descriptors to hand over."));
    }
    if let Some(folder) = launch.log.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let log = std::fs::File::create(launch.log)?;
    let mut command = Command::new(launch.program);
    command
        .args(launch.arguments)
        .current_dir(launch.directory)
        .envs(&launch.environment)
        .stdin(std::process::Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .kill_on_drop(false);
    let sources: Vec<RawFd> = launch.descriptors.iter().map(AsRawFd::as_raw_fd).collect();
    // SAFETY: only setsid, fcntl, dup2 and syscall run between fork and exec, which are safe there, on
    // numbers computed before the fork.
    unsafe {
        command.pre_exec(move || hand_over(&sources));
    }
    let child = command.spawn()?;
    drop(launch.descriptors);
    if let Some(pid) = child.id() {
        let _ = std::fs::write(launch.pid_file, format!("{pid}\n"));
    }
    Ok(child)
}

/// In the new process: a session of its own, `sources` at 3, 4, 5 and so on, and every other descriptor
/// above them closed on exec.
fn hand_over(sources: &[RawFd]) -> io::Result<()> {
    // SAFETY: see `launch`.
    unsafe {
        libc::setsid();
        let first_free = FIRST_DESCRIPTOR + sources.len() as RawFd;
        // A source whose number is among those being handed out would be overwritten before its turn, so
        // each goes out of the way first. The copies are closed on exec.
        let mut moved = [0 as RawFd; 64];
        for (index, source) in sources.iter().enumerate().take(moved.len()) {
            moved[index] = libc::fcntl(*source, libc::F_DUPFD_CLOEXEC, first_free + 64);
            if moved[index] < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        for (index, copy) in moved.iter().take(sources.len()).enumerate() {
            // dup2 leaves the new number open across exec.
            if libc::dup2(*copy, FIRST_DESCRIPTOR + index as RawFd) < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        close_above(first_free);
    }
    Ok(())
}

/// Marks every descriptor from `first` on to be closed on exec.
unsafe fn close_above(first: RawFd) {
    #[cfg(target_os = "linux")]
    // SAFETY: close_range with CLOSE_RANGE_CLOEXEC only sets flags.
    unsafe {
        if libc::syscall(libc::SYS_close_range, first as libc::c_uint, libc::c_uint::MAX, libc::CLOSE_RANGE_CLOEXEC) == 0 {
            return;
        }
    }
    // SAFETY: getdtablesize and fcntl are safe between fork and exec.
    unsafe {
        for descriptor in first..libc::getdtablesize() {
            let flags = libc::fcntl(descriptor, libc::F_GETFD);
            if flags >= 0 {
                libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }
}

/// Whether the process `pid` is there, a zombie included.
pub fn is_alive(pid: i32) -> bool {
    // SAFETY: kill with signal 0 only checks.
    pid > 1 && (unsafe { libc::kill(pid, 0) } == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM))
}

pub fn kill(pid: i32, signal: libc::c_int) {
    if pid > 1 {
        // SAFETY: kill has no memory effects.
        unsafe {
            libc::kill(pid, signal);
        }
    }
}

/// Whether the process `pid` has ended: it is gone, or waits only to be collected.
pub fn has_ended(pid: i32) -> bool {
    !is_alive(pid) || is_zombie(pid)
}

/// Waits until `pid` is gone, for `timeout` at most. Returns whether it is. For a process that isn't this
/// one's child: a child is collected by whoever waits for it.
pub async fn wait_gone(pid: i32, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    while !has_ended(pid) {
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    true
}

/// Whether `pid` has ended and waits only to be collected by its parent.
fn is_zombie(pid: i32) -> bool {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .ok()
            .and_then(|stat| stat.rsplit_once(") ").map(|(_, rest)| rest.starts_with('Z')))
            .unwrap_or(false)
    }
    #[cfg(target_os = "macos")]
    {
        // proc_pidinfo tells nothing of a zombie, which still answers kill. Our own processes are
        // otherwise always readable.
        // SAFETY: proc_pidinfo writes at most the size it is given into the struct.
        unsafe {
            let mut info: libc::proc_bsdinfo = std::mem::zeroed();
            let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
            let read = libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size);
            if read == size { info.pbi_status == libc::SZOMB } else { libc::kill(pid, 0) == 0 }
        }
    }
}

/// What the process `pid` was started with: its arguments, the program first, as the system keeps them.
pub fn arguments_of(pid: i32) -> Option<Vec<String>> {
    #[cfg(target_os = "linux")]
    {
        let data = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        let mut parts: Vec<String> = data.split(|byte| *byte == 0).map(|part| String::from_utf8_lossy(part).into_owned()).collect();
        if parts.last().is_some_and(String::is_empty) {
            parts.pop();
        }
        (!parts.is_empty()).then_some(parts)
    }
    #[cfg(target_os = "macos")]
    {
        // KERN_PROCARGS2: the number of arguments, the program's path, padding, then the arguments, each
        // ending in a zero byte.
        let mut name = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
        let mut size: libc::size_t = 0;
        // SAFETY: sysctl with a null buffer only reports the size.
        if unsafe { libc::sysctl(name.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0) } != 0 || size <= 4 {
            return None;
        }
        let mut buffer = vec![0u8; size];
        // SAFETY: the buffer is `size` bytes long.
        if unsafe { libc::sysctl(name.as_mut_ptr(), 3, buffer.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0) } != 0 {
            return None;
        }
        buffer.truncate(size);
        let count = i32::from_ne_bytes(buffer[..4].try_into().ok()?) as usize;
        let mut index = 4;
        while index < buffer.len() && buffer[index] != 0 {
            index += 1;
        }
        while index < buffer.len() && buffer[index] == 0 {
            index += 1;
        }
        let mut strings = Vec::with_capacity(count);
        while index < buffer.len() && strings.len() < count {
            let start = index;
            while index < buffer.len() && buffer[index] != 0 {
                index += 1;
            }
            strings.push(String::from_utf8_lossy(&buffer[start..index]).into_owned());
            index += 1;
        }
        (strings.len() == count).then_some(strings)
    }
}

/// The folder the process `pid` runs in.
pub fn working_directory_of(pid: i32) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
    }
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        // SAFETY: proc_pidinfo writes at most the size it is given into the struct.
        unsafe {
            let mut info: libc::proc_vnodepathinfo = std::mem::zeroed();
            let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
            if libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, (&mut info as *mut libc::proc_vnodepathinfo).cast(), size) != size {
                return None;
            }
            let path = &info.pvi_cdir.vip_path;
            let bytes: &[u8] = std::slice::from_raw_parts(path.as_ptr().cast(), std::mem::size_of_val(path));
            let length = bytes.iter().position(|byte| *byte == 0).unwrap_or(bytes.len());
            Some(PathBuf::from(std::ffi::OsStr::from_bytes(&bytes[..length])))
        }
    }
}

/// The process ID a pid file names, if any.
pub fn read_pid_file(pid_file: &Path) -> Option<i32> {
    std::fs::read_to_string(pid_file).ok()?.trim().parse().ok().filter(|pid| *pid > 1)
}

/// Ends the process `pid_file` names, if `is_leftover` says from its ID and arguments that it is the one
/// left behind, and waits until it is gone. The pid file goes either way.
///
/// The process is told by what it was started with, not by its program: an app that was replaced since
/// leaves a QEMU behind whose program is gone, and an ID written down long ago may be another's by now.
pub async fn end_leftover(pid_file: &Path, is_leftover: impl Fn(i32, &[String]) -> bool) {
    if let Some(pid) = read_pid_file(pid_file)
        && let Some(arguments) = arguments_of(pid)
        && is_leftover(pid, &arguments)
    {
        kill(pid, libc::SIGKILL);
        wait_gone(pid, Duration::from_secs(5)).await;
    }
    let _ = std::fs::remove_file(pid_file);
}

/// Whether a process started with `arguments` is a QEMU that runs the machine `machine_id`.
pub fn is_qemu(arguments: &[String], machine_id: &uuid::Uuid) -> bool {
    let Some(program) = arguments.first() else { return false };
    if !Path::new(program).file_name().and_then(|name| name.to_str()).is_some_and(|name| name.starts_with("qemu-system-")) {
        return false;
    }
    arguments
        .iter()
        .position(|argument| argument == "-uuid")
        .and_then(|flag| arguments.get(flag + 1))
        .is_some_and(|uuid| uuid.eq_ignore_ascii_case(&machine_id.hyphenated().to_string()))
}

/// What a process wrote last to `log`.
pub fn last_output(log: &Path) -> String {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut file) = std::fs::File::open(log) else { return String::new() };
    let length = file.metadata().map(|metadata| metadata.len()).unwrap_or(0);
    let _ = file.seek(SeekFrom::Start(length.saturating_sub(KEPT_OUTPUT)));
    let mut bytes = Vec::new();
    let _ = file.read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).trim().to_string()
}

/// The last line QEMU wrote that says what went wrong, without QEMU's name in front.
pub fn complaint(output: &str) -> Option<String> {
    let lines: Vec<&str> = output.lines().collect();
    let line = lines.iter().rev().find(|line| !line.contains("warning:")).or(lines.last())?;
    let parts: Vec<&str> = line.split(": ").collect();
    let reason = if parts.first().is_some_and(|first| first.starts_with("qemu-system")) { parts[1..].join(": ") } else { line.to_string() };
    (!reason.is_empty()).then_some(reason)
}
