//! The QEMU machines the service runs, and the engine requests about them (`qemu-…`). The app hands its
//! QEMU machines over with `qemu-start`; the machines outlive a restart of the service, whose next run takes
//! them on again from their runtime folders.

use std::collections::{BTreeMap, HashMap};
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::Value;
use swiftvm_protocol::qemu::{DescriptorRole, Frame, QemuEvent, QemuExit, QemuRequest, QemuState};
use swiftvm_protocol::wire::{Command, ControlResponse, ErrorCode, Id};
use swiftvm_qemu::installation::Installation;
use swiftvm_qemu::{Machine, QemuError, StartOptions};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::connection::Connection;
use crate::{Service, lines, log};

enum Slot {
    /// Being started: another start waits for this one to finish.
    Starting,
    Running(Arc<Machine>),
    /// QEMU has ended, and whoever started it hasn't heard how yet.
    Exited(QemuExit),
}

pub(crate) struct Engine {
    /// Where the machines' runtime folders are.
    root: PathBuf,
    installation: Option<Installation>,
    machines: Mutex<HashMap<Id, Slot>>,
    /// Held to read by each request at work on a machine. The service, stopping, takes it to write and
    /// lets go of the machines only once that work is done; `true` after that, when nothing more starts.
    work: tokio::sync::RwLock<bool>,
    /// The service is stopping: no new work starts.
    closing: std::sync::atomic::AtomicBool,
}

