//! Which programs may use SwiftVM. A program is known by its path. The service's own program, and the
//! app it is in, always may; another program is asked about once, by the app, and the answer is kept
//! in `clients.json` in the data folder.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use swiftvm_protocol::paths::app_bundle_containing;
use swiftvm_protocol::wire::{ClientProgram, Command, ControlResponse, ErrorCode, Timestamp};

use crate::connection::ask_app;
use crate::transport::Peer;
use crate::{Config, Service, log};

/// How long the person at the computer has to answer.
const ANSWER_TIME: Duration = Duration::from_secs(120);

#[derive(Debug, Default, Serialize, Deserialize)]
struct Store {
    programs: Vec<ClientProgram>,
}

pub(crate) struct Permission {
    file: PathBuf,
    /// Programs that need no permission: the service's own, and those in the app it is in.
    trusted_program: Option<PathBuf>,
    trusted_bundle: Option<PathBuf>,
    store: Mutex<Store>,
    /// Held while the app asks, so that it asks one question at a time and about a program only once.
    asking: tokio::sync::Mutex<()>,
}

impl Permission {
    pub fn new(config: &Config) -> Self {
        let file = config.paths.clients_file();
        let store = std::fs::read(&file).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        let program = config.program.canonicalize().unwrap_or_else(|_| config.program.clone());
        Permission {
            file,
            trusted_bundle: config.trusts_own_program.then(|| app_bundle_containing(&program)).flatten(),
            trusted_program: config.trusts_own_program.then_some(program),
            store: Mutex::new(store),
            asking: tokio::sync::Mutex::new(()),
        }
    }

    fn store(&self) -> std::sync::MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn decision(&self, program: &Path) -> Option<bool> {
        let path = program.to_string_lossy();
        self.store().programs.iter().find(|entry| entry.path == path).map(|entry| entry.allowed)
    }

    fn is_trusted(&self, program: &Path) -> bool {
        self.trusted_program.as_deref() == Some(program) || self.trusted_bundle.as_ref().is_some_and(|bundle| program.starts_with(bundle))
    }

    /// Whether the program at the other end may go on. `Err` says why not.
    pub async fn check(&self, peer: &Peer, service: &Service) -> Result<(), String> {
        let Some(program) = &peer.program else {
            return Err("The program that connected can't be told, so it isn't allowed to use SwiftVM.".into());
        };
        let program = program.canonicalize().unwrap_or_else(|_| program.clone());
        if self.is_trusted(&program) {
            return Ok(());
        }
        let name = name_of(&program);
        let refused = |program: &Path| {
            format!("“{name}” was refused the use of SwiftVM. `swiftvm clients remove {}` has it asked again.", program.display())
        };
        match self.decision(&program) {
            Some(true) => return Ok(()),
            Some(false) => return Err(refused(&program)),
            None => {}
        }
        // Two minutes at most in all, also for a program whose question waits behind another's.
        let started = tokio::time::Instant::now();
        let Ok(_asking) = tokio::time::timeout(ANSWER_TIME, self.asking.lock()).await else {
            return Err(format!(
                "“{name}” isn't allowed to use SwiftVM, and nobody answered in time. `swiftvm clients allow {}` allows it.",
                swiftvm_protocol::text::shell_word(&program.to_string_lossy())
            ));
        };
        // Another connection from it may have been decided on while this one waited.
        match self.decision(&program) {
            Some(true) => return Ok(()),
            Some(false) => return Err(refused(&program)),
            None => {}
        }
        let request = json!({
            "command": Command::AskPermission.raw_value(),
            "program": program.to_string_lossy(),
            "programName": name,
        });
        let not_asked = |why: &str| {
            format!(
                "“{name}” isn't allowed to use SwiftVM, and {why} `swiftvm clients allow {}` allows it.",
                swiftvm_protocol::text::shell_word(&program.to_string_lossy())
            )
        };
        let left = ANSWER_TIME.saturating_sub(started.elapsed());
        let answer = match tokio::time::timeout(left, ask_app(service, None, &request)).await {
            Ok(Ok((answer, _, _))) => answer,
            Ok(Err(failure)) if failure.error.as_ref().is_some_and(|error| error.code == ErrorCode::AppNotRunning) => {
                return Err(not_asked(&format!("{} isn't running to ask.", service.config.app_name)));
            }
            Ok(Err(failure)) => {
                return Err(not_asked(&format!("asking failed: {}", failure.error_message().unwrap_or("no reason given."))));
            }
            Err(_) => return Err(not_asked("nobody answered in time.")),
        };
        if answer.get("ok") == Some(&Value::Bool(true)) {
            self.decide(&program, true);
            log(&format!("Allowed {}, as the user said.", program.display()));
            return Ok(());
        }
        let code = answer.pointer("/error/code").and_then(Value::as_str);
        if code == Some(ErrorCode::NotAllowed.name()) {
            self.decide(&program, false);
            log(&format!("Refused {}, as the user said.", program.display()));
            return Err(refused(&program));
        }
        if code == Some(ErrorCode::TimedOut.name()) {
            return Err(not_asked("nobody answered in time."));
        }
        let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or("no reason given.");
        Err(not_asked(&format!("asking failed: {message}")))
    }

    fn decide(&self, program: &Path, allowed: bool) {
        let path = program.to_string_lossy().into_owned();
        let mut store = self.store();
        store.programs.retain(|entry| entry.path != path);
        store.programs.push(ClientProgram { name: name_of(program), path, allowed, decided_at: Timestamp::now() });
        self.save(&store);
    }

    fn save(&self, store: &Store) {
        let Ok(data) = serde_json::to_vec_pretty(store) else { return };
        let staged = self.file.with_extension("json.new");
        let written = {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .open(&staged)
                .and_then(|mut file| file.write_all(&data))
        };
        if let Err(error) = written.and_then(|_| std::fs::rename(&staged, &self.file)) {
            log(&format!("{} couldn't be saved: {error}", self.file.display()));
        }
    }

    /// `clients`, `clients-allow`, `clients-deny` and `clients-remove`.
    pub fn change(&self, command: Command, program: Option<&str>, id: u64) -> ControlResponse {
        if command != Command::Clients {
            let Some(program) = program.filter(|program| program.starts_with('/')) else {
                return ControlResponse::failure(Some(id), ErrorCode::BadRequest, "Give the program's full path.");
            };
            let path = Path::new(program).canonicalize().unwrap_or_else(|_| PathBuf::from(program));
            match command {
                Command::ClientsAllow => self.decide(&path, true),
                Command::ClientsDeny => self.decide(&path, false),
                _ => {
                    let text = path.to_string_lossy().into_owned();
                    let mut store = self.store();
                    let before = store.programs.len();
                    store.programs.retain(|entry| entry.path != text && entry.path != program);
                    if store.programs.len() == before {
                        return ControlResponse::failure(Some(id), ErrorCode::NotFound, format!("Nothing was decided for {program}."));
                    }
                    self.save(&store);
                }
            }
        }
        let mut programs = self.store().programs.clone();
        programs.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then(a.path.cmp(&b.path)));
        ControlResponse { clients: Some(programs), ..ControlResponse::success(Some(id)) }
    }
}

/// What to call a program: its app's name when it is in one, its file name otherwise.
pub fn name_of(program: &Path) -> String {
    let name = match app_bundle_containing(program) {
        Some(app) => app.file_stem().map(|name| name.to_string_lossy().into_owned()),
        None => program.file_name().map(|name| name.to_string_lossy().into_owned()),
    };
    name.unwrap_or_else(|| program.display().to_string())
}
