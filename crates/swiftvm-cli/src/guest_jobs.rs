//! `swiftvm exec` and `cp`: what the guest tools do in a guest when asked from here.
//!
//! The app opens the job and then only passes bytes on, so that this tool and the agent in the guest
//! speak to each other in job frames. Leaving, for whatever reason, calls the job off.

use std::collections::BTreeMap;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::process::{Child, Command as Process, ExitStatus, Stdio};
use std::sync::Arc;
use std::sync::mpsc;
use std::time::Duration;

use base64::Engine;
use swiftvm_protocol::io::{self, is_terminal};
use swiftvm_protocol::paths::standardized_path;
use swiftvm_protocol::text::CopyEndpoint;
use swiftvm_protocol::{Command, ControlRequest, Exec, GuestJob, Id, JobEnd, JobFrame, JobFrameKind};

use crate::exec_completion::{ExecCompletion, ExecCompletionWriter};
use crate::format;
use crate::util::{client, exit, fail, fail_with, ignore_broken_pipe_signal, send};

/// What `swiftvm exec` exits with when it isn't the command's own status, as `timeout` and `docker` have
/// it: the time was up, or the command never got to run.
pub const TIMED_OUT_STATUS: i32 = 124;
pub const FAILED_STATUS: i32 = 125;
/// A reader that went away, as the shell reports a program that a closed pipe ended.
const BROKEN_PIPE_STATUS: i32 = 141;
/// The most that a command run to read what it says may put out.
const LONGEST_COLLECTED_OUTPUT: usize = 256 << 20;
/// How long such a command gets.
const COLLECT_TIMEOUT: Duration = Duration::from_secs(120);

// MARK: Running a job

/// Has the guest tools of `machine` take on `job` and returns the connection that carries it. Stops with
/// the reason when the app or the guest tools say no.
fn open(job: GuestJob, machine: &str, failure_status: i32) -> OwnedFd {
    // A line that has gone shows as a write that fails, not as the end of this tool.
    ignore_broken_pipe_signal();
    let request = ControlRequest { job: Some(job), ..ControlRequest::for_machine(Command::Job, machine) };
    match client().open_stream(&request) {
        Ok((_, Some(connection))) => connection,
        Ok((response, None)) => fail_with(response.error.as_deref().unwrap_or("The guest tools didn't take that on."), failure_status),
        Err(error) => fail_with(&error.to_string(), failure_status),
    }
}

/// What a job is given as its input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Input {
    /// Nothing is said about input: the job isn't a command.
    None,
    /// The command is told at once that no input is coming.
    Empty,
    /// What can be read from this descriptor, to its end.
    From(RawFd),
}

/// Carries a job to its end and returns how it ended.
///
/// `output` and `error_output` take what the job puts out, and return `false` when nobody is listening
/// any more, which ends this tool through `output_failure`, or with the status of a broken pipe.
pub fn run(
    descriptor: RawFd,
    input: Input,
    output: &mut dyn FnMut(&[u8]) -> bool,
    error_output: &mut dyn FnMut(&[u8]) -> bool,
    output_failure: &dyn Fn(),
) -> JobEnd {
    if input != Input::None {
        // Nobody else writes to the connection, so the frames of the input can't get mixed up with others.
        std::thread::spawn(move || {
            if let Input::From(source) = input {
                let mut buffer = vec![0u8; JobFrame::MAXIMUM_PAYLOAD_LENGTH];
                loop {
                    let count = io::read(source, &mut buffer);
                    if count <= 0 {
                        break;
                    }
                    if !JobFrame::write(JobFrameKind::Input, &buffer[..count as usize], descriptor) {
                        return;
                    }
                }
            }
            // An empty frame is the end of the input.
            JobFrame::write(JobFrameKind::Input, &[], descriptor);
        });
    }
    loop {
        let Ok(Some(frame)) = JobFrame::read(descriptor, None) else {
            return JobEnd::failure("The connection to the guest was lost before it was done.");
        };
        match frame.kind {
            JobFrameKind::Output => {
                if !output(&frame.payload) {
                    output_failure();
                    exit(BROKEN_PIPE_STATUS)
                }
            }
            JobFrameKind::ErrorOutput => {
                if !error_output(&frame.payload) {
                    output_failure();
                    exit(BROKEN_PIPE_STATUS)
                }
            }
            JobFrameKind::End => return frame.end().unwrap_or_else(JobEnd::success),
            JobFrameKind::Input => {}
        }
    }
}

