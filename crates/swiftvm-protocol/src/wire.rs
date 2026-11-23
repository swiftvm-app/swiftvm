//! The messages of the control socket, as the app's Swift `JSONEncoder` writes and reads them: one JSON
//! document per line, optional fields left out when empty, dates as seconds since 2001, and UUIDs in
//! capitals.

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::text::shown_line;

// MARK: - Values with Swift's own coding

/// A UUID, written in capitals the way Swift's `UUID` writes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Id(pub uuid::Uuid);

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut buffer = uuid::Uuid::encode_buffer();
        f.write_str(self.0.hyphenated().encode_upper(&mut buffer))
    }
}

impl Serialize for Id {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Id {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        uuid::Uuid::parse_str(&text).map(Id).map_err(serde::de::Error::custom)
    }
}

/// A moment, as Swift's `Date` is coded by default: seconds since the first instant of 2001, in UTC.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SwiftDate(pub f64);

impl SwiftDate {
    /// Seconds from 1970 to 2001.
    pub const UNIX_OFFSET: f64 = 978_307_200.0;

    pub fn unix_seconds(self) -> f64 {
        self.0 + Self::UNIX_OFFSET
    }
}

/// Bytes, as Swift's `Data` is coded: in Base64.
mod base64_data {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(bytes) => serializer.serialize_str(&STANDARD.encode(bytes)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error> {
        let text = Option::<String>::deserialize(deserializer)?;
        text.map(|text| STANDARD.decode(text).map_err(serde::de::Error::custom)).transpose()
    }
}

// MARK: - Requests

/// What a request asks of the app. Each has the name it goes by on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Command {
    #[default]
    List,
    Start,
    /// Ask the guest to shut down and wait until it has.
    Stop,
    ForceStop,
    Suspend,
    Pause,
    Resume,
    Restart,
    /// Show the machine's window.
    Open,
    Create,
    Delete,
    /// Quit the app. Refused while a machine is running, and while one is being created unless
    /// `cancelsCreations` is set.
    Quit,
    /// Throw away a suspended machine's saved memory, so that it starts up fresh.
    DiscardState,
    Share,
    Unshare,
    Info,
    Attach,
    Eject,
    Resize,
    Compression,
    Clone,
    Move,
    Snapshot,
    Snapshots,
    Revert,
    DeleteSnapshot,
    RenameSnapshot,
    Templates,
    SaveTemplate,
    DeleteTemplate,
    RenameTemplate,
    Forward,
    Unforward,
    /// The machine's serial console. After the answer the connection carries its bytes both ways.
    Console,
    /// A port in the guest over the machine's socket device. After the answer the connection carries
    /// that conversation.
    Vsock,
    Plug,
    Unplug,
    NetworkInterfaces,
    Network,
    InstallTools,
    ShareClipboard,
    UsbList,
    UsbAttach,
    UsbDetach,
    UsbAuto,
    Scripts,
    Wait,
    /// A job for the guest tools. After the answer the connection carries the job's frames.
    Job,
    /// Steps on the machine's desktop. After the answer the connection carries a `ControlOutcome` in
    /// frames.
    Control,
    Automation,
    AllowAccessibility,
}

impl Command {
    pub const ALL: [Command; 51] = [
        Command::List,
        Command::Start,
        Command::Stop,
        Command::ForceStop,
        Command::Suspend,
        Command::Pause,
        Command::Resume,
        Command::Restart,
        Command::Open,
        Command::Create,
        Command::Delete,
        Command::Quit,
        Command::DiscardState,
        Command::Share,
        Command::Unshare,
        Command::Info,
        Command::Attach,
        Command::Eject,
        Command::Resize,
        Command::Compression,
        Command::Clone,
        Command::Move,
        Command::Snapshot,
        Command::Snapshots,
        Command::Revert,
        Command::DeleteSnapshot,
        Command::RenameSnapshot,
        Command::Templates,
        Command::SaveTemplate,
        Command::DeleteTemplate,
        Command::RenameTemplate,
        Command::Forward,
        Command::Unforward,
        Command::Console,
        Command::Vsock,
        Command::Plug,
        Command::Unplug,
        Command::NetworkInterfaces,
        Command::Network,
        Command::InstallTools,
        Command::ShareClipboard,
        Command::UsbList,
        Command::UsbAttach,
        Command::UsbDetach,
        Command::UsbAuto,
        Command::Scripts,
        Command::Wait,
        Command::Job,
        Command::Control,
        Command::Automation,
        Command::AllowAccessibility,
    ];

