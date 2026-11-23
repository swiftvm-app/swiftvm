//! `swiftvm exec --result-fd`: how the command in the guest ended, on a descriptor of its own, apart from
//! the guest's output and from this tool's exit status, which can have the same values.

use std::os::fd::RawFd;
use std::sync::Mutex;

use serde::Serialize;
use swiftvm_protocol::io;
use swiftvm_protocol::{Id, JobEnd};

use crate::guest_jobs::FAILED_STATUS;
use crate::util::{exit, fail_with, warn};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Completion {
    Exited,
    Signaled,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecCompletion {
    pub schema_version: u32,
    pub machine: String,
    #[serde(rename = "machineID", skip_serializing_if = "Option::is_none")]
    pub machine_id: Option<Id>,
    pub completion: Completion,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signal: Option<i32>,
}

impl ExecCompletion {
    pub fn new(machine: &str, machine_id: Option<Id>, end: Option<&JobEnd>) -> Self {
        // An error, or an end that is ambiguous or malformed, is no evidence that the command finished.
        let (completion, status, signal) = match end {
            Some(JobEnd { error: None, status: Some(status), signal: None }) => (Completion::Exited, Some(*status), None),
            Some(JobEnd { error: None, status: None, signal: Some(signal) }) if (1..=127).contains(signal) => {
                (Completion::Signaled, None, Some(*signal))
            }
            _ => (Completion::Unknown, None, None),
        };
        ExecCompletion { schema_version: 1, machine: machine.to_string(), machine_id, completion, status, signal }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct InvalidDescriptor;

impl std::fmt::Display for InvalidDescriptor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("--result-fd needs an open, writable descriptor greater than 2.")
    }
}

/// Writes the record, on a duplicate of the descriptor it was given, so that it never lands on a
/// connection that was opened later under the same number.
pub struct ExecCompletionWriter {
    descriptor: Option<RawFd>,
    /// The time-out and the reader can finish together. Each writes and exits holding this.
    finishing: Mutex<()>,
}

impl ExecCompletionWriter {
    pub fn new(descriptor: Option<RawFd>) -> Result<Self, InvalidDescriptor> {
        let Some(descriptor) = descriptor else { return Ok(ExecCompletionWriter { descriptor: None, finishing: Mutex::new(()) }) };
        if descriptor <= libc::STDERR_FILENO {
            return Err(InvalidDescriptor);
        }
        // SAFETY: fcntl takes any number and says when it isn't an open descriptor.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
        if flags < 0 || flags & libc::O_ACCMODE == libc::O_RDONLY {
            return Err(InvalidDescriptor);
        }
        // SAFETY: as above.
        let owned = unsafe { libc::fcntl(descriptor, libc::F_DUPFD_CLOEXEC, libc::STDERR_FILENO + 1) };
        if owned < 0 {
            return Err(InvalidDescriptor);
        }
        #[cfg(target_os = "macos")]
        // SAFETY: the descriptor was just made, and is this writer's.
        unsafe {
            libc::fcntl(owned, libc::F_SETNOSIGPIPE, 1);
        }
        Ok(ExecCompletionWriter { descriptor: Some(owned), finishing: Mutex::new(()) })
    }

    /// Writes the record on a line of its own. A caller reads a whole line before trusting it: a write
    /// that failed can leave part of one.
    pub fn write(&self, completion: &ExecCompletion) -> Result<(), i32> {
        let Some(descriptor) = self.descriptor else { return Ok(()) };
        let data = serde_json::to_vec(completion).unwrap_or_default();
        io::write_line(descriptor, &data)
    }

    pub fn finish(&self, completion: &ExecCompletion, status: i32, diagnostic: Option<&str>) -> ! {
        let _turn = self.finishing.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(diagnostic) = diagnostic {
            warn(&format!("swiftvm: {diagnostic}"));
        }
        let written = self.write(completion).is_ok();
        match status_after_writing(written, status) {
            Ok(status) => exit(status),
            // A guest's success isn't passed on once its record has been lost.
            Err(message) => fail_with(message, FAILED_STATUS),
        }
    }
}

impl Drop for ExecCompletionWriter {
    fn drop(&mut self) {
        if let Some(descriptor) = self.descriptor {
            io::close(descriptor);
        }
    }
}

/// What the tool exits with once the record was written, or not.
fn status_after_writing(written: bool, status: i32) -> Result<i32, &'static str> {
    if written { Ok(status) } else { Err("Couldn't write the exec completion record.") }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;

    fn json(record: &ExecCompletion) -> serde_json::Value {
        serde_json::to_value(record).unwrap()
    }

    #[test]
    fn guest_statuses_are_known_even_when_they_match_cli_failures() {
        let id = Id(uuid::Uuid::new_v4());
        for status in [0, 1, 124, 125, 255, 256, -1, i32::MAX] {
            let record = ExecCompletion::new("desk", Some(id), Some(&JobEnd { status: Some(status), ..Default::default() }));
            assert_eq!((record.completion, record.status, record.signal), (Completion::Exited, Some(status), None));
            let json = json(&record);
            assert_eq!(json["schemaVersion"], 1);
            assert_eq!(json["machine"], "desk");
            assert_eq!(json["machineID"], id.to_string());
        }
    }

    #[test]
    fn a_signal_is_not_an_exit_status() {
        let record = ExecCompletion::new("desk", None, Some(&JobEnd { signal: Some(libc::SIGTERM), ..Default::default() }));
        assert_eq!((record.completion, record.status, record.signal), (Completion::Signaled, None, Some(libc::SIGTERM)));
    }

    #[test]
    fn missing_or_ambiguous_completion_stays_unknown() {
        let ends = [
            None,
            Some(JobEnd::default()),
            Some(JobEnd { signal: Some(0), ..Default::default() }),
            Some(JobEnd { signal: Some(i32::MAX), ..Default::default() }),
            Some(JobEnd { status: Some(0), signal: Some(libc::SIGTERM), error: None }),
            Some(JobEnd { status: Some(0), signal: None, error: Some("interrupted".into()) }),
            Some(JobEnd::failure("lost")),
        ];
        for end in ends {
            let record = ExecCompletion::new("desk", None, end.as_ref());
            assert_eq!((record.completion, record.status, record.signal), (Completion::Unknown, None, None), "{end:?}");
        }
    }

    #[test]
    fn invalid_and_read_only_descriptors_are_rejected_before_dispatch() {
        for descriptor in [-1, 0, 1, 2, i32::MAX] {
            assert!(ExecCompletionWriter::new(Some(descriptor)).is_err());
        }
        let source = std::fs::File::open("/dev/null").unwrap();
        assert!(ExecCompletionWriter::new(Some(source.as_raw_fd())).is_err());
    }

    #[test]
    fn a_record_has_its_own_line_and_a_lost_one_fails_the_command() {
        let (reader, writer) = std::os::unix::net::UnixStream::pair().unwrap();
        let completion = ExecCompletionWriter::new(Some(writer.as_raw_fd())).unwrap();
        drop(writer);
        let record = ExecCompletion::new("desk", None, Some(&JobEnd { status: Some(125), ..Default::default() }));
        completion.write(&record).unwrap();
        let line = io::read_line(reader.as_raw_fd()).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&line).unwrap();
        assert_eq!((json["completion"].as_str(), json["status"].as_i64()), (Some("exited"), Some(125)));
        assert!(json.get("machineID").is_none());
        drop(reader);
        assert!(completion.write(&record).is_err());
        assert_eq!(status_after_writing(false, 0), Err("Couldn't write the exec completion record."));
        assert_eq!(status_after_writing(true, 0), Ok(0));
    }
}