fn write_to(descriptor: RawFd) -> impl FnMut(&[u8]) -> bool {
    move |data| io::write_all(descriptor, data)
}

/// Runs a job that has nothing to take in, and returns what it put out. Stops with the reason when it
/// didn't work out.
fn collect(job: GuestJob, machine: &str) -> Vec<u8> {
    let connection = open(job, machine, 1);
    // These take a moment, not minutes. A guest that took the job on and then says nothing would keep
    // whoever asked waiting for good, and a script has nobody to press Control-C.
    let (done, watchdog) = mpsc::channel::<()>();
    std::thread::spawn(move || {
        if let Err(mpsc::RecvTimeoutError::Timeout) = watchdog.recv_timeout(COLLECT_TIMEOUT) {
            fail(&format!("The guest tools took this on and didn't finish in {} seconds.", COLLECT_TIMEOUT.as_secs()));
        }
    });
    let mut collected = Vec::new();
    let end = run(
        connection.as_raw_fd(),
        Input::None,
        &mut |data| {
            // A guest that sends without end isn't answering.
            if collected.len() + data.len() > LONGEST_COLLECTED_OUTPUT {
                fail(&format!("The guest sent more than {} MB, which is no answer to this.", LONGEST_COLLECTED_OUTPUT >> 20));
            }
            collected.extend_from_slice(data);
            true
        },
        &mut write_to(libc::STDERR_FILENO),
        &|| (),
    );
    // What comes after, a copy for one, may take as long as it takes.
    drop(done);
    if let Some(error) = end.shown_error() {
        fail(&error);
    }
    if end.status != Some(0) {
        fail("The guest tools gave up, without saying why.");
    }
    collected
}

// MARK: exec

pub const EXEC_USAGE: &str = "Usage: swiftvm exec <machine> [--root | --user <name>] [--cwd <folder>] [--env <name>=<value>] [--timeout <seconds>] [--result-fd <descriptor>] [--] <command> [arguments]";

/// The account a command runs as, the way `--root` and `--user` name it.
#[derive(Default)]
struct Account {
    /// `None` leaves it to the app: the machine's own account.
    name: Option<String>,
}

impl Account {
    fn take(&mut self, option: &str, value: Option<String>, failure_status: i32) {
        if self.name.is_some() {
            fail_with("Give --root or --user, once.", failure_status);
        }
        self.name = if option == "--root" { Some("root".into()) } else { value };
    }
}

fn exec_job(
    arguments: Vec<String>,
    user: Option<String>,
    directory: Option<String>,
    environment: Option<BTreeMap<String, String>>,
) -> GuestJob {
    GuestJob::Exec(Exec { arguments, user, directory, environment })
}

