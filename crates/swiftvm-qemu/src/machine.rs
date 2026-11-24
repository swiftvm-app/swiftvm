//! A machine running on QEMU, in a process of its own (a port of the app's `QEMUBackend.swift`).
//!
//! QEMU starts with its guest held. The lines it needs are put in place first: its machine protocol, the
//! display, the network and the agent's serial line. `resume_held` lets it run. A restart of the guest ends
//! QEMU (`-no-reboot`), and whoever started it starts it again, so that the next run gets the hardware the
//! machine is configured with by then.
//!
//! A record in the machine's runtime folder says what the service knows of it, so that a service that
//! started later takes it on again (`Machine::adopt`): QEMU holds every line it needs by itself.

use std::collections::HashMap;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use swiftvm_protocol::qemu::{DirectX, DisplayAdapter, Keys, Pointer, QemuExit, QemuMachine, QemuState, RemovableImage, Size};
use swiftvm_protocol::wire::Id;
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;

use crate::agent_channel::AgentChannel;
use crate::battery::HostBattery;
use crate::command_line::{self, CommandLine, DiskSource};
use crate::config::{Bundle, DiskFormat, MachineConfig};
use crate::input::{self, BUTTON_NAMES, InputStep};
use crate::installation::Installation;
use crate::qmp::{Qmp, QmpEvent};
use crate::saved_state::{self, SavedStateHeader};
use crate::{QemuError, process, tpm};

/// How a machine is to start, besides what its bundle says.
#[derive(Default)]
pub struct StartOptions {
    pub bundle: PathBuf,
    /// Resume from this saved state instead of booting.
    pub saved_state: Option<PathBuf>,
    pub direct_x: Option<DirectX>,
    pub refresh_rate: Option<u32>,
    /// The NBD socket that serves each compressed disk.
    pub nbd_sockets: HashMap<Id, String>,
    /// The serial console's line. Without one, the console goes nowhere.
    pub console: Option<OwnedFd>,
    /// One datagram socket per network card, in the order of the machine's interfaces.
    pub networks: Vec<OwnedFd>,
    /// The one client of the VNC display, handed to QEMU once it is up.
    pub display: Option<OwnedFd>,
}

/// What the service knows of a machine it runs, kept in its runtime folder.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    machine: Id,
    name: String,
    bundle: PathBuf,
    pid: i32,
    #[serde(default)]
    tpm_pid: Option<i32>,
    adapter: DisplayAdapter,
    state: QemuState,
    /// The USB port of each drive and disk on USB, by its identifier.
    usb_ports: HashMap<Id, u32>,
    /// The drives that are plugged in, which an unplug finds its devices by.
    drives: Vec<RemovableImage>,
    has_tpm: bool,
    audio: bool,
    network_count: usize,
    /// Until it runs: the saved state it resumes from.
    #[serde(default)]
    saved_state: Option<PathBuf>,
    /// Until it runs: an installer disc waits for a key, which nobody is there to press.
    #[serde(default)]
    presses_key: bool,
    #[serde(default)]
    spice_socket: Option<PathBuf>,
}

const RECORD: &str = "machine.json";

/// How long QEMU has to set up its machine protocol after it starts.
const STARTUP_TIME: Duration = Duration::from_secs(30);

pub struct Machine {
    pub id: Id,
    folder: PathBuf,
    bundle: Bundle,
    record: Mutex<Record>,
    qmp: Arc<Qmp>,
    agent: Mutex<Option<Arc<AgentChannel>>>,
    /// Where it is in its life, and once QEMU has ended, how.
    status: watch::Sender<(QemuState, Option<QemuExit>)>,
    /// Becomes `true` once QEMU's process is gone.
    gone: watch::Receiver<bool>,
    /// The service has asked QEMU to end, and its end is no news.
    expects_exit: AtomicBool,
    /// Why QEMU said the guest went down, from its `SHUTDOWN` event.
    shutdown_reason: Mutex<Option<String>>,
    /// Who waits for QEMU to say a device is gone, by the device's ID.
    removals: Mutex<HashMap<String, Vec<oneshot::Sender<()>>>>,
    /// What was asked of the mouse and the keyboard last; the next thing waits for it.
    input: tokio::sync::Mutex<InputState>,
    battery: Mutex<Option<JoinHandle<()>>>,
    battery_status: Mutex<Option<u32>>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
    frames: AtomicU64,
}

