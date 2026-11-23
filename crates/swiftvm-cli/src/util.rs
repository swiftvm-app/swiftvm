//! What every command uses: leaving with a message, printing, and the app to talk to.

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

use swiftvm_protocol::io::write_all;
use swiftvm_protocol::paths::home_directory;
use swiftvm_protocol::wire::{ApiError, ErrorCode};
use swiftvm_protocol::{AppIdentity, ClientError, ControlPaths, ControlRequest, ControlResponse, ServiceClient};

/// Ends the program with `status`, after what was printed has gone out.
pub fn exit(status: i32) -> ! {
    let _ = std::io::stdout().flush();
    std::process::exit(status)
}

/// Says why on the error output and ends the program with status 1.
pub fn fail(message: &str) -> ! {
    fail_with(message, 1)
}

/// With `--json`, the reason goes on the output as an answer that says no.
pub fn fail_with(message: &str, status: i32) -> ! {
    if prints_json() {
        say_json(&ControlResponse::failure(None, ErrorCode::Failed, message));
    } else {
        warn(&format!("swiftvm: {message}"));
    }
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

/// What this tool calls itself to the service.
pub fn client_name() -> String {
    format!("swiftvm {}", env!("CARGO_PKG_VERSION"))
}

/// The service, which this tool starts when it isn't running.
pub fn client() -> ServiceClient {
    ServiceClient::new(paths().clone(), client_name(), Some(tool_path()))
}

/// Sends `request` and returns the answer. Stops with the reason when the answer is no.
pub fn send(request: ControlRequest) -> ControlResponse {
    match client().send(&request) {
        Ok(response) if response.ok => response,
        Ok(response) if prints_json() => {
            say_json(&response);
            exit(1)
        }
        Ok(response) => fail(response.error_message().unwrap_or("The command failed.")),
        Err(error) if prints_json() => {
            say_json(&failure_answer(&error));
            exit(1)
        }
        Err(error) => fail(&error.to_string()),
    }
}

static PRINTS_JSON: AtomicBool = AtomicBool::new(false);

/// `--json`: what a command prints is the service's answer, in API v1.
pub fn set_prints_json(prints: bool) {
    PRINTS_JSON.store(prints, Ordering::Relaxed);
}

pub fn prints_json() -> bool {
    PRINTS_JSON.load(Ordering::Relaxed)
}

/// Prints `value` on one line of JSON.
pub fn say_json<T: serde::Serialize>(value: &T) {
    say(&serde_json::to_string(value).unwrap_or_default());
}

/// A failure that never reached the service, in the shape of its answers.
pub fn failure_answer(error: &ClientError) -> ControlResponse {
    let error = match error {
        ClientError::Refused(refusal) => refusal.clone(),
        other => ApiError { code: ErrorCode::Failed, message: other.to_string() },
    };
    ControlResponse { error: Some(error), ..ControlResponse::default() }
}

/// Sends `request` for the answer a command shows. With `--json` it prints the answer, whatever it is,
/// and ends the program: with status 0 when it says yes, 1 when no. Otherwise it returns the answer, or
/// stops with the reason when it says no.
pub fn answer(request: ControlRequest) -> ControlResponse {
    if !prints_json() {
        return send(request);
    }
    let response = client().send(&request).unwrap_or_else(|error| failure_answer(&error));
    say_json(&response);
    exit(if response.ok { 0 } else { 1 })
}