/// `swiftvm exec`: runs a command in the guest, and ends the way the command did.
pub fn exec(arguments: &[String]) -> ! {
    let Some(machine) = arguments.first().filter(|machine| !machine.starts_with('-')) else { fail_with(EXEC_USAGE, FAILED_STATUS) };
    let machine = machine.clone();
    let mut account = Account::default();
    let mut directory = None;
    let mut environment = BTreeMap::new();
    let mut timeout: Option<f64> = None;
    let mut result_descriptor: Option<RawFd> = None;
    let mut index = 1;
    let value = |index: &mut usize, option: &str| -> String {
        *index += 1;
        arguments.get(*index).cloned().unwrap_or_else(|| fail_with(&format!("{option} needs a value."), FAILED_STATUS))
    };
    // Options end at the first word that isn't one, or at a double dash: what follows is the command's,
    // dashes and all.
    while index < arguments.len() {
        let option = arguments[index].as_str();
        match option {
            "--" => {
                index += 1;
                break;
            }
            "--root" => account.take(option, None, FAILED_STATUS),
            "--user" => {
                let name = value(&mut index, option);
                account.take(option, Some(name), FAILED_STATUS);
            }
            "--cwd" => directory = Some(value(&mut index, option)),
            "--env" => {
                let pair = value(&mut index, option);
                match pair.split_once('=') {
                    Some((name, value)) if !name.is_empty() => {
                        environment.insert(name.to_string(), value.to_string());
                    }
                    _ => fail_with("--env needs <name>=<value>.", FAILED_STATUS),
                }
            }
            "--timeout" => match value(&mut index, option).parse::<f64>() {
                Ok(seconds) if seconds > 0.0 && seconds.is_finite() => timeout = Some(seconds),
                _ => fail_with("--timeout needs a number of seconds.", FAILED_STATUS),
            },
            "--result-fd" => match value(&mut index, option).parse::<RawFd>() {
                Ok(descriptor) if result_descriptor.is_none() && descriptor > libc::STDERR_FILENO => result_descriptor = Some(descriptor),
                _ => fail_with("Give --result-fd once, with a descriptor greater than 2.", FAILED_STATUS),
            },
            _ if option.starts_with('-') => fail_with(&format!("Unknown option {option}.\n{EXEC_USAGE}"), FAILED_STATUS),
            _ => break,
        }
        index += 1;
    }
    let command = arguments[index.min(arguments.len())..].to_vec();
    if command.is_empty() {
        fail_with(EXEC_USAGE, FAILED_STATUS);
    }

    let job = exec_job(command, account.name, directory, (!environment.is_empty()).then_some(environment));
    let completion = match ExecCompletionWriter::new(result_descriptor) {
        Ok(writer) => Arc::new(writer),
        Err(error) => fail_with(&error.to_string(), FAILED_STATUS),
    };
    ignore_broken_pipe_signal();
    let request = ControlRequest { job: Some(job), ..ControlRequest::for_machine(Command::Job, machine.as_str()) };
    let (connection, machine_id): (OwnedFd, Option<Id>) = match client().open_stream(&request) {
        Ok((response, Some(connection))) => (connection, response.machines.first().map(|machine| machine.id)),
        Ok((response, None)) => completion.finish(
            &ExecCompletion::new(&machine, None, None),
            FAILED_STATUS,
            Some(response.error.as_deref().unwrap_or("The guest tools didn't take that on.")),
        ),
        Err(error) => completion.finish(&ExecCompletion::new(&machine, None, None), FAILED_STATUS, Some(&error.to_string())),
    };
    if let Some(timeout) = timeout {
        // Leaving is what calls the command off in the guest.
        let completion = Arc::clone(&completion);
        let machine = machine.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs_f64(timeout));
            completion.finish(
                &ExecCompletion::new(&machine, machine_id, None),
                TIMED_OUT_STATUS,
                Some(&format!("The command didn't finish in {} seconds; guest completion is unknown.", format::number(timeout))),
            );
        });
    }
    // What is typed at a terminal isn't the command's to read: it has no terminal of its own.
    let input = if is_terminal(libc::STDIN_FILENO) { Input::Empty } else { Input::From(libc::STDIN_FILENO) };
    let end = run(connection.as_raw_fd(), input, &mut write_to(libc::STDOUT_FILENO), &mut write_to(libc::STDERR_FILENO), &|| {
        completion.finish(&ExecCompletion::new(&machine, machine_id, None), BROKEN_PIPE_STATUS, None)
    });
    let status = end.status.or(end.signal.filter(|signal| (1..=127).contains(signal)).map(|signal| 128 + signal)).unwrap_or(FAILED_STATUS);
    completion.finish(&ExecCompletion::new(&machine, machine_id, Some(&end)), status, end.shown_error().as_deref())
}