#[derive(Default)]
struct InputState {
    buttons: u8,
    /// The display's size when a picture of it was last taken.
    size: Option<(i64, i64)>,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Machine {
    /// The machine in `bundle`, as its configuration says, if it runs on QEMU.
    pub fn configuration(bundle: &Path) -> Result<MachineConfig, QemuError> {
        let config = MachineConfig::read(&Bundle::new(bundle)).map_err(|error| QemuError::Invalid(error.to_string()))?;
        if config.engine() != crate::config::Engine::Qemu {
            return Err(QemuError::Invalid(format!("“{}” doesn't run on QEMU.", config.name)));
        }
        Ok(config)
    }

    /// Ends the QEMU that was left running for the machine in `bundle`, by a service or an app that stopped
    /// without stopping it, and its TPM, and waits until they are gone.
    pub async fn end_leftover(bundle: &Path, config: &MachineConfig) {
        let bundle = Bundle::new(bundle);
        process::end_leftover(&bundle.qemu_pid_file(), |_, arguments| process::is_qemu(arguments, &config.id.0)).await;
        tpm::end_leftover(&bundle).await;
    }

    /// Starts the machine in `options.bundle` with its guest held, its runtime files in a folder of its own
    /// under `root`.
    pub async fn launch(options: StartOptions, installation: &Installation, root: &Path) -> Result<Arc<Machine>, QemuError> {
        let bundle = Bundle::new(options.bundle.clone());
        let config = Self::configuration(&bundle.path)?;
        let folder = &crate::runtime::machine_folder(root, &config.id);
        crate::runtime::make_private(folder).map_err(|error| QemuError::DidNotStart(error.to_string()))?;
        // A QEMU that was left running for the machine, and the TPM that goes once it has.
        Self::end_leftover(&bundle.path, &config).await;

        let mut disk_sources = HashMap::new();
        for disk in &config.disks {
            let path = bundle.disk(disk);
            if !path.exists() {
                return Err(QemuError::Invalid(format!("The virtual machine is missing “{}”.", disk.file_name)));
            }
            let source = match disk.format {
                DiskFormat::Raw => DiskSource::File(path),
                DiskFormat::Compressed => {
                    DiskSource::Nbd(
                        options.nbd_sockets.get(&disk.id).cloned().ok_or_else(|| {
                            QemuError::Invalid(format!("“{}” is compressed, and nothing serves it to QEMU.", disk.file_name))
                        })?,
                    )
                }
                DiskFormat::Asif => {
                    return Err(QemuError::Invalid(format!(
                        "QEMU can't read “{}”, which is in Apple's sparse image format. Convert the disk to a raw or compressed one in the machine's settings.",
                        disk.file_name
                    )));
                }
            };
            disk_sources.insert(disk.id, source);
        }
        for image in config.removable_images() {
            if !Path::new(&image.path).exists() {
                let name = Path::new(&image.path).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
                return Err(QemuError::Invalid(format!(
                    "The disk image “{name}” can't be found. Put it back, or eject it in the virtual machine's settings."
                )));
            }
        }
        if options.networks.len() != config.network_interfaces.len() {
            return Err(QemuError::Invalid("The machine's network cards weren't handed over with it.".into()));
        }
        if !bundle.efi_variable_store().exists() {
            installation
                .make_variable_store(&bundle.efi_variable_store())
                .map_err(|error| QemuError::DidNotStart(format!("Its UEFI variables couldn't be made: {error}")))?;
        }

        let restoring = options.saved_state.is_some();
        let header = options.saved_state.as_deref().map(SavedStateHeader::read).transpose()?;
        let attaches_tpm = command_line::attaches_tpm(&config, installation.supports_tpm(), header.as_ref().map(|header| header.has_tpm))?;
        let adapter = command_line::display_adapter(&config, installation, restoring)?;
        let gpu_folder = folder.join("gpu");
        let spice_socket = (adapter == DisplayAdapter::VirtioGpu3d).then(|| gpu_folder.join("display.sock"));
        if spice_socket.is_some() {
            crate::runtime::make_private(&gpu_folder).map_err(|error| QemuError::DidNotStart(error.to_string()))?;
        }
        let monitor_socket = folder.join("qmp.sock");
        let agent_socket = folder.join("agent.sock");
        for socket in [&monitor_socket, &agent_socket] {
            let _ = std::fs::remove_file(socket);
        }
        let command_line = CommandLine {
            config: &config,
            bundle: &bundle,
            installation,
            disk_sources,
            display: adapter,
            restores_saved_state: restoring,
            usb_ports: header.as_ref().map(|header| header.usb_ports.clone()).unwrap_or_default(),
            spice_socket: spice_socket.clone(),
            attaches_tpm,
            refresh_rate: options.refresh_rate,
            monitor_socket: monitor_socket.clone(),
            agent_socket: agent_socket.clone(),
            has_console: options.console.is_some(),
        };
        let arguments = command_line.arguments()?;
        let usb_ports = command_line.starting_usb_ports()?;
        let presses_key = command_line::boots_installer(&config, &bundle);

        // The lines, in the order the command line numbers them: the console, the network cards, the TPM.
        let console = match options.console {
            Some(console) => console,
            None => std::fs::File::open("/dev/null").map_err(|error| QemuError::DidNotStart(error.to_string()))?.into(),
        };
        let mut descriptors = vec![console];
        descriptors.extend(options.networks);
        // The TPM is up before QEMU, which starts it as soon as it is up itself.
        let mut tpm_child = None;
        if attaches_tpm {
            let (child, qemu_end) = tpm::launch(&installation.tpm_emulator(), &bundle)
                .map_err(|error| QemuError::DidNotStart(format!("Its TPM couldn't be started: {error}")))?;
            descriptors.push(qemu_end);
            tpm_child = Some(child);
        }
        let environment = match &spice_socket {
            Some(_) => installation.environment(&gpu_folder, options.direct_x.as_ref()),
            None => Default::default(),
        };
        let child = process::launch(process::Launch {
            program: &installation.program,
            arguments: &arguments,
            descriptors,
            log: &bundle.qemu_log(),
            pid_file: &bundle.qemu_pid_file(),
            directory: &bundle.logs(),
            environment,
        });
        let tpm_pid = tpm_child.as_ref().and_then(|child| child.id()).map(|pid| pid as i32);
        let child = match child {
            Ok(child) => child,
            Err(error) => {
                if let Some(pid) = tpm_pid {
                    process::kill(pid, libc::SIGKILL);
                }
                return Err(QemuError::DidNotStart(error.to_string()));
            }
        };
        let pid = child.id().map(|pid| pid as i32).unwrap_or_default();
        let gone = watch_child(child);
        if let Some(tpm_child) = tpm_child {
            drop(watch_child(tpm_child));
        }

        let record = Record {
            machine: config.id,
            name: config.name.clone(),
            bundle: bundle.path.clone(),
            pid,
            tpm_pid,
            adapter,
            state: QemuState::Held,
            usb_ports,
            drives: config.removable_images().to_vec(),
            has_tpm: attaches_tpm,
            audio: config.audio.output_enabled,
            network_count: config.network_interfaces.len(),
            saved_state: options.saved_state.clone(),
            presses_key: presses_key && !restoring,
            spice_socket,
        };
        // Written down at once: a service that starts while this one is still waiting for QEMU finds it.
        write_record(folder, &record);
        let opened = Self::open_lines(&monitor_socket, &agent_socket, pid, &gone).await;
        let (qmp, events, agent) = match opened {
            Ok(opened) => opened,
            Err(_) => {
                let reason = why_it_did_not_start(&bundle, pid, tpm_pid, &gone).await;
                let _ = std::fs::remove_dir_all(folder);
                return Err(QemuError::DidNotStart(reason));
            }
        };
        let machine = Self::new(config.id, folder, bundle, record, qmp, agent, gone);
        machine.watch(events);
        if let Err(error) = machine.finish_launch(&config, options.display).await {
            machine.stop(true).await;
            return Err(error);
        }
        Ok(machine)
    }

    /// Puts the display's client and the network cables in place, as the machine is configured.
    async fn finish_launch(&self, config: &MachineConfig, display: Option<OwnedFd>) -> Result<(), QemuError> {
        if let Some(display) = display
            && self.adapter() != DisplayAdapter::VirtioGpu3d
        {
            // The display's line, handed to QEMU over its machine protocol, which carries descriptors.
            self.qmp.execute_passing("getfd", Some(json!({"fdname": "screen"})), display.as_fd()).await?;
            self.qmp.execute("add_client", Some(json!({"protocol": "vnc", "fdname": "screen", "skipauth": true}))).await?;
        }
        // Every card is on the network, also one whose cable is out: QEMU drops what goes over a link
        // that is down, and plugging the cable in is a word to QEMU.
        for (index, interface) in config.network_interfaces.iter().enumerate() {
            if !interface.is_connected {
                self.qmp.execute("set_link", Some(json!({"name": command_line::network_device_id(index), "up": false}))).await?;
            }
        }
        Ok(())
    }

    async fn open_lines(
        monitor: &Path,
        agent: &Path,
        pid: i32,
        gone: &watch::Receiver<bool>,
    ) -> Result<(Arc<Qmp>, mpsc::UnboundedReceiver<QmpEvent>, Arc<AgentChannel>), QemuError> {
        let alive = {
            let gone = gone.clone();
            move || !*gone.borrow() && process::is_alive(pid)
        };
        let (qmp, events) = Qmp::connect(monitor, STARTUP_TIME, alive.clone()).await?;
        // QEMU listens on the agent's line by the time its machine protocol answers.
        let mut attempts = 0;
        let line = loop {
            match UnixStream::connect(agent).await {
                Ok(line) => break line,
                Err(_) if attempts < 250 && alive() => {
                    attempts += 1;
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                Err(_) => {
                    qmp.close().await;
                    return Err(QemuError::Disconnected);
                }
            }
        };
        Ok((qmp, events, AgentChannel::start(line)))
    }

    fn new(
        id: Id,
        folder: &Path,
        bundle: Bundle,
        record: Record,
        qmp: Arc<Qmp>,
        agent: Arc<AgentChannel>,
        gone: watch::Receiver<bool>,
    ) -> Arc<Machine> {
        let state = record.state;
        Arc::new(Machine {
            id,
            folder: folder.to_path_buf(),
            bundle,
            record: Mutex::new(record),
            qmp,
            agent: Mutex::new(Some(agent)),
            status: watch::channel((state, None)).0,
            gone,
            expects_exit: AtomicBool::new(false),
            shutdown_reason: Mutex::new(None),
            removals: Mutex::new(HashMap::new()),
            input: tokio::sync::Mutex::new(InputState::default()),
            battery: Mutex::new(None),
            battery_status: Mutex::new(None),
            tasks: Mutex::new(Vec::new()),
            frames: AtomicU64::new(0),
        })
    }

    /// Takes on a machine that an earlier service started, from the record in `folder`. When its QEMU has
    /// ended meanwhile, cleans up after it and says how it ended.
    pub async fn adopt(folder: &Path) -> Result<Arc<Machine>, Option<(Id, QemuExit)>> {
        let data = std::fs::read(folder.join(RECORD)).map_err(|_| None)?;
        let record: Record = serde_json::from_slice(&data).map_err(|_| None)?;
        let bundle = Bundle::new(record.bundle.clone());
        let is_its_qemu = !process::has_ended(record.pid)
            && process::arguments_of(record.pid).is_some_and(|arguments| process::is_qemu(&arguments, &record.machine.0));
        let opened = if is_its_qemu {
            let gone = watch_pid(record.pid);
            Self::open_lines(&folder.join("qmp.sock"), &folder.join("agent.sock"), record.pid, &gone).await.map(|opened| (opened, gone))
        } else {
            Err(QemuError::Disconnected)
        };
        let ((qmp, events, agent), gone) = match opened {
            Ok(opened) => opened,
            Err(_) => {
                // It ended while no service was there to hear why.
                if is_its_qemu {
                    process::kill(record.pid, libc::SIGKILL);
                    process::wait_gone(record.pid, Duration::from_secs(5)).await;
                }
                tpm::end_leftover(&bundle).await;
                let _ = std::fs::remove_file(bundle.qemu_pid_file());
                let exit = QemuExit { reason: None, expected: false, message: complaint(&bundle, record.tpm_pid) };
                let _ = std::fs::remove_dir_all(folder);
                return Err(Some((record.machine, exit)));
            }
        };
        let mut record = record;
        if let Ok(status) = qmp.execute("query-status", None).await {
            record.state = match status.get("status").and_then(Value::as_str) {
                Some("prelaunch" | "inmigrate") => QemuState::Held,
                _ if status.get("running").and_then(Value::as_bool) == Some(true) => QemuState::Running,
                _ => QemuState::Paused,
            };
        }
        let id = record.machine;
        let state = record.state;
        let machine = Self::new(id, folder, bundle, record, qmp, agent, gone);
        machine.save_record();
        machine.watch(events);
        if state != QemuState::Held {
            machine.start_battery().await;
        }
        Ok(machine)
    }

    // MARK: What it is

    pub fn name(&self) -> String {
        lock(&self.record).name.clone()
    }

    pub fn pid(&self) -> i32 {
        lock(&self.record).pid
    }

    pub fn adapter(&self) -> DisplayAdapter {
        lock(&self.record).adapter
    }

    pub fn state(&self) -> QemuState {
        self.status.borrow().0
    }

    /// How QEMU ended, once it has.
    pub fn exit(&self) -> Option<QemuExit> {
        self.status.borrow().1.clone()
    }

    /// Changes when the state does, and when QEMU ends.
    pub fn subscribe(&self) -> watch::Receiver<(QemuState, Option<QemuExit>)> {
        self.status.subscribe()
    }

    pub fn summary(&self) -> QemuMachine {
        let record = lock(&self.record);
        QemuMachine {
            machine: record.machine,
            name: record.name.clone(),
            bundle: record.bundle.to_string_lossy().into_owned(),
            pid: record.pid,
            state: self.state(),
            adapter: record.adapter,
            can_save_state: record.adapter != DisplayAdapter::VirtioGpu3d,
            spice_socket: record.spice_socket.as_ref().map(|socket| socket.to_string_lossy().into_owned()),
        }
    }

    fn set_state(&self, state: QemuState) {
        self.status.send_if_modified(|status| {
            if status.0 == state || status.0 == QemuState::Exited {
                return false;
            }
            status.0 = state;
            true
        });
        lock(&self.record).state = state;
        self.save_record();
    }

    fn save_record(&self) {
        write_record(&self.folder, &lock(&self.record));
    }

    fn running(&self) -> Result<(), QemuError> {
        match self.state() {
            QemuState::Exited => Err(QemuError::NotRunning(self.name())),
            _ => Ok(()),
        }
    }

    // MARK: Its life

    /// Lets a held guest run: from its saved state, if it was started with one.
    pub async fn resume_held(self: &Arc<Self>) -> Result<(), QemuError> {
        if self.state() != QemuState::Held {
            return Err(QemuError::Invalid(format!("“{}” isn't held.", self.name())));
        }
        let saved_state = lock(&self.record).saved_state.clone();
        if let Some(saved_state) = saved_state {
            self.qmp.execute("migrate-incoming", Some(json!({"channels": migration_channels(&saved_state)}))).await?;
            self.wait_for_migration().await?;
            self.plug_in_audio().await;
            lock(&self.record).saved_state = None;
        }
        self.start_battery().await;
        self.qmp.execute("cont", None).await?;
        self.set_state(QemuState::Running);
        let presses_key = std::mem::take(&mut lock(&self.record).presses_key);
        if presses_key {
            self.press_key_for_installer();
        }
        Ok(())
    }

    /// An installer disc's firmware asks for a key before it starts the installer, and starts from the
    /// empty disk when none comes. A few seconds of pressing the space bar is that key.
    fn press_key_for_installer(self: &Arc<Self>) {
        let machine = Arc::downgrade(self);
        self.keep(tokio::spawn(async move {
            for _ in 0..20 {
                tokio::time::sleep(Duration::from_millis(500)).await;
                let Some(machine) = machine.upgrade() else { return };
                if machine.state() != QemuState::Running {
                    return;
                }
                let _ = machine.qmp.execute("send-key", Some(json!({"keys": [{"type": "qcode", "data": "spc"}]}))).await;
            }
        }));
    }

    /// Asks the guest to shut down, as its power button does.
    pub async fn power_down(&self) -> Result<(), QemuError> {
        self.running()?;
        self.qmp.execute("system_powerdown", None).await.map(drop)
    }

    /// Ends QEMU: asks it to quit and gives it a few seconds, or with `force` ends it at once. Returns once
    /// it has ended.
    pub async fn stop(&self, force: bool) {
        self.expects_exit.store(true, Ordering::SeqCst);
        if !*self.gone.borrow() {
            let pid = self.pid();
            if !force {
                let _ = tokio::time::timeout(Duration::from_secs(2), self.qmp.execute("quit", None)).await;
            }
            if force || !self.wait_gone(Duration::from_secs(5)).await {
                process::kill(pid, libc::SIGKILL);
                self.wait_gone(Duration::from_secs(5)).await;
            }
        }
        let mut status = self.subscribe();
        let _ = tokio::time::timeout(Duration::from_secs(10), status.wait_for(|status| status.0 == QemuState::Exited)).await;
    }

    async fn wait_gone(&self, timeout: Duration) -> bool {
        let mut gone = self.gone.clone();
        tokio::time::timeout(timeout, gone.wait_for(|gone| *gone)).await.is_ok_and(|result| result.is_ok())
    }

    pub async fn pause(&self) -> Result<(), QemuError> {
        self.running()?;
        self.qmp.execute("stop", None).await?;
        self.set_state(QemuState::Paused);
        Ok(())
    }

    pub async fn resume(&self) -> Result<(), QemuError> {
        self.running()?;
        self.refresh_battery().await;
        self.qmp.execute("cont", None).await?;
        self.set_state(QemuState::Running);
        Ok(())
    }

    /// Saves the memory of a paused guest to `path`, with the header a restore needs.
    pub async fn save(&self, path: &Path) -> Result<(), QemuError> {
        self.running()?;
        if self.adapter() == DisplayAdapter::VirtioGpu3d {
            return Err(QemuError::Refused("The GPU cannot save running graphics state.".into()));
        }
        let _ = std::fs::remove_file(path);
        let audio = lock(&self.record).audio;
        // QEMU can't save its USB sound card, which is unplugged for the moment saving takes.
        if audio {
            self.remove_device(command_line::AUDIO_DEVICE_ID).await;
        }
        let result = async {
            self.qmp.execute("migrate", Some(json!({"channels": migration_channels(path)}))).await?;
            self.wait_for_migration().await?;
            let header = {
                let record = lock(&self.record);
                SavedStateHeader { usb_ports: record.usb_ports.clone(), has_tpm: record.has_tpm }
            };
            header.write_into(path)
        }
        .await;
        self.plug_in_audio().await;
        result
    }

    async fn plug_in_audio(&self) {
        if lock(&self.record).audio {
            // A machine without sound is still of use.
            let _ = self.qmp.execute("device_add", Some(command_line::audio_device())).await;
        }
    }

    async fn wait_for_migration(&self) -> Result<(), QemuError> {
        loop {
            let status = self.qmp.execute("query-migrate", None).await?;
            match status.get("status").and_then(Value::as_str) {
                Some("completed") => return Ok(()),
                Some("failed" | "cancelled") => {
                    let reason =
                        status.get("error-desc").and_then(Value::as_str).unwrap_or("The machine's memory couldn't be saved or read back.");
                    return Err(QemuError::Refused(reason.to_string()));
                }
                _ => tokio::time::sleep(Duration::from_millis(100)).await,
            }
        }
    }

    // MARK: Devices

    /// Plugs the virtual network cable of the card at `index` in, or pulls it.
    pub async fn set_link(&self, index: usize, connected: bool) -> Result<(), QemuError> {
        self.running()?;
        if index >= lock(&self.record).network_count {
            return Err(QemuError::Invalid(format!("“{}” has no network card {index}.", self.name())));
        }
        self.qmp.execute("set_link", Some(json!({"name": command_line::network_device_id(index), "up": connected}))).await.map(drop)
    }

    /// Plugs a disc or disk image into the running guest as a USB drive.
    pub async fn attach_image(&self, image: RemovableImage) -> Result<(), QemuError> {
        self.running()?;
        let port = {
            let record = lock(&self.record);
            command_line::free_usb_port(record.usb_ports.values())
        };
        let Some(port) = port else {
            let name = Path::new(&image.path).file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
            return Err(QemuError::Invalid(format!("“{}” has no free USB port for “{name}”. Eject another drive first.", self.name())));
        };
        let device = command_line::image_device_id(&image);
        let node = command_line::image_node_name(&image.id);
        self.qmp.execute("blockdev-add", Some(command_line::image_node(&image))).await?;
        let plugged = async {
            for device in command_line::image_devices(&image, port) {
                self.qmp.execute("device_add", Some(device)).await?;
            }
            // A drive for discs plugged in while the guest runs waits for its disc before the guest sees
            // it, and is told when it has one.
            if crate::config::is_disc_image(&image.path) {
                self.qmp
                    .execute(
                        "qom-set",
                        Some(json!({"path": format!("/machine/peripheral/{device}"), "property": "attached", "value": true})),
                    )
                    .await?;
            }
            Ok::<(), QemuError>(())
        }
        .await;
        if let Err(error) = plugged {
            let _ = self.qmp.execute("device_del", Some(json!({"id": device}))).await;
            let _ = self.qmp.execute("blockdev-del", Some(json!({"node-name": node}))).await;
            return Err(error);
        }
        {
            let mut record = lock(&self.record);
            record.usb_ports.insert(image.id, port);
            record.drives.retain(|drive| drive.id != image.id);
            record.drives.push(image);
        }
        self.save_record();
        Ok(())
    }

    /// Unplugs a drive the guest started with or that was plugged in later.
    pub async fn detach_image(&self, id: Id) -> Result<(), QemuError> {
        self.running()?;
        let Some(image) = lock(&self.record).drives.iter().find(|drive| drive.id == id).cloned() else { return Ok(()) };
        self.remove_device(&command_line::image_device_id(&image)).await;
        let _ = self.qmp.execute("blockdev-del", Some(json!({"node-name": command_line::image_node_name(&id)}))).await;
        {
            let mut record = lock(&self.record);
            record.drives.retain(|drive| drive.id != id);
            record.usb_ports.remove(&id);
        }
        self.save_record();
        Ok(())
    }

    /// Unplugs a device, and returns once QEMU says the guest has let go of it, or after a while.
    async fn remove_device(&self, device: &str) {
        let (done, wait) = oneshot::channel();
        let is_under_way = {
            let mut removals = lock(&self.removals);
            let waiting = removals.entry(device.to_string()).or_default();
            waiting.push(done);
            waiting.len() > 1
        };
        if !is_under_way && self.qmp.execute("device_del", Some(json!({"id": device}))).await.is_err() {
            self.finish_removal(device);
        }
        // A guest that never lets go doesn't keep anyone waiting for long, nor the machine with them.
        if tokio::time::timeout(Duration::from_secs(10), wait).await.is_err() {
            self.finish_removal(device);
        }
    }

    fn finish_removal(&self, device: &str) {
        for waiting in lock(&self.removals).remove(device).unwrap_or_default() {
            let _ = waiting.send(());
        }
    }

    // MARK: The guest's agent

    /// Opens a connection to `port` in the guest, over the agent's line.
    pub async fn connect(&self, port: u32) -> Result<UnixStream, QemuError> {
        self.running()?;
        let agent = lock(&self.agent).clone().ok_or(QemuError::Disconnected)?;
        Ok(agent.connect(port, Duration::from_secs(5)).await?)
    }

    // MARK: The display, the mouse and the keyboard

    /// What the display shows: its size, and four bytes a pixel, blue first.
    pub async fn frame(&self) -> Result<(u32, u32, Vec<u8>), QemuError> {
        self.running()?;
        if self.adapter() == DisplayAdapter::VirtioGpu3d {
            return Err(QemuError::Unavailable(
                "This machine draws its display with the GPU, which the service can't take a picture of.".into(),
            ));
        }
        let file = self.folder.join(format!("frame-{}.ppm", self.frames.fetch_add(1, Ordering::Relaxed)));
        let taken = self.qmp.execute("screendump", Some(json!({"filename": file.to_string_lossy()}))).await;
        let data = std::fs::read(&file);
        let _ = std::fs::remove_file(&file);
        taken.map_err(|_| QemuError::NothingShown)?;
        let (width, height, pixels) = data
            .ok()
            .and_then(|data| input::ppm_to_bgrx(&data))
            .filter(|(width, height, _)| *width > 0 && *height > 0)
            .ok_or(QemuError::NothingShown)?;
        self.input.lock().await.size = Some((i64::from(width), i64::from(height)));
        Ok((width, height, pixels))
    }

    /// Uses the machine's own mouse. Places are in the display's pixels. `size` is the display's, for one
    /// the service can't take a picture of.
    pub async fn pointer(&self, pointer: &Pointer, size: Option<Size>) -> Result<(), QemuError> {
        self.running()?;
        let known = self.input.lock().await.size;
        let (width, height) = match (size, known) {
            (Some(size), _) => (i64::from(size.width), i64::from(size.height)),
            (None, _) if self.adapter() == DisplayAdapter::VirtioGpu3d => {
                return Err(QemuError::Invalid("The request doesn't say how large the display is.".into()));
            }
            // The size of what the guest shows now, which may have changed since the last picture.
            (None, _) => {
                self.frame().await.map(|(width, height, _)| (i64::from(width), i64::from(height))).or_else(|error| known.ok_or(error))?
            }
        };
        let steps = input::pointer_steps(pointer, width, height)?;
        self.play(&steps, (width, height)).await
    }

    /// Presses keys of the machine's own keyboard, which has the keys of a US keyboard.
    pub async fn keys(&self, keys: &Keys) -> Result<(), QemuError> {
        self.running()?;
        let steps = input::key_steps(keys)?;
        self.play(&steps, (1, 1)).await
    }

    async fn play(&self, steps: &[InputStep], (width, height): (i64, i64)) -> Result<(), QemuError> {
        let mut input = self.input.lock().await;
        for step in steps {
            match *step {
                InputStep::Pause(pause) => tokio::time::sleep(pause).await,
                InputStep::Key { code, down } => {
                    let event = json!({"type": "key", "data": {"down": down, "key": {"type": "number", "data": code}}});
                    self.qmp.execute("input-send-event", Some(json!({"events": [event]}))).await?;
                }
                InputStep::Pointer { x, y, buttons } => {
                    // QEMU scales a place on the display as its VNC server does.
                    let scale = |value: i64, size: i64| value * 0x7fff / size.max(1);
                    let mut events = vec![
                        json!({"type": "abs", "data": {"axis": "x", "value": scale(x, width)}}),
                        json!({"type": "abs", "data": {"axis": "y", "value": scale(y, height)}}),
                    ];
                    for (bit, name) in BUTTON_NAMES {
                        if (input.buttons ^ buttons) & bit != 0 {
                            events.push(json!({"type": "btn", "data": {"down": buttons & bit != 0, "button": name}}));
                        }
                    }
                    input.buttons = buttons;
                    self.qmp.execute("input-send-event", Some(json!({"events": events}))).await?;
                }
            }
        }
        Ok(())
    }

    // MARK: QEMU's own word

    fn keep(&self, task: JoinHandle<()>) {
        let mut tasks = lock(&self.tasks);
        tasks.retain(|task| !task.is_finished());
        tasks.push(task);
    }

    /// Hears QEMU's events until its line closes, then waits for its process to go, and says how it ended.
    fn watch(self: &Arc<Self>, mut events: mpsc::UnboundedReceiver<QmpEvent>) {
        let machine = Arc::downgrade(self);
        let mut gone = self.gone.clone();
        self.keep(tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                let Some(machine) = machine.upgrade() else { return };
                machine.handle(event);
            }
            let _ = gone.wait_for(|gone| *gone).await;
            if let Some(machine) = machine.upgrade() {
                machine.did_exit().await;
            }
        }));
    }

    fn handle(&self, event: QmpEvent) {
        match event.name.as_str() {
            "SHUTDOWN" => *lock(&self.shutdown_reason) = event.data.get("reason").and_then(Value::as_str).map(str::to_string),
            "DEVICE_DELETED" => {
                if let Some(device) = event.data.get("device").and_then(Value::as_str) {
                    self.finish_removal(device);
                }
            }
            "VSERPORT_CHANGE" => {
                // The agent's side of its line was closed, or opened anew: what was open on it is gone.
                if let Some(agent) = lock(&self.agent).clone() {
                    if event.data.get("open").and_then(Value::as_bool) == Some(false) {
                        agent.agent_left();
                    } else {
                        agent.agent_arrived();
                    }
                }
            }
            _ => {}
        }
    }

    /// QEMU has ended and its line has closed: what it said last, its reason for the guest going down
    /// among it, has been heard by then.
    async fn did_exit(&self) {
        self.stop_battery();
        if let Some(agent) = lock(&self.agent).take() {
            agent.close();
        }
        for waiting in lock(&self.removals).drain().flat_map(|(_, waiting)| waiting) {
            let _ = waiting.send(());
        }
        let tpm_pid = lock(&self.record).tpm_pid;
        // It ends by itself once QEMU has.
        if let Some(pid) = tpm_pid
            && !process::wait_gone(pid, Duration::from_secs(2)).await
        {
            process::kill(pid, libc::SIGKILL);
            process::wait_gone(pid, Duration::from_secs(5)).await;
        }
        for file in [self.bundle.qemu_pid_file(), self.bundle.tpm_pid_file()] {
            let _ = std::fs::remove_file(file);
        }
        let exit = QemuExit {
            reason: lock(&self.shutdown_reason).clone(),
            expected: self.expects_exit.load(Ordering::SeqCst),
            message: complaint(&self.bundle, None),
        };
        let _ = std::fs::remove_dir_all(&self.folder);
        self.status.send_replace((QemuState::Exited, Some(exit)));
    }

    /// Lets go of QEMU without ending it, for the next service to take on: the service is stopping.
    pub async fn detach(&self) {
        for task in lock(&self.tasks).drain(..) {
            task.abort();
        }
        self.stop_battery();
        if let Some(agent) = lock(&self.agent).take() {
            agent.close();
        }
        self.qmp.close().await;
    }

    // MARK: The battery

    /// Passes the host's battery on while QEMU is alive, paused too, if this QEMU has the device for it.
    async fn start_battery(self: &Arc<Self>) {
        if lock(&self.battery).is_some() {
            return;
        }
        let properties = self.qmp.execute("qom-list", Some(json!({"path": "/machine"}))).await.unwrap_or(Value::Null);
        let has_battery = properties.as_array().is_some_and(|properties| {
            properties.iter().any(|property| property.get("name").and_then(Value::as_str) == Some("battery-status"))
        });
        if !has_battery {
            return;
        }
        self.refresh_battery().await;
        let machine = Arc::downgrade(self);
        *lock(&self.battery) = Some(tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                let Some(machine) = machine.upgrade() else { return };
                machine.refresh_battery().await;
            }
        }));
    }

    async fn refresh_battery(&self) {
        let status = HostBattery::current_status();
        if *lock(&self.battery_status) == Some(status) {
            return;
        }
        let set = json!({"path": "/machine", "property": "battery-status", "value": status});
        // The last status QEMU took is kept, so that a failure is tried again.
        if self.qmp.execute("qom-set", Some(set)).await.is_ok() {
            *lock(&self.battery_status) = Some(status);
        }
    }

    fn stop_battery(&self) {
        if let Some(task) = lock(&self.battery).take() {
            task.abort();
        }
    }
}