    /// The name the command goes by on the wire.
    pub fn raw_value(self) -> String {
        match serde_json::to_value(self) {
            Ok(serde_json::Value::String(name)) => name,
            _ => unreachable!("a command is coded as its name"),
        }
    }

    /// The command that goes by `name` on the wire.
    pub fn from_raw_value(name: &str) -> Option<Command> {
        Self::ALL.into_iter().find(|command| command.raw_value() == name)
    }

    /// Whether a successful answer is followed by a byte stream instead of further requests.
    pub fn opens_stream(self) -> bool {
        matches!(self, Command::Console | Command::Vsock | Command::Job | Command::Control)
    }
}

/// A request sent to the running app over its control socket.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlRequest {
    pub command: Command,
    /// Name, SSH alias or UUID of the machine the command applies to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub create: Option<CreateParameters>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub share: Option<ShareParameters>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drive: Option<DriveParameters>,
    /// The name for a copy, a snapshot or a template, or the new name of a snapshot or template.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disk_gigabytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forward: Option<ForwardParameters>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cancels_creations: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uses_disc: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_on: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usb_device: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job: Option<GuestJob>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub control: Option<ControlCall>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bridged_interface_identifier: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mac_address: Option<String>,
}

impl ControlRequest {
    /// The longest `wait` waits: a day.
    pub const LONGEST_WAIT: f64 = 86_400.0;

    pub fn new(command: Command) -> Self {
        ControlRequest { command, ..Default::default() }
    }