// MARK: cp

pub const COPY_USAGE: &str = "Usage: swiftvm cp [--root | --user <name>] <from> <to>, where one of the two is <machine>:<path>";

/// Puts what arrives on its input where `cp -R` would: into `$1` if that is a folder, under the name `$1`
/// otherwise. `$2` is the name it arrives under, a dot for the contents of a folder.
const UNPACK_SCRIPT: &str = r#"set -e
dest=$1
name=$2
if [ "$name" = . ]; then
    mkdir -p -- "$dest"
    exec tar --no-same-owner -xf - -C "$dest"
fi
if [ -d "$dest" ]; then
    exec tar --no-same-owner -xf - -C "$dest"
fi
parent=$(dirname -- "$dest")
[ -d "$parent" ] || { echo "$parent: no such folder" >&2; exit 1; }
work=$(mktemp -d "$parent/.swiftvm-cp.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
tar --no-same-owner -xf - -C "$work"
mv -f -- "$work/$name" "$dest""#;

const PACK_SCRIPT: &str = r#"cd -- "$(dirname -- "$1")" && exec tar -cf - -- "$(basename -- "$1")""#;

/// What the commands that pack and unpack in the guest run with: macOS keeps its tar from adding files
/// of its own with this, and Linux doesn't mind.
const ARCHIVE_ENVIRONMENT: [(&str, &str); 1] = [("COPYFILE_DISABLE", "1")];

fn archive_environment() -> BTreeMap<String, String> {
    ARCHIVE_ENVIRONMENT.iter().map(|(name, value)| (name.to_string(), value.to_string())).collect()
}

/// This computer's tar, and the options that keep what only this computer knows out of an archive.
fn local_tar() -> (&'static str, &'static [&'static str]) {
    if cfg!(target_os = "macos") { ("/usr/bin/tar", &["--no-xattrs", "--no-mac-metadata"]) } else { ("tar", &["--no-xattrs"]) }
}

/// `swiftvm cp`: copies a file or a folder into a guest or out of one, as a tar archive that a command in
/// the guest unpacks or packs.
pub fn copy(arguments: &[String]) -> ! {
    let mut account = Account::default();
    let mut places = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "--root" => account.take(argument, None, 1),
            "--user" => {
                index += 1;
                let Some(name) = arguments.get(index) else { fail("--user needs a value.") };
                account.take(argument, Some(name.clone()), 1);
            }
            _ if argument.starts_with("--") => fail(&format!("Unknown option {argument}.\n{COPY_USAGE}")),
            _ => places.push(argument.to_string()),
        }
        index += 1;
    }
    if places.len() != 2 {
        fail(COPY_USAGE);
    }
    let user = account.name;
    match (CopyEndpoint::parse(&places[0]), CopyEndpoint::parse(&places[1])) {
        (CopyEndpoint::Local(source), CopyEndpoint::Guest { machine, path }) => {
            if is_windows(&machine) {
                copy_into_windows(&source, &path, &machine, user);
            }
            copy_in(&source, &path, &machine, user)
        }
        (CopyEndpoint::Guest { machine, path }, CopyEndpoint::Local(destination)) => {
            if is_windows(&machine) {
                copy_out_of_windows(&path, &machine, &destination, user);
            }
            copy_out(&path, &machine, &destination, user, None)
        }
        (CopyEndpoint::Local(_), CopyEndpoint::Local(_)) => fail(&format!("Neither is in a virtual machine. {COPY_USAGE}")),
        (CopyEndpoint::Guest { .. }, CopyEndpoint::Guest { .. }) => {
            fail("Copying from one virtual machine to another isn't done in one step: copy to this Mac first.")
        }
    }
}

// MARK: cp in Windows

