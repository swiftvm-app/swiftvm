//! The TPM 2.0 of a Windows guest: `swtpm`, in a process of its own next to QEMU, with what it holds in one
//! file in the machine's bundle.
//!
//! QEMU is handed one end of a line and swtpm the other, as its control channel. QEMU starts the TPM over
//! it. Once QEMU is gone the line closes, and swtpm ends (`terminate`).
//!
//! swtpm reads its options as `key=value` lists that a comma ends, with no way to escape one, so it runs in
//! the bundle and is given the file by its name there.

use std::os::fd::OwnedFd;
use std::path::Path;

use tokio::process::Child;

use crate::config::Bundle;
use crate::process::{self, FIRST_DESCRIPTOR, Launch};

pub fn arguments(state_file_name: &str) -> Vec<String> {
    vec![
        "socket".into(),
        "--tpm2".into(),
        // `terminate`: end when QEMU, at the other end, is gone.
        "--ctrl".into(),
        format!("type=unixio,clientfd={FIRST_DESCRIPTOR},terminate"),
        // `lock`: two at once would write over each other's state.
        "--tpmstate".into(),
        format!("backend-uri=file://{state_file_name},mode=0600,lock"),
        // No `--log`: swtpm writes its errors to standard error by itself, which goes to the log.
    ]
}

/// What swtpm says each time QEMU, at the other end, goes away: no news about why.
const DISCONNECT_NOTICE: &str = "Data client disconnected";
const LINE_PREFIX: &str = "swtpm: ";

/// What swtpm said last that tells why the machine didn't start, if anything did.
pub fn complaint(output: &str) -> Option<String> {
    output
        .lines()
        .map(|line| {
            let text = line.trim();
            text.strip_prefix(LINE_PREFIX).unwrap_or(text).to_string()
        })
        .rfind(|line| !line.is_empty() && line != DISCONNECT_NOTICE)
}

/// Starts the machine's TPM, and gives back QEMU's end of its line.
pub fn launch(program: &Path, bundle: &Bundle) -> std::io::Result<(Child, OwnedFd)> {
    let (tpm_end, qemu_end) = crate::fdpass::socket_pair(libc::SOCK_STREAM)?;
    let state = bundle.tpm_state();
    let name = state.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let child = process::launch(Launch {
        program,
        arguments: &arguments(&name),
        descriptors: vec![tpm_end],
        log: &bundle.tpm_log(),
        pid_file: &bundle.tpm_pid_file(),
        directory: &bundle.path,
        environment: Default::default(),
    })?;
    Ok((child, qemu_end))
}

/// Ends the TPM that was left running for the machine in `bundle`, once its QEMU is gone, and waits until
/// it has: the next one can't open the state while it holds it. It is told apart from another machine's
/// by the folder it runs in.
pub async fn end_leftover(bundle: &Bundle) {
    let folder = std::fs::canonicalize(&bundle.path).unwrap_or_else(|_| bundle.path.clone());
    process::end_leftover(&bundle.tpm_pid_file(), |pid, arguments| {
        let Some(program) = arguments.first() else { return false };
        Path::new(program).file_name().is_some_and(|name| name == "swtpm")
            && process::working_directory_of(pid).is_some_and(|directory| std::fs::canonicalize(&directory).unwrap_or(directory) == folder)
    })
    .await;
}
