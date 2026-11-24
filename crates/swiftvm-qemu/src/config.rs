//! What QEMU needs of a machine: the part of its `config.json` that QEMU has a say in, and where its
//! files are in its bundle. The app writes both (`VMCore/VMConfiguration.swift`, `VMCore/VMBundle.swift`);
//! the service only reads them.
//!
//! Reading is as tolerant as the app's: every section that was added after the first version has a
//! default, so that older bundles keep opening.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use swiftvm_protocol::qemu::{DisplayAdapter, RemovableImage};
use swiftvm_protocol::wire::Id;
use uuid::Uuid;

/// The newest `config.json` the service reads.
pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineConfig {
    #[serde(default = "first_schema")]
    pub schema_version: u32,
    pub id: Id,
    pub name: String,
    pub os: GuestOs,
    #[serde(default)]
    pub engine: Option<Engine>,
    pub cpu_count: i64,
    /// In bytes.
    pub memory_size: u64,
    #[serde(default)]
    pub disks: Vec<Disk>,
    /// Missing from bundles made before there were drives: see `MachineConfig::read`.
    #[serde(default)]
    pub removable_images: Option<Vec<RemovableImage>>,
    #[serde(default)]
    pub display: Display,
    #[serde(default)]
    pub network_interfaces: Vec<NetworkInterface>,
    #[serde(default)]
    pub shared_folders: Vec<SharedFolder>,
    #[serde(default)]
    pub audio: Audio,
    #[serde(default)]
    pub boot: Boot,
    #[serde(default)]
    pub installation: Installation,
}