/// Whether `machine` runs Windows, which has `tar` but no shell to say where it unpacks.
fn is_windows(machine: &str) -> bool {
    send(ControlRequest::for_machine(Command::Info, machine)).machines.first().and_then(|machine| machine.family.as_deref())
        == Some("windows")
}

/// What a path in a Windows guest is, as PowerShell there says.
struct WindowsPlace {
    is_folder: bool,
    /// The whole path, with `~` and a relative path resolved.
    full: String,
    /// Empty for the root of a drive.
    parent: String,
    leaf: String,
}

fn windows_place(path: &str, creating_folder: bool, machine: &str, user: Option<String>) -> WindowsPlace {
    // The path comes in the environment: in the script PowerShell would read quotes of several kinds in
    // it. Without a console to draw it on, PowerShell writes the progress of loading its modules to
    // errors, as XML, and what it prints in the code page of DOS.
    let script = format!(
        "$ProgressPreference = 'SilentlyContinue'\n\
         [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false\n\
         $p = $env:SWIFTVM_PLACE\n\
         if (${}) {{ New-Item -ItemType Directory -Force -Path $p | Out-Null }}\n\
         $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)\n\
         if (Test-Path -LiteralPath $full -PathType Container) {{ 'folder' }} elseif (Test-Path -LiteralPath $full) {{ 'file' }} else {{ 'none' }}\n\
         $full\n\
         Split-Path -Parent $full\n\
         Split-Path -Leaf $full",
        if creating_folder { "true" } else { "false" }
    );
    // As UTF-16 in Base64: nothing in it is read by a shell on its way.
    let encoded: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let job = exec_job(
        vec![
            "powershell.exe".into(),
            "-NoProfile".into(),
            "-NonInteractive".into(),
            "-EncodedCommand".into(),
            base64::engine::general_purpose::STANDARD.encode(encoded),
        ],
        user,
        None,
        Some(BTreeMap::from([("SWIFTVM_PLACE".to_string(), path.to_string())])),
    );
    // Every line counts, also the empty one that is the parent of a drive's root.
    let said = String::from_utf8_lossy(&collect(job, machine)).replace('\r', "");
    let lines: Vec<&str> = said.split('\n').map(str::trim).collect();
    if lines.len() < 4 || lines[1].is_empty() {
        fail(&format!("“{path}” isn't a place in “{machine}”."));
    }
    WindowsPlace { is_folder: lines[0] == "folder", full: lines[1].into(), parent: lines[2].into(), leaf: lines[3].into() }
}