/// The longest the service, stopping, waits for the work under way on its machines.
const LONGEST_WORK: std::time::Duration = std::time::Duration::from_secs(120);

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Engine {
    pub fn new(root: PathBuf, installation: Option<Installation>) -> Arc<Engine> {
        Arc::new(Engine {
            root,
            installation,
            machines: Mutex::new(HashMap::new()),
            work: tokio::sync::RwLock::new(false),
            closing: std::sync::atomic::AtomicBool::new(false),
        })
    }

    /// Takes on the machines that an earlier service started and left running.
    pub async fn adopt_all(self: &Arc<Self>) {
        let Ok(entries) = std::fs::read_dir(&self.root) else { return };
        for entry in entries.flatten() {
            let folder = entry.path();
            if !folder.is_dir() {
                continue;
            }
            match Machine::adopt(&folder).await {
                Ok(machine) => {
                    log(&format!("Took on “{}” (QEMU {}), which was running.", machine.name(), machine.pid()));
                    self.insert(machine);
                }
                Err(Some((id, exit))) => {
                    log(&format!("A machine ({id}) ended while no service ran."));
                    lock(&self.machines).insert(id, Slot::Exited(exit));
                }
                Err(None) => {
                    let _ = std::fs::remove_dir_all(&folder);
                }
            }
        }
    }

    /// Lets go of every machine without ending it, for the next service to take on, once the work under
    /// way on them is done: a start, a restore, a save.
    pub async fn shutdown(&self) {
        self.closing.store(true, std::sync::atomic::Ordering::SeqCst);
        // Work that doesn't end in time, on a QEMU that doesn't answer, isn't waited for.
        let _closed = match tokio::time::timeout(LONGEST_WORK, self.work.write()).await {
            Ok(mut closed) => {
                *closed = true;
                Some(closed)
            }
            Err(_) => {
                log("Letting go of the machines with work still under way on them.");
                None
            }
        };
        let running: Vec<Arc<Machine>> = lock(&self.machines)
            .values()
            .filter_map(|slot| match slot {
                Slot::Running(machine) => Some(machine.clone()),
                _ => None,
            })
            .collect();
        for machine in running {
            machine.detach().await;
        }
    }

    /// Keeps `machine`, and notes how it ended once it has.
    fn insert(self: &Arc<Self>, machine: Arc<Machine>) {
        lock(&self.machines).insert(machine.id, Slot::Running(machine.clone()));
        let engine = Arc::downgrade(self);
        let mut status = machine.subscribe();
        tokio::spawn(async move {
            let Ok(ended) = status.wait_for(|status| status.0 == QemuState::Exited).await.map(|status| status.1.clone()) else { return };
            let exit = ended.unwrap_or_default();
            log(&format!("“{}” ended{}.", machine.name(), exit.reason.as_ref().map(|reason| format!(" ({reason})")).unwrap_or_default()));
            let Some(engine) = engine.upgrade() else { return };
            let mut machines = lock(&engine.machines);
            if matches!(machines.get(&machine.id), Some(Slot::Running(current)) if Arc::ptr_eq(current, &machine)) {
                machines.insert(machine.id, Slot::Exited(exit));
            }
        });
    }

    fn machine(&self, request: &QemuRequest, id: u64) -> Result<Arc<Machine>, Box<ControlResponse>> {
        let Some(machine) = request.machine else {
            return Err(failure(id, ErrorCode::BadRequest, "The request doesn't say which machine."));
        };
        match lock(&self.machines).get(&machine) {
            Some(Slot::Running(running)) if running.state() != QemuState::Exited => Ok(running.clone()),
            Some(Slot::Starting) => Err(failure(id, ErrorCode::Busy, "The machine is starting.")),
            _ => Err(failure(id, ErrorCode::WrongState, "The service doesn't run that machine.")),
        }
    }

    async fn start(
        self: &Arc<Self>,
        request: &QemuRequest,
        descriptors: Vec<OwnedFd>,
        id: u64,
    ) -> Result<Arc<Machine>, Box<ControlResponse>> {
        let Some(bundle) = request.bundle.as_deref().map(PathBuf::from) else {
            return Err(failure(id, ErrorCode::BadRequest, "The request doesn't say where the machine is."));
        };
        let roles = request.descriptors.clone().unwrap_or_default();
        if roles.len() != descriptors.len() {
            return Err(failure(
                id,
                ErrorCode::BadRequest,
                format!("The request names {} descriptors, and {} came with it.", roles.len(), descriptors.len()),
            ));
        }
        let Some(installation) = self.installation.clone() else { return Err(qemu_failure(id, &QemuError::NotInstalled)) };
        let config = Machine::configuration(&bundle).map_err(|error| qemu_failure(id, &error))?;
        {
            let mut machines = lock(&self.machines);
            match machines.get(&config.id) {
                Some(Slot::Starting) => return Err(failure(id, ErrorCode::Busy, format!("“{}” is starting already.", config.name))),
                Some(Slot::Running(machine)) if machine.state() != QemuState::Exited => {
                    return Err(failure(id, ErrorCode::WrongState, format!("“{}” is running already.", config.name)));
                }
                _ => {}
            }
            machines.insert(config.id, Slot::Starting);
        }
        // The slot is let go of however the start ends, a panic too, unless a machine took it.
        let mut starting = StartingSlot { engine: self, id: config.id, is_taken: false };
        let mut options = StartOptions {
            bundle,
            saved_state: request.saved_state.as_deref().map(PathBuf::from),
            direct_x: request.direct_x.clone(),
            refresh_rate: request.refresh_rate,
            nbd_sockets: nbd_sockets(request.disk_sources.as_ref()),
            ..StartOptions::default()
        };
        for (role, descriptor) in roles.into_iter().zip(descriptors) {
            match role {
                DescriptorRole::Console => options.console = Some(descriptor),
                DescriptorRole::Network => options.networks.push(descriptor),
                DescriptorRole::Display => options.display = Some(descriptor),
            }
        }
        match Machine::launch(options, &installation, &self.root).await {
            Ok(machine) => {
                log(&format!("Started “{}” (QEMU {}).", machine.name(), machine.pid()));
                self.insert(machine.clone());
                starting.is_taken = true;
                Ok(machine)
            }
            Err(error) => {
                log(&format!("“{}” didn't start: {error}", config.name));
                Err(qemu_failure(id, &error))
            }
        }
    }
}

/// A machine's slot while it starts, which goes again unless the machine took it.
struct StartingSlot<'a> {
    engine: &'a Engine,
    id: Id,
    is_taken: bool,
}

impl Drop for StartingSlot<'_> {
    fn drop(&mut self) {
        if !self.is_taken {
            let mut machines = lock(&self.engine.machines);
            if matches!(machines.get(&self.id), Some(Slot::Starting)) {
                machines.remove(&self.id);
            }
        }
    }
}

fn nbd_sockets(sources: Option<&BTreeMap<String, String>>) -> HashMap<Id, String> {
    sources
        .into_iter()
        .flatten()
        .filter_map(|(disk, socket)| uuid::Uuid::parse_str(disk).ok().map(|disk| (Id(disk), socket.clone())))
        .collect()
}

fn failure(id: u64, code: ErrorCode, message: impl Into<String>) -> Box<ControlResponse> {
    Box::new(ControlResponse::failure(Some(id), code, message))
}

