//! What every command uses: leaving with a message, printing, and the app to talk to.

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

use swiftvm_protocol::io::write_all;
use swiftvm_protocol::paths::home_directory;
use swiftvm_protocol::{AppIdentity, ControlClient, ControlPaths, ControlRequest, ControlResponse};

/// Ends the program with `status`, after what was printed has gone out.
pub fn exit(status: i32) -> ! {
    let _ = std::io::stdout().flush();
    std::process::exit(status)
}

/// Says why on the error output and ends the program with status 1.
pub fn fail(message: &str) -> ! {
    fail_with(message, 1)
}

pub fn fail_with(message: &str, status: i32) -> ! {
    warn(&format!("swiftvm: {message}"));
    exit(status)
}

/// A line on the error output. Written in one go and straight to the descriptor, as another thread may
/// be about to end the program.
pub fn warn(line: &str) {
    write_all(libc::STDERR_FILENO, format!("{line}\n").as_bytes());
}

/// A line on the output. A reader that has gone away isn't this program's problem here: where that
/// should end it, SIGPIPE does.
pub fn say(line: &str) {
    let mut output = std::io::stdout().lock();
    let _ = writeln!(output, "{line}");
}

/// Text on the output, as it is.
pub fn say_raw(text: &str) {
    let mut output = std::io::stdout().lock();
    let _ = output.write_all(text.as_bytes());
}

/// Lets SIGPIPE end the program, as it does a C or Swift one, rather than turn into a failed write.
/// Rust ignores it before `main` starts.
pub fn restore_broken_pipe_signal() {
    // SAFETY: setting a signal's disposition to its default.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
}

/// Makes a reader that has gone away a failed write rather than the end of the program.
pub fn ignore_broken_pipe_signal() {
    // SAFETY: setting a signal's disposition to ignored.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
}

/// This program, with any link to it followed: the one in `/usr/local/bin` leads into the app.
pub fn tool_path() -> PathBuf {
    let program = std::env::current_exe().unwrap_or_else(|_| PathBuf::from(std::env::args().next().unwrap_or_default()));
    program.canonicalize().unwrap_or(program)
}

/// The copy of SwiftVM this tool is part of. A tool that can't tell stops here, with the reason.
pub fn identity() -> AppIdentity {
    static IDENTITY: OnceLock<AppIdentity> = OnceLock::new();
    *IDENTITY.get_or_init(|| match AppIdentity::of_program(&tool_path()) {
        Ok(identity) => identity,
        Err(app) => {
            warn(&format!("SwiftVM can't tell which copy of it this is: the Info.plist of {} can't be read.", app.display()));
            exit(1)
        }
    })
}

pub fn paths() -> &'static ControlPaths {
    static PATHS: OnceLock<ControlPaths> = OnceLock::new();
    PATHS.get_or_init(|| {
        // What isn't UTF-8 is read as well as it can be, as Foundation does, rather than end the program.
        let environment: HashMap<String, String> =
            std::env::vars_os().map(|(name, value)| (name.to_string_lossy().into_owned(), value.to_string_lossy().into_owned())).collect();
        ControlPaths::new(identity(), &environment, &home_directory())
    })
}

pub fn client() -> ControlClient {
    ControlClient::new(paths().socket(), identity().name())
}

/// Sends `request` and returns the answer. Stops with the app's reason when it says no.
pub fn send(request: ControlRequest) -> ControlResponse {
    match client().send(&request) {
        Ok(response) if response.ok => response,
        Ok(response) => fail(response.error.as_deref().unwrap_or("The command failed.")),
        Err(error) => fail(&error.to_string()),
    }
}