    pub fn for_machine(command: Command, machine: impl Into<String>) -> Self {
        ControlRequest { command, machine: Some(machine.into()), ..Default::default() }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForwardParameters {
    pub host_port: u16,
    /// `None` means the same port as on the host.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guest_port: Option<u16>,
    pub udp: bool,
    /// Accept connections from other devices on the network, not only from this Mac.
    pub allows_other_devices: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveParameters {
    /// Absolute host path of the image. For `eject`, a file name is enough.
    pub path: String,
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareParameters {
    /// Absolute host path of the folder.
    pub path: String,
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateParameters {
    /// `macos`, `windows`, or a Linux catalog identifier such as `ubuntu-26.04`. Empty for a machine
    /// made from a template.
    pub distribution: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_gigabytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disk_gigabytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restore_image_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installer_path: Option<String>,
    /// Setup scripts by name, or by absolute path: what starts with a `/`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scripts: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rosetta: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nested_virtualization: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compressed: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accelerates_graphics: Option<bool>,
    #[serde(rename = "installsSSHKey", skip_serializing_if = "Option::is_none")]
    pub installs_ssh_key: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template: Option<String>,
    pub start: bool,
}

impl CreateParameters {
    pub fn new(distribution: impl Into<String>) -> Self {
        CreateParameters {
            distribution: distribution.into(),
            name: None,
            cpu_count: None,
            memory_gigabytes: None,
            disk_gigabytes: None,
            user: None,
            password: None,
            restore_image_path: None,
            installer_path: None,
            scripts: None,
            location: None,
            rosetta: None,
            nested_virtualization: None,
            compressed: None,
            accelerates_graphics: None,
            installs_ssh_key: None,
            template: None,
            start: true,
        }
    }
}

// MARK: - Responses

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The machines the command touched, or all of them for `list`.
    #[serde(default)]
    pub machines: Vec<MachineSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshots: Option<Vec<SnapshotSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usb_devices: Option<Vec<UsbDeviceSummary>>,
    /// Something for the person at the terminal to read once the command has done its part.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub setup_scripts: Option<Vec<SetupScriptSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub templates: Option<Vec<TemplateSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub creations: Option<Vec<CreationSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network_interfaces: Option<Vec<NetworkInterface>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NetworkInterface {
    pub identifier: String,
    pub name: String,
}

/// What the app knows about one machine.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineSummary {
    pub id: Id,
    pub name: String,
    pub state: String,
    pub system: String,
    /// `macOS`, `linux` or `windows`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub family: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ssh_alias: Option<String>,
    pub cpu_count: i64,
    pub memory_size: u64,
    pub disk_allocated: u64,
    pub disk_capacity: u64,
    /// Only filled in for `info`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<MachineDetails>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<MachineUsage>,
}

/// What a running machine takes of this Mac.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineUsage {
    /// Processor time, in percent of one core: a guest that keeps two cores busy is at 200.
    pub cpu_percent: f64,
    pub memory_bytes: u64,
}

impl MachineUsage {
    /// `23.4%`: one decimal, as Activity Monitor shows it.
    pub fn percent(value: f64) -> String {
        if !value.is_finite() {
            return "-".into();
        }
        format!("{:.1}%", value.max(0.0))
    }
}

/// A machine the app is still creating, or failed to create.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreationSummary {
    pub name: String,
    pub system: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fraction: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// The parts of a machine that don't fit in a table row.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineDetails {
    pub location: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mac_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bridged_interface_identifier: Option<String>,
    pub drives: Vec<Drive>,
    pub shared_folders: Vec<Folder>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forwards: Option<Vec<Forward>>,
    pub snapshot_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guest_tools: Option<GuestTools>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shares_clipboard: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usb_devices: Option<Vec<UsbDeviceSummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usb_auto_connect: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub setup: Option<Setup>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub automation: Option<Automation>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Drive {
    pub path: String,
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub name: String,
    pub path: String,
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Forward {
    pub host_port: u16,
    pub guest_port: u16,
    pub udp: bool,
    pub allows_other_devices: bool,
    /// `listening`, `starting`, why the port couldn't be opened, or `None` while the machine isn't running.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Automation {
    pub is_allowed: bool,
    /// What the connected guest tools do: `exec`, `screen`, `input`, `accessibility`.
    pub features: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Setup {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// `pending`, `running`, `finished` or `failed`.
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GuestTools {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kernel: Option<String>,
}

/// A setup script: something a new Linux machine can be set up with, such as a desktop.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupScriptSummary {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    pub systems: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minimum_memory_gigabytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minimum_disk_gigabytes: Option<i64>,
    pub is_built_in: bool,
}

/// A USB device that this Mac has given the app.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsbDeviceSummary {
    pub id: u64,
    pub name: String,
    /// Vendor and product, as in `0781:5581`.
    pub identifier: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub manufacturer: Option<String>,
    #[serde(rename = "serialNumber", skip_serializing_if = "Option::is_none")]
    pub serial_number: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotSummary {
    pub id: Id,
    pub name: String,
    pub created_at: SwiftDate,
    /// Going back to it resumes the guest where it was instead of booting it.
    pub includes_memory: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateSummary {
    pub id: Id,
    pub name: String,
    pub created_at: SwiftDate,
    pub system: String,
    pub cpu_count: i64,
    pub memory_size: u64,
    pub disk_allocated: u64,
    pub disk_capacity: u64,
}

// MARK: - Guest jobs

/// Something the guest tools do in the guest. A client only ever sends commands to run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum GuestJob {
    Exec(Exec),
}

/// A command to run. No shell reads it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Exec {
    pub arguments: Vec<String>,
    /// The account to run it as, `root` for one. Without one, whoever is logged in at the screen.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    /// Where to run it. Without one, the account's home folder.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub environment: Option<BTreeMap<String, String>>,
}

/// How a job ended, as the payload of its last frame.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct JobEnd {
    /// The exit status of a command that ran to its end, and zero for any other job that worked out.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signal: Option<i32>,
    /// What went wrong, in the agent's words.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl JobEnd {
    pub fn success() -> Self {
        JobEnd { status: Some(0), ..Default::default() }
    }

    pub fn failure(error: impl Into<String>) -> Self {
        JobEnd { error: Some(error.into()), ..Default::default() }
    }

    /// `error` made fit to show: one line of no more than a few hundred characters.
    pub fn shown_error(&self) -> Option<String> {
        let error = self.error.as_ref()?;
        let line = shown_line(error, 500);
        Some(if line.is_empty() { "The guest tools gave up, without saying why.".into() } else { line })
    }
}

// MARK: - Desktop control

/// What `swiftvm control` and `swiftvm mcp` ask of a machine's desktop: steps done in order, stopping at
/// the first that fails.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct ControlCall {
    pub steps: Vec<ControlStep>,
}

/// What a step acts on: a number from the last look, what it says, an author id, or a place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "TargetCoding", into = "TargetCoding")]
pub enum ControlTarget {
    Number(i64),
    Text(String),
    Id(String),
    Point { x: i64, y: i64 },
}

/// How Swift codes an enum with associated values: unlabelled ones as `_0`.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum TargetCoding {
    Number {
        #[serde(rename = "_0")]
        value: i64,
    },
    Text {
        #[serde(rename = "_0")]
        value: String,
    },
    Id {
        #[serde(rename = "_0")]
        value: String,
    },
    Point {
        x: i64,
        y: i64,
    },
}