fn qemu_failure(id: u64, error: &QemuError) -> Box<ControlResponse> {
    failure(id, error.code(), error.to_string())
}

fn answered(id: u64, result: Result<(), QemuError>) -> ControlResponse {
    match result {
        Ok(()) => ControlResponse::success(Some(id)),
        Err(error) => *qemu_failure(id, &error),
    }
}

/// Answers an engine request. Returns the connection when it goes on with further requests.
pub(crate) async fn handle(mut connection: Connection, id: u64, command: Command, request: Value) -> Option<Connection> {
    let engine = connection.service.engine.clone();
    let descriptors = connection.take_descriptors();
    let request: QemuRequest = match serde_json::from_value(request) {
        Ok(request) => request,
        Err(error) => {
            let answer = ControlResponse::failure(Some(id), ErrorCode::BadRequest, format!("The request couldn't be understood: {error}"));
            return connection.answer(&answer).await.then_some(connection);
        }
    };
    if command == Command::QemuList {
        let machines = lock(&engine.machines)
            .values()
            .filter_map(|slot| match slot {
                Slot::Running(machine) if machine.state() != QemuState::Exited => Some(machine.summary()),
                _ => None,
            })
            .collect();
        let answer = ControlResponse { qemu_machines: Some(machines), ..ControlResponse::success(Some(id)) };
        return connection.answer(&answer).await.then_some(connection);
    }
    // Work on a machine, which the service lets end before it stops. A stream that follows isn't work.
    let work = if command == Command::QemuAttach { None } else { Some(engine.work.read().await) };
    if work.as_ref().is_some_and(|closed| **closed) || (work.is_some() && engine.closing.load(std::sync::atomic::Ordering::SeqCst)) {
        let answer = ControlResponse::failure(Some(id), ErrorCode::Busy, "The service is stopping. Try again in a moment.");
        return connection.answer(&answer).await.then_some(connection);
    }
    if command == Command::QemuStart {
        let started = engine.start(&request, descriptors, id).await;
        drop(work);
        return match started {
            Ok(machine) => follow(connection, id, machine).await,
            Err(failure) => connection.answer(&failure).await.then_some(connection),
        };
    }
    drop(descriptors);
    if command == Command::QemuStop
        && request.machine.is_none()
        && let Some(bundle) = &request.bundle
    {
        // By its bundle: the machine the service runs from there, or a QEMU left behind for it.
        let answer = match Machine::configuration(std::path::Path::new(bundle)) {
            Ok(config) => {
                let running = match lock(&engine.machines).get(&config.id) {
                    Some(Slot::Running(machine)) => Some(machine.clone()),
                    _ => None,
                };
                match running {
                    Some(machine) => machine.stop(request.force == Some(true)).await,
                    None => Machine::end_leftover(std::path::Path::new(bundle), &config).await,
                }
                ControlResponse::success(Some(id))
            }
            Err(error) => *qemu_failure(id, &error),
        };
        return connection.answer(&answer).await.then_some(connection);
    }
    if command == Command::QemuAttach
        && let Some(machine) = request.machine
    {
        let exited = {
            let mut machines = lock(&engine.machines);
            match machines.get(&machine) {
                Some(Slot::Exited(_)) => match machines.remove(&machine) {
                    Some(Slot::Exited(exit)) => Some(exit),
                    _ => None,
                },
                _ => None,
            }
        };
        if let Some(exit) = exited {
            let answer = ControlResponse { exit: Some(exit), ..ControlResponse::success(Some(id)) };
            return connection.answer(&answer).await.then_some(connection);
        }
    }
    let machine = match engine.machine(&request, id) {
        Ok(machine) => machine,
        Err(failure) => return connection.answer(&failure).await.then_some(connection),
    };
    let missing = |what: &str| ControlResponse::failure(Some(id), ErrorCode::BadRequest, format!("The request doesn't say {what}."));
    let answer = match command {
        Command::QemuAttach => return follow(connection, id, machine).await,
        Command::QemuContinue => answered(id, machine.resume_held().await),
        Command::QemuStop => {
            let force = request.force == Some(true);
            log(&format!("Stopping “{}”{}, as asked.", machine.name(), if force { " at once" } else { "" }));
            machine.stop(force).await;
            ControlResponse::success(Some(id))
        }
        Command::QemuPowerdown => answered(id, machine.power_down().await),
        Command::QemuPause => answered(id, machine.pause().await),
        Command::QemuResume => answered(id, machine.resume().await),
        Command::QemuSave => match &request.path {
            Some(path) => answered(id, machine.save(std::path::Path::new(path)).await),
            None => missing("where to save the machine's memory"),
        },
        Command::QemuLink => match (request.index, request.connected) {
            (Some(index), Some(connected)) => answered(id, machine.set_link(index, connected).await),
            _ => missing("which network card, and whether its cable is in"),
        },
        Command::QemuAttachImage => match request.image {
            Some(image) => answered(id, machine.attach_image(image).await),
            None => missing("which image"),
        },
        Command::QemuDetachImage => match request.image_id {
            Some(image) => answered(id, machine.detach_image(image).await),
            None => missing("which drive"),
        },
        Command::QemuPointer => match &request.pointer {
            Some(pointer) => answered(id, machine.pointer(pointer, request.size).await),
            None => missing("what the mouse does"),
        },
        Command::QemuKeys => match &request.keys {
            Some(keys) => answered(id, machine.keys(keys).await),
            None => missing("what to type"),
        },
        Command::QemuConnect => {
            let Some(port) = request.port else { return connection.answer(&missing("which port")).await.then_some(connection) };
            let connected = machine.connect(port).await;
            drop(work);
            return match connected {
                Ok(guest) => relay(connection, id, guest).await,
                Err(error) => connection.answer(&qemu_failure(id, &error)).await.then_some(connection),
            };
        }
        Command::QemuFrame => match machine.frame().await {
            Ok((width, height, pixels)) => {
                let frame = Frame { width, height, bytes_per_row: width * 4, length: pixels.len() as u64 };
                let answer = ControlResponse { frame: Some(frame), ..ControlResponse::success(Some(id)) };
                if !connection.answer(&answer).await || connection.writer.write_all(&pixels).await.is_err() {
                    return None;
                }
                return Some(connection);
            }
            Err(error) => *qemu_failure(id, &error),
        },
        _ => ControlResponse::failure(Some(id), ErrorCode::BadRequest, "The service doesn't know that request."),
    };
    if let Some(error) = &answer.error {
        log(&format!("{} for “{}” failed: {}", command.raw_value(), machine.name(), error.message));
    }
    connection.answer(&answer).await.then_some(connection)
}