fn first_schema() -> u32 {
    1
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Engine {
    Virtualization,
    Qemu,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct GuestOs {
    pub family: Family,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub enum Family {
    #[serde(rename = "macOS")]
    MacOs,
    #[serde(rename = "linux")]
    Linux,
    #[serde(rename = "windows")]
    Windows,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Disk {
    pub id: Id,
    /// Relative to the bundle.
    pub file_name: String,
    pub bus: Bus,
    pub format: DiskFormat,
    #[serde(default)]
    pub read_only: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Bus {
    Virtio,
    Nvme,
    Usb,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DiskFormat {
    /// Apple's sparse image format, which QEMU doesn't read.
    Asif,
    Raw,
    /// SwiftVM's own, served to QEMU over NBD by the app.
    Compressed,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Display {
    pub width_in_pixels: u32,
    pub height_in_pixels: u32,
    #[serde(default = "yes")]
    pub automatically_resizes: bool,
    /// The adapter the guest last started with, which memory saved of it expects.
    #[serde(default)]
    pub adapter: Option<DisplayAdapter>,
    #[serde(default)]
    pub accelerates_graphics: bool,
}

impl Default for Display {
    fn default() -> Self {
        Display { width_in_pixels: 1920, height_in_pixels: 1200, automatically_resizes: true, adapter: None, accelerates_graphics: false }
    }
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkInterface {
    pub id: Id,
    #[serde(default)]
    pub bridged_interface_identifier: Option<String>,
    pub mac_address: String,
    #[serde(default = "yes")]
    pub is_connected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedFolder {
    pub id: Id,
    pub path: String,
    #[serde(default)]
    pub read_only: bool,
}

impl SharedFolder {
    /// The tag a Linux guest's agent mounts the folder by (`GuestIntegration.folderDeviceTag`).
    pub fn device_tag(&self) -> String {
        format!("swiftvm-{}", &self.id.0.hyphenated().to_string()[..8])
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Audio {
    #[serde(default = "yes")]
    pub output_enabled: bool,
}

impl Default for Audio {
    fn default() -> Self {
        Audio { output_enabled: true }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Boot {
    /// Windows guests get a TPM 2.0 unless it is turned off.
    #[serde(default = "yes")]
    pub tpm: bool,
}

impl Default for Boot {
    fn default() -> Self {
        Boot { tpm: true }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Installation {
    #[serde(default)]
    pub attaches_seed_image: bool,
    #[serde(default)]
    pub has_display_driver: bool,
    #[serde(default)]
    pub has_accelerated_display_driver: bool,
    /// Bundles made before drives existed kept the one installer disc here.
    #[serde(default)]
    pub install_media_path: Option<String>,
}

#[derive(Debug)]
pub enum ConfigError {
    Unreadable(String),
    Invalid(String),
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::Unreadable(message) | ConfigError::Invalid(message) => f.write_str(message),
        }
    }
}

impl MachineConfig {
    pub fn parse(data: &[u8]) -> Result<MachineConfig, ConfigError> {
        let mut config: MachineConfig = serde_json::from_slice(data)
            .map_err(|error| ConfigError::Invalid(format!("The virtual machine's configuration can't be read: {error}")))?;
        if config.schema_version > SCHEMA_VERSION {
            return Err(ConfigError::Invalid(format!(
                "This virtual machine was created by a newer version of SwiftVM (schema {}).",
                config.schema_version
            )));
        }
        if config.removable_images.is_none() {
            // The one installer disc of old bundles, as the drive with the machine's own identifier.
            let legacy = config.installation.install_media_path.clone();
            config.removable_images =
                Some(legacy.map(|path| vec![RemovableImage { id: config.id, path, read_only: true }]).unwrap_or_default());
        }
        Ok(config)
    }

    pub fn read(bundle: &Bundle) -> Result<MachineConfig, ConfigError> {
        let data = std::fs::read(bundle.config_path())
            .map_err(|error| ConfigError::Unreadable(format!("{} can't be read: {error}", bundle.config_path().display())))?;
        Self::parse(&data)
    }

    pub fn family(&self) -> Family {
        self.os.family
    }

    /// The engine it runs on: QEMU for Windows unless it says otherwise.
    pub fn engine(&self) -> Engine {
        self.engine.unwrap_or(if self.os.family == Family::Windows { Engine::Qemu } else { Engine::Virtualization })
    }

    pub fn removable_images(&self) -> &[RemovableImage] {
        self.removable_images.as_deref().unwrap_or_default()
    }

    /// The disk it starts from.
    pub fn system_disk(&self) -> Option<&Disk> {
        self.disks.first()
    }
}

/// Whether an image is a disc, which goes into a drive for discs.
pub fn is_disc_image(path: &str) -> bool {
    Path::new(path).extension().and_then(|extension| extension.to_str()).is_some_and(|extension| {
        let extension = extension.to_ascii_lowercase();
        extension == "iso" || extension == "cdr"
    })
}

/// A machine's folder, and where its files are in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bundle {
    pub path: PathBuf,
}

impl Bundle {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Bundle { path: path.into() }
    }

    pub fn config_path(&self) -> PathBuf {
        self.path.join("config.json")
    }

    pub fn efi_variable_store(&self) -> PathBuf {
        self.path.join("efi-vars.fd")
    }

    pub fn tpm_state(&self) -> PathBuf {
        self.path.join("tpm-state.bin")
    }

    pub fn seed_image(&self) -> PathBuf {
        self.path.join("seed.iso")
    }

    pub fn logs(&self) -> PathBuf {
        self.path.join("logs")
    }

    pub fn qemu_log(&self) -> PathBuf {
        self.logs().join("qemu.log")
    }

    pub fn tpm_log(&self) -> PathBuf {
        self.logs().join("tpm.log")
    }

    /// Where QEMU writes its process ID, so that one left behind is found and ended.
    pub fn qemu_pid_file(&self) -> PathBuf {
        self.path.join("qemu.pid")
    }

    pub fn tpm_pid_file(&self) -> PathBuf {
        self.path.join("tpm.pid")
    }

    pub fn disk(&self, disk: &Disk) -> PathBuf {
        self.path.join(&disk.file_name)
    }

    /// How much of the disks is written: what they take up on the disk they are kept on.
    pub fn allocated_size(&self, disks: &[&Disk]) -> u64 {
        disks.iter().filter_map(|disk| std::fs::metadata(self.disk(disk)).ok()).map(|metadata| metadata.blocks() * 512).sum()
    }
}

/// The identifier of the drive that the setup disc of a machine that sets itself up is: made up, but always
/// the same.
pub fn seed_image_id() -> Id {
    Id(Uuid::from_u128(0x5E1D0000_0000_4000_8000_000000000000))
}