impl From<TargetCoding> for ControlTarget {
    fn from(coding: TargetCoding) -> Self {
        match coding {
            TargetCoding::Number { value } => ControlTarget::Number(value),
            TargetCoding::Text { value } => ControlTarget::Text(value),
            TargetCoding::Id { value } => ControlTarget::Id(value),
            TargetCoding::Point { x, y } => ControlTarget::Point { x, y },
        }
    }
}

impl From<ControlTarget> for TargetCoding {
    fn from(target: ControlTarget) -> Self {
        match target {
            ControlTarget::Number(value) => TargetCoding::Number { value },
            ControlTarget::Text(value) => TargetCoding::Text { value },
            ControlTarget::Id(value) => TargetCoding::Id { value },
            ControlTarget::Point { x, y } => TargetCoding::Point { x, y },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Look,
    Click,
    Move,
    Drag,
    Scroll,
    Type,
    Key,
    Set,
    Focus,
    Wait,
    Screenshot,
    Open,
    Clipboard,
}

impl Action {
    pub const ALL: [Action; 13] = [
        Action::Look,
        Action::Click,
        Action::Move,
        Action::Drag,
        Action::Scroll,
        Action::Type,
        Action::Key,
        Action::Set,
        Action::Focus,
        Action::Wait,
        Action::Screenshot,
        Action::Open,
        Action::Clipboard,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Action::Look => "look",
            Action::Click => "click",
            Action::Move => "move",
            Action::Drag => "drag",
            Action::Scroll => "scroll",
            Action::Type => "type",
            Action::Key => "key",
            Action::Set => "set",
            Action::Focus => "focus",
            Action::Wait => "wait",
            Action::Screenshot => "screenshot",
            Action::Open => "open",
            Action::Clipboard => "clipboard",
        }
    }

    pub fn from_name(name: &str) -> Option<Action> {
        Self::ALL.into_iter().find(|action| action.name() == name)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Button {
    Left,
    Right,
    Middle,
}

impl Button {
    pub fn from_name(name: &str) -> Option<Button> {
        match name {
            "left" => Some(Button::Left),
            "right" => Some(Button::Right),
            "middle" => Some(Button::Middle),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
}

impl Direction {
    pub fn from_name(name: &str) -> Option<Direction> {
        match name {
            "up" => Some(Direction::Up),
            "down" => Some(Direction::Down),
            "left" => Some(Direction::Left),
            "right" => Some(Direction::Right),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlStep {
    pub action: Action,
    /// What to click, move to, scroll over, set or focus. For a drag, where it starts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<ControlTarget>,
    /// Where a drag ends.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<ControlTarget>,
    /// What to type, set, open, put on the clipboard, or wait for.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gone: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id_gone: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keys: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub button: Option<Button>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub direction: Option<Direction>,
    /// Notches of the wheel.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub amount: Option<i64>,
    /// Seconds to wait.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<bool>,
    /// Left, top, width and height of the part of the screen to show in the picture.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<Vec<i64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub all: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub application: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ocr: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub changes: Option<bool>,
}

impl ControlStep {
    pub fn new(action: Action) -> Self {
        ControlStep {
            action,
            target: None,
            to: None,
            text: None,
            gone: None,
            id: None,
            id_gone: None,
            keys: None,
            button: None,
            count: None,
            direction: None,
            amount: None,
            timeout: None,
            image: None,
            region: None,
            all: None,
            application: None,
            ocr: None,
            changes: None,
        }
    }
}

/// How a call went. A step that failed is the last one.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct ControlOutcome {
    pub results: Vec<ControlStepResult>,
}

impl ControlOutcome {
    /// The step that failed, if one did.
    pub fn failure(&self) -> Option<&ControlStepResult> {
        self.results.iter().find(|result| result.error.is_some())
    }

    /// Everything said, the way a person or a model reads it.
    pub fn text(&self) -> String {
        self.results.iter().map(ControlStepResult::text).filter(|text| !text.is_empty()).collect::<Vec<_>>().join("\n")
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlStepResult {
    pub action: Action,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// A wait that ran out of time, rather than a step that failed some other way.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timed_out: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub look: Option<ControlLook>,
    /// A JPEG for a look, a PNG for a screenshot.
    #[serde(default, with = "base64_data", skip_serializing_if = "Option::is_none")]
    pub image: Option<Vec<u8>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub milliseconds: Option<i64>,
}

impl ControlStepResult {
    pub fn text(&self) -> String {
        let mut lines = Vec::new();
        if let Some(error) = &self.error {
            lines.push(format!("{} failed: {}", self.action.name(), error));
        }
        if let Some(note) = &self.note {
            lines.push(note.clone());
        }
        if let Some(look) = &self.look {
            lines.push(look.text());
        }
        lines.join("\n")
    }
}

/// What is on a machine's screen, in the screen's own pixels.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControlLook {
    pub machine: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system: Option<String>,
    pub width: i64,
    pub height: i64,
    /// How many of the display's own pixels make one of these. A Retina display has 2.
    pub scale: f64,
    /// The how-manieth look at this machine.
    pub sequence: i64,
    /// The applications on the screen, the one in front first.
    pub applications: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub front: Option<String>,
    pub elements: Vec<ControlElement>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub removed: Option<Vec<ControlElement>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub changed: Option<Vec<i64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub omitted: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<Vec<String>>,
}

impl ControlLook {
    /// One line about the screen, one about its applications, and one for each element.
    pub fn text(&self) -> String {
        let system = self.system.as_ref().map(|system| format!(" · {system}")).unwrap_or_default();
        let scale = if self.scale > 1.0 {
            let shown = if self.scale == self.scale.round() { format!("{}", self.scale as i64) } else { format!("{:.2}", self.scale) };
            format!(" ({shown}x)")
        } else {
            String::new()
        };
        let mut lines =
            vec![format!("{}{} · screen {}x{}{} · look {}", self.machine, system, self.width, self.height, scale, self.sequence)];
        if !self.applications.is_empty() {
            let applications: Vec<String> = self
                .applications
                .iter()
                .map(|application| if Some(application) == self.front.as_ref() { format!("{application}*") } else { application.clone() })
                .collect();
            lines.push(format!("apps: {}", applications.join(", ")));
        }
        lines.extend(self.notes.iter().flatten().map(|note| format!("note: {note}")));
        if let Some(removed) = &self.removed {
            let changed = self.changed.clone().unwrap_or_default();
            lines.extend(
                self.elements
                    .iter()
                    .map(|element| format!("{}{}", if changed.contains(&element.number) { "~ " } else { "+ " }, element.line(false))),
            );
            lines.extend(removed.iter().map(|element| format!("- {}", element.line(false))));
            if self.elements.is_empty() && removed.is_empty() {
                lines.push("no changes".into());
            }
        } else {
            lines.extend(self.elements.iter().map(|element| element.line(true)));
            if self.elements.is_empty() {
                lines.push("nothing to read: add --image to see the screen".into());
            }
        }
        if let Some(omitted) = self.omitted
            && omitted > 0
        {
            lines.push(format!("… {omitted} more: narrow it with --app, or see them with --all"));
        }
        lines.join("\n")
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControlElement {
    /// What a step calls it by. It stays with the element from look to look.
    pub number: i64,
    /// `button`, `textfield`, `text`, `link`, and the like. `ocr` for what was read off the pixels.
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub states: Option<Vec<String>>,
    /// Left, top, width and height.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame: Option<Vec<i64>>,
    pub depth: i64,
    /// The author-provided accessibility identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

impl ControlElement {
    pub fn line(&self, indented: bool) -> String {
        let indent = if indented { " ".repeat(self.depth.clamp(0, 8) as usize) } else { String::new() };
        let mut line = format!("{indent}[{}] {}", self.number, self.role);
        if let Some(name) = self.name.as_deref().filter(|name| !name.is_empty()) {
            line += &format!(" \"{name}\"");
        }
        if let Some(value) = self.value.as_deref().filter(|value| !value.is_empty()) {
            line += &format!(" =\"{value}\"");
        }
        if let Some(states) = self.states.as_ref().filter(|states| !states.is_empty()) {
            line += &format!(" {}", states.join(" "));
        }
        if let Some(id) = self.id.as_deref().filter(|id| !id.is_empty()) {
            line += &format!(" #{}", shown_line(id, 240));
        }
        if let Some(frame) = self.frame.as_ref().filter(|frame| frame.len() == 4) {
            line += &format!(" {},{} {}x{}", frame[0], frame[1], frame[2], frame[3]);
        }
        line
    }
}

/// What the tool exits with after a control call: the same whether it came from a script or an agent.
pub mod control_exit {
    use super::ControlOutcome;

    pub const FAILED: i32 = 1;
    pub const TIMED_OUT: i32 = 124;
    pub const COULD_NOT_RUN: i32 = 125;

    pub fn status(outcome: &ControlOutcome) -> i32 {
        match outcome.failure() {
            None => 0,
            Some(failure) if failure.timed_out == Some(true) => TIMED_OUT,
            Some(_) => FAILED,
        }
    }
}