/// Answers with the machine, then tells how it ended, once it has. Ends when the client goes, or the
/// service stops: the client attaches again to the next service.
async fn follow(mut connection: Connection, id: u64, machine: Arc<Machine>) -> Option<Connection> {
    let answer = ControlResponse { qemu: Some(machine.summary()), ..ControlResponse::success(Some(id)) };
    if !connection.answer(&answer).await {
        return None;
    }
    let service: Arc<Service> = connection.service.clone();
    let mut stopping = service.stopping.subscribe();
    let mut status = machine.subscribe();
    let mut ignored = [0u8; 256];
    loop {
        tokio::select! {
            exit = exited(&mut status) => {
                {
                    let mut machines = lock(&service.engine.machines);
                    if matches!(machines.get(&machine.id), Some(Slot::Exited(_))) {
                        machines.remove(&machine.id);
                    }
                }
                let event = QemuEvent { event: "qemu-exited".into(), machine: machine.id, exit: Some(exit) };
                lines::write_value(&mut connection.writer, &event).await;
                return None;
            }
            read = connection.reader.read(&mut ignored) => {
                if !matches!(read, Ok(count) if count > 0) {
                    return None;
                }
            }
            _ = crate::until_stopped(&mut stopping) => return None,
        }
    }
}

/// How the machine whose status `status` is ended, once it has.
async fn exited(status: &mut tokio::sync::watch::Receiver<(QemuState, Option<QemuExit>)>) -> QemuExit {
    status.wait_for(|status| status.0 == QemuState::Exited).await.ok().and_then(|status| status.1.clone()).unwrap_or_default()
}

/// Answers, then carries a connection to a port in the guest both ways until both sides are done.
async fn relay(mut connection: Connection, id: u64, mut guest: tokio::net::UnixStream) -> Option<Connection> {
    if !connection.answer(&ControlResponse::success(Some(id))).await {
        return None;
    }
    let (mut client, left) = connection.into_stream()?;
    if !left.is_empty() && guest.write_all(&left).await.is_err() {
        return None;
    }
    let _ = tokio::io::copy_bidirectional(&mut client, &mut guest).await;
    None
}