/// Writes what the service knows of a machine into its runtime folder, whole or not at all.
fn write_record(folder: &Path, record: &Record) {
    let data = serde_json::to_vec_pretty(record).unwrap_or_default();
    let staging = folder.join(format!("{RECORD}.new"));
    if std::fs::write(&staging, data).is_ok() {
        let _ = std::fs::rename(staging, folder.join(RECORD));
    }
}

/// Where the machine's memory goes, or comes from: a file, given by its name rather than in a URI, which a
/// comma in the path would cut short. It starts after SwiftVM's header.
fn migration_channels(path: &Path) -> Value {
    json!([{"channel-type": "main", "addr": {"transport": "file", "filename": path.to_string_lossy(), "offset": saved_state::SIZE}}])
}

/// Becomes `true` once `child` has ended, which it collects.
fn watch_child(mut child: tokio::process::Child) -> watch::Receiver<bool> {
    let (gone, receiver) = watch::channel(false);
    tokio::spawn(async move {
        let _ = child.wait().await;
        gone.send_replace(true);
    });
    receiver
}

/// Becomes `true` once the process `pid`, which isn't this one's child, has ended.
fn watch_pid(pid: i32) -> watch::Receiver<bool> {
    let (gone, receiver) = watch::channel(false);
    tokio::spawn(async move {
        while !process::has_ended(pid) {
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        gone.send_replace(true);
    });
    receiver
}

/// What QEMU said last that tells what went wrong, or its TPM, when that is what went wrong.
fn complaint(bundle: &Bundle, tpm_pid: Option<i32>) -> Option<String> {
    // QEMU only says it lost its TPM. The TPM says why.
    if tpm_pid.is_some()
        && let Some(complaint) = tpm::complaint(&process::last_output(&bundle.tpm_log()))
    {
        return Some(format!("Its TPM said: {complaint}"));
    }
    process::complaint(&process::last_output(&bundle.qemu_log()))
}

/// Why QEMU didn't start: what it said as it ended, which it says once it has.
async fn why_it_did_not_start(bundle: &Bundle, pid: i32, tpm_pid: Option<i32>, gone: &watch::Receiver<bool>) -> String {
    let mut gone = gone.clone();
    if tokio::time::timeout(Duration::from_secs(2), gone.wait_for(|gone| *gone)).await.is_err() {
        process::kill(pid, libc::SIGKILL);
        let _ = tokio::time::timeout(Duration::from_secs(5), gone.wait_for(|gone| *gone)).await;
    }
    if let Some(tpm_pid) = tpm_pid
        && !process::wait_gone(tpm_pid, Duration::from_secs(2)).await
    {
        process::kill(tpm_pid, libc::SIGKILL);
    }
    let _ = std::fs::remove_file(bundle.qemu_pid_file());
    match complaint(bundle, tpm_pid) {
        Some(complaint) if complaint.starts_with("Its TPM") => complaint,
        Some(complaint) => format!("It said: {complaint}"),
        None => "It ended without saying why.".into(),
    }
}