/// `text` as a pattern for tar's `-s` (or GNU tar's `--transform`), which read basic regular
/// expressions: only what is special in those is escaped.
pub fn tar_pattern(text: &str) -> String {
    let mut pattern = String::new();
    for character in text.chars() {
        if "\\.[]*^$".contains(character) {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    pattern
}

/// `text` as what replaces a match: `~` stands for the match in BSD tar, `&` in GNU tar.
pub fn tar_replacement(text: &str) -> String {
    let special = if cfg!(target_os = "macos") { "\\~" } else { "\\&" };
    let mut replacement = String::new();
    for character in text.chars() {
        if special.contains(character) {
            replacement.push('\\');
        }
        replacement.push(character);
    }
    replacement
}

/// The option that renames `name` to `leaf` as it goes into the archive. `/` is in no name, on this
/// computer or in Windows.
fn rename_option(name: &str, leaf: &str) -> Vec<String> {
    let expression = format!("/^{}/{}/", tar_pattern(name), tar_replacement(leaf));
    if cfg!(target_os = "macos") { vec!["-s".into(), expression] } else { vec![format!("--transform=s{expression}")] }
}

/// A path's parent and last part, as Foundation's `URL` has them.
fn parent_and_name(path: &str) -> (String, String) {
    let path = Path::new(path);
    let parent = path.parent().map(|parent| parent.to_string_lossy().into_owned()).unwrap_or_else(|| "/".into());
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| "/".into());
    (parent, name)
}

fn exists_without_following(path: &str) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

/// Starts this computer's tar to pack `name` in `parent`, with what it writes in a pipe.
fn start_packing(parent: &str, name: &str, extra: Vec<String>) -> Child {
    let (tar, options) = local_tar();
    let mut arguments: Vec<String> = options.iter().map(|option| option.to_string()).collect();
    arguments.extend(["-cf".into(), "-".into(), "-C".into(), parent.into()]);
    arguments.extend(extra);
    arguments.extend(["--".into(), name.into()]);
    Process::new(tar)
        .args(arguments)
        .envs(ARCHIVE_ENVIRONMENT)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap_or_else(|error| fail(&format!("tar couldn't be run: {error}")))
}

/// Sends what `tar` packs to the job on `connection`, and waits for both to finish.
fn send_archive(connection: &OwnedFd, mut tar: Child) -> ! {
    let packed = tar.stdout.take().expect("tar writes to a pipe");
    let end = run(connection.as_raw_fd(), Input::From(packed.as_raw_fd()), &mut |_| true, &mut write_to(libc::STDERR_FILENO), &|| ());
    if end.error.is_some() || end.status != Some(0) {
        // The guest's side gave up before the archive was through, and nobody takes the rest of it. tar
        // would wait for someone to, for good.
        // SAFETY: tar is this process's child and hasn't been waited for.
        unsafe { libc::kill(tar.id() as libc::pid_t, libc::SIGTERM) };
    } else {
        // The guest has all it needs. What tar still has to say after that is read to its end.
        let mut rest = vec![0u8; 64 * 1024];
        while io::read(packed.as_raw_fd(), &mut rest) > 0 {}
    }
    let status = tar.wait().unwrap_or_else(|error| fail(&format!("tar couldn't be run: {error}")));
    finish_copy(&end, status)
}

fn copy_into_windows(source: &str, destination: &str, machine: &str, user: Option<String>) -> ! {
    if destination.is_empty() {
        fail(&format!("Missing where to put it in “{machine}”."));
    }
    let is_contents = source == "." || source.ends_with("/.");
    let path = standardized_path(source);
    if !exists_without_following(&path) {
        fail(&format!("“{source}” isn't there."));
    }
    let (parent, name) = if is_contents { (path.clone(), ".".to_string()) } else { parent_and_name(&path) };
    let place = windows_place(destination, is_contents, machine, user.clone());

    // Into a folder that is there it goes under its own name; anywhere else under the name given.
    let (folder, rename) = if place.is_folder {
        (place.full, Vec::new())
    } else {
        if place.parent.is_empty() {
            fail(&format!("“{destination}” isn't a place for a file in “{machine}”."));
        }
        (place.parent, rename_option(&name, &place.leaf))
    };
    let job = exec_job(vec!["tar.exe".into(), "-xf".into(), "-".into(), "-C".into(), folder], user, None, None);
    let connection = open(job, machine, 1);
    let tar = start_packing(&parent, &name, rename);
    send_archive(&connection, tar)
}

fn copy_out_of_windows(source: &str, machine: &str, destination: &str, user: Option<String>) -> ! {
    if source.is_empty() {
        fail(&format!("Missing what to copy from “{machine}”."));
    }
    let is_contents = source == "." || source.ends_with("/.") || source.ends_with("\\.");
    let folder_path = if source == "." { ".".to_string() } else { source.chars().take(source.chars().count().saturating_sub(2)).collect() };
    let place = windows_place(if is_contents { &folder_path } else { source }, false, machine, user.clone());
    if is_contents && !place.is_folder {
        fail(&format!("“{source}” isn't a folder in “{machine}”."));
    }
    // The whole of a drive is its contents.
    if !is_contents && place.parent.is_empty() {
        fail(&format!("To copy all of “{source}”, copy “{source}.”: what is in it."));
    }
    // `tar` itself, with no shell around it, so that the archive reaches this computer as it is.
    let folder = if is_contents { place.full } else { place.parent };
    let name = if is_contents { ".".to_string() } else { place.leaf };
    let packing = vec!["tar.exe".into(), "-cf".into(), "-".into(), "-C".into(), folder, "--".into(), name.clone()];
    copy_out(&name, machine, destination, user, Some(packing))
}

// MARK: cp in macOS and Linux

fn copy_in(source: &str, destination: &str, machine: &str, user: Option<String>) -> ! {
    if destination.is_empty() {
        fail(&format!("Missing where to put it in “{machine}”."));
    }
    // `folder/.` is the folder's contents, as it is to cp.
    let is_contents = source == "." || source.ends_with("/.");
    let path = standardized_path(source);
    // The link itself is copied, even when its target isn't on this computer.
    if !exists_without_following(&path) {
        fail(&format!("“{source}” isn't there."));
    }
    let (parent, name) = if is_contents { (path.clone(), ".".to_string()) } else { parent_and_name(&path) };
    let job = exec_job(
        vec!["/bin/sh".into(), "-c".into(), UNPACK_SCRIPT.into(), "swiftvm-cp".into(), destination.into(), name.clone()],
        user,
        None,
        Some(archive_environment()),
    );
    let connection = open(job, machine, 1);
    let tar = start_packing(&parent, &name, Vec::new());
    send_archive(&connection, tar)
}

/// - `packing`: the command that packs `source` in the guest, where that isn't the shell's.
fn copy_out(source: &str, machine: &str, destination: &str, user: Option<String>, packing: Option<Vec<String>>) -> ! {
    if source.is_empty() {
        fail(&format!("Missing what to copy from “{machine}”."));
    }
    let is_contents = source == "." || source.ends_with("/.");
    // The last part of a path in the guest, read as text: this computer's folders have no say in it.
    let name = if is_contents { ".".to_string() } else { source.split('/').rfind(|part| !part.is_empty()).unwrap_or("").to_string() };
    if name.is_empty() || name == ".." || (!is_contents && name == ".") {
        fail(&format!(
            "“{source}” doesn't name a file or a folder in “{machine}”. To copy what is in a folder, end its path with a slash and a dot, as in {machine}:/srv/."
        ));
    }
    let target = PathBuf::from(standardized_path(destination));
    let is_folder = std::fs::metadata(&target).is_ok_and(|metadata| metadata.is_dir());
    // The archive is the guest's word. It is unpacked in a folder of its own, next to where the copy goes,
    // and only what was asked for is taken out of it.
    let home = if is_contents || is_folder {
        target.clone()
    } else {
        target.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("/"))
    };
    if is_contents && let Err(error) = std::fs::create_dir_all(&target) {
        fail(&error.to_string());
    }
    let work = home.join(format!(".swiftvm-cp.{}", Id(uuid::Uuid::new_v4())));
    if let Err(error) = std::fs::create_dir(&work) {
        fail(&error.to_string());
    }
    let leave = |message: &str| -> ! {
        let _ = std::fs::remove_dir_all(&work);
        fail(message)
    };

    let (tar, _) = local_tar();
    let job = exec_job(
        packing.unwrap_or_else(|| vec!["/bin/sh".into(), "-c".into(), PACK_SCRIPT.into(), "swiftvm-cp".into(), source.into()]),
        user,
        None,
        Some(archive_environment()),
    );
    let connection = open(job, machine, 1);
    let mut unpacking = Process::new(tar)
        .args(["-xf", "-", "-C"])
        .arg(&work)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap_or_else(|error| leave(&format!("tar couldn't be run: {error}")));
    let archive = unpacking.stdin.take().expect("tar reads from a pipe");
    // A tar that gave up shows in how it exits. The guest's side is heard out either way.
    let end = run(
        connection.as_raw_fd(),
        Input::Empty,
        &mut |data| {
            io::write_all(archive.as_raw_fd(), data);
            true
        },
        &mut write_to(libc::STDERR_FILENO),
        &|| (),
    );
    drop(archive);
    let status = unpacking.wait().unwrap_or_else(|error| leave(&format!("tar couldn't be run: {error}")));
    if end.error.is_some() || end.status != Some(0) || !status.success() {
        let _ = std::fs::remove_dir_all(&work);
        finish_copy(&end, status);
    }

    // cp puts it where cp would: into a folder that is there, under the name given otherwise.
    let unpacked = if is_contents { format!("{}/.", work.display()) } else { work.join(&name).to_string_lossy().into_owned() };
    if !is_contents && !exists_without_following(&unpacked) {
        leave("The guest sent something else than what was asked for.");
    }
    // A copy that shares its blocks with what was unpacked where the disk can.
    let clone_option = if cfg!(target_os = "macos") { "-Rc" } else { "-R" };
    let mut cp = Process::new(if cfg!(target_os = "macos") { "/bin/cp" } else { "cp" });
    cp.arg(clone_option);
    if !cfg!(target_os = "macos") {
        cp.arg("--reflink=auto");
    }
    let status = cp.arg(&unpacked).arg(&target).status().unwrap_or_else(|error| leave(&format!("cp couldn't be run: {error}")));
    let _ = std::fs::remove_dir_all(&work);
    exit(exit_code(status))
}

/// What a process that ended says, as Foundation's `terminationStatus` has it: its exit status, or the
/// signal that ended it.
fn exit_code(status: ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    status.code().or(status.signal()).unwrap_or(1)
}

/// Ends `swiftvm cp` the way its two halves ended.
fn finish_copy(end: &JobEnd, archiver: ExitStatus) -> ! {
    if let Some(error) = end.shown_error() {
        fail(&error);
    }
    if end.status != Some(0) {
        exit(end.status.unwrap_or(1));
    }
    exit(exit_code(archiver))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    #[test]
    fn a_jobs_streams_keep_their_bytes_and_a_malformed_end_is_an_error() {
        let (receiver, sender) = UnixStream::pair().unwrap();
        let binary: Vec<u8> = (0..=255).collect();
        let reversed: Vec<u8> = binary.iter().rev().copied().collect();
        let (sent, sent_reversed) = (binary.clone(), reversed.clone());
        std::thread::spawn(move || {
            JobFrame::write(JobFrameKind::Output, &sent, sender.as_raw_fd());
            JobFrame::write(JobFrameKind::ErrorOutput, &sent_reversed, sender.as_raw_fd());
            JobFrame::write(JobFrameKind::End, b"not JSON", sender.as_raw_fd());
        });
        let (mut output, mut errors) = (Vec::new(), Vec::new());
        let never = || panic!("nobody stopped listening");
        let end = run(
            receiver.as_raw_fd(),
            Input::None,
            &mut |data| {
                output.extend_from_slice(data);
                true
            },
            &mut |data| {
                errors.extend_from_slice(data);
                true
            },
            &never,
        );
        assert_eq!((output, errors), (binary, reversed));
        assert!(end.error.is_some());
        let lost = run(receiver.as_raw_fd(), Input::None, &mut |_| true, &mut |_| true, &never);
        assert!(lost.error.is_some());
    }

    #[test]
    fn a_name_is_renamed_in_the_archive_exactly() {
        assert_eq!(tar_pattern("a.b[1]*^$\\"), "a\\.b\\[1\\]\\*\\^\\$\\\\");
        if cfg!(target_os = "macos") {
            assert_eq!(tar_replacement("x~y\\"), "x\\~y\\\\");
            assert_eq!(rename_option("a.txt", "b"), vec!["-s".to_string(), "/^a\\.txt/b/".to_string()]);
        } else {
            assert_eq!(tar_replacement("x&y\\"), "x\\&y\\\\");
            assert_eq!(rename_option("a.txt", "b"), vec!["--transform=s/^a\\.txt/b/".to_string()]);
        }
    }
}
