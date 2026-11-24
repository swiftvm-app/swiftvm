//! What QEMU is told about a machine when it starts: everything in its configuration that QEMU has a say
//! in, as its command line. A port of the app's `QEMUCommandLine.swift`, argument for argument, so that a
//! machine the app saved resumes here: QEMU restores a machine only onto the same hardware.
//!
//! Devices go as JSON, which QEMU reads as it does its machine protocol: a path needs no escaping, and a
//! drive plugged in while the machine runs is described the same way as one it starts with.
//!
//! QEMU's machine protocol and the agent's line are sockets that QEMU listens on in the machine's runtime
//! folder, so that a service that restarts finds them again. The other lines are descriptors QEMU is handed
//! as it starts, numbered from 3: the serial console, one per network card, then the TPM's.

use std::collections::HashMap;
use std::path::PathBuf;

use serde_json::{Map, Value, json};
use swiftvm_protocol::qemu::{DisplayAdapter, RemovableImage};
use swiftvm_protocol::wire::Id;

use crate::QemuError;
use crate::config::{Bundle, Bus, Family, MachineConfig, seed_image_id};
use crate::installation::Installation;

/// The most frames a second a guest is asked for: what a Mac's own screen shows at its fastest.
pub const HIGHEST_REFRESH_RATE: u32 = 120;

/// The machine type, by its version. A machine saved by one QEMU only resumes on one that builds the same
/// hardware, and a later QEMU still builds this one when asked by name.
pub const MACHINE_TYPE: &str = "virt-11.1";

pub const CONSOLE_DESCRIPTOR: i32 = 3;

/// The descriptor of the network card at `index` among the machine's interfaces.
pub fn network_descriptor(index: usize) -> i32 {
    4 + index as i32
}

/// The name the agent's serial port has in the guest, which is how the agent finds it.
pub const AGENT_PORT_NAME: &str = "org.swiftvm.agent";

/// QEMU tells the USB devices of a saved machine apart by the port each is in, so a machine is restored
/// with every device in the port it had. The keyboard, the tablet and the sound card have ports of their
/// own. Drives get the first free one, and keep it.
pub const USB_PORT_COUNT: u32 = 15;
const KEYBOARD_PORT: u32 = 1;
const TABLET_PORT: u32 = 2;
const AUDIO_PORT: u32 = 3;
pub const FIRST_DRIVE_PORT: u32 = 4;

/// The sound card, which is unplugged while the machine is saved: QEMU can't save it.
pub const AUDIO_DEVICE_ID: &str = "audio";

pub fn audio_device() -> Value {
    json!({"driver": "usb-audio", "id": AUDIO_DEVICE_ID, "bus": "usb.0", "port": AUDIO_PORT.to_string(), "audiodev": "audio"})
}

/// The lowest port for a drive that none of `used` is in, if there is one.
pub fn free_usb_port<'a>(used: impl IntoIterator<Item = &'a u32>) -> Option<u32> {
    let taken: Vec<u32> = used.into_iter().copied().collect();
    (FIRST_DRIVE_PORT..=USB_PORT_COUNT).find(|port| !taken.contains(port))
}

/// Where QEMU reads and writes a disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiskSource {
    /// A raw image.
    File(PathBuf),
    /// The app's server, for a compressed disk.
    Nbd(String),
}

/// The name of the export the app's NBD server gives a compressed disk under (`CompressedDiskExport`).
pub const NBD_EXPORT_NAME: &str = "disk";

pub struct CommandLine<'a> {
    pub config: &'a MachineConfig,
    pub bundle: &'a Bundle,
    pub installation: &'a Installation,
    /// Where each disk is, by its identifier.
    pub disk_sources: HashMap<Id, DiskSource>,
    pub display: DisplayAdapter,
    /// Start from saved state, which QEMU is handed once it is up.
    pub restores_saved_state: bool,
    /// The USB ports that drives and disks on USB were in when the machine was saved.
    pub usb_ports: HashMap<Id, u32>,
    pub spice_socket: Option<PathBuf>,
    /// The machine has a TPM, whose emulator is at the other end of `tpm_descriptor`.
    pub attaches_tpm: bool,
    /// The frames a second a guest on the GPU draws. Without it the guest is told QEMU's own 75.
    pub refresh_rate: Option<u32>,
    pub monitor_socket: PathBuf,
    pub agent_socket: PathBuf,
    /// The serial console is a descriptor handed to QEMU. Without one, it goes nowhere.
    pub has_console: bool,
}

/// Whether a machine starts with a TPM. One that resumes has the one it was saved with, as QEMU restores a
/// machine only onto the same hardware. One that starts afresh has it if it is Windows with it turned on,
/// and this QEMU comes with the emulator.
pub fn attaches_tpm(config: &MachineConfig, supports_tpm: bool, saved_with_tpm: Option<bool>) -> Result<bool, QemuError> {
    if let Some(saved_with_tpm) = saved_with_tpm {
        if saved_with_tpm && !supports_tpm {
            return Err(QemuError::DidNotStart(format!(
                "“{}” was saved with a TPM, and this copy of SwiftVM was built without one. Discard its saved state to start it up fresh.",
                config.name
            )));
        }
        return Ok(saved_with_tpm);
    }
    Ok(config.family() == Family::Windows && config.boot.tpm && supports_tpm)
}

/// The adapter a machine starts with. Memory that was saved expects the display it was saved with. A
/// guest that starts afresh gets the one that follows the window once it has the driver for it.
pub fn display_adapter(config: &MachineConfig, installation: &Installation, restoring: bool) -> Result<DisplayAdapter, QemuError> {
    let adapter = if restoring {
        config.display.adapter.unwrap_or(DisplayAdapter::Framebuffer)
    } else if config.family() == Family::Linux {
        // Linux brings the driver for a virtio GPU along, whether it draws with the GPU or not.
        if config.display.accelerates_graphics { DisplayAdapter::VirtioGpu3d } else { DisplayAdapter::VirtioGpu }
    } else {
        windows_display_adapter(config, installation)
    };
    if adapter == DisplayAdapter::VirtioGpu3d {
        if restoring {
            return Err(QemuError::DidNotStart("A machine with graphics acceleration can't resume saved memory.".into()));
        }
        if !installation.accelerates_graphics {
            return Err(QemuError::DidNotStart("This copy of SwiftVM's QEMU was built without graphics acceleration.".into()));
        }
        // Custom builds can leave out Direct3D, which Windows' 3D driver needs.
        if config.family() == Family::Windows && !installation.supports_direct3d() {
            return Err(QemuError::DidNotStart(
                "This copy of SwiftVM's QEMU was built without Direct3D, which Windows' 3D driver needs.".into(),
            ));
        }
    }
    Ok(adapter)
}

pub fn windows_display_adapter(config: &MachineConfig, installation: &Installation) -> DisplayAdapter {
    if config.installation.has_accelerated_display_driver {
        // The 3D installer removes the display-only driver. Without Direct3D, the firmware's framebuffer
        // still works; a plain virtio GPU may have no driver.
        return if installation.accelerates_graphics && installation.supports_direct3d() {
            DisplayAdapter::VirtioGpu3d
        } else {
            DisplayAdapter::Framebuffer
        };
    }
    if config.installation.has_display_driver { DisplayAdapter::VirtioGpu } else { DisplayAdapter::Framebuffer }
}

/// Whether the machine is about to start an installer disc: one is plugged in, and nothing has been
/// written to the disk it would install to. Only Windows' disc waits for a key.
pub fn boots_installer(config: &MachineConfig, bundle: &Bundle) -> bool {
    let Some(disk) = config.system_disk() else { return false };
    config.family() == Family::Windows
        && config.removable_images().iter().any(|image| crate::config::is_disc_image(&image.path))
        && bundle.allocated_size(&[disk]) < 16 << 20
}

impl CommandLine<'_> {
    /// The drives the machine starts with: those plugged in, and the setup disc of a machine that sets
    /// itself up and has it. Linux has its setup disc as a disk of its own.
    pub fn starting_drives(&self) -> Vec<RemovableImage> {
        let mut drives = self.config.removable_images().to_vec();
        if self.config.family() != Family::Linux
            && let Some(seed) = self.seed_image()
        {
            drives.push(seed);
        }
        drives
    }

    fn seed_image(&self) -> Option<RemovableImage> {
        let path = self.bundle.seed_image();
        (self.config.installation.attaches_seed_image && path.exists()).then(|| RemovableImage {
            id: seed_image_id(),
            path: path.to_string_lossy().into_owned(),
            read_only: true,
        })
    }

    /// The port of every drive and disk on USB the machine starts with: the one it had when it was saved,
    /// otherwise the first free one.
    pub fn starting_usb_ports(&self) -> Result<HashMap<Id, u32>, QemuError> {
        let ids: Vec<Id> = self
            .config
            .disks
            .iter()
            .filter(|disk| disk.bus == Bus::Usb)
            .map(|disk| disk.id)
            .chain(self.starting_drives().iter().map(|image| image.id))
            .collect();
        let mut ports = HashMap::new();
        for id in &ids {
            if let Some(port) = self.usb_ports.get(id) {
                ports.insert(*id, *port);
            }
        }
        for id in &ids {
            if !ports.contains_key(id) {
                let port = free_usb_port(ports.values())
                    .ok_or_else(|| QemuError::DidNotStart(format!("“{}” has more drives than USB ports for them.", self.config.name)))?;
                ports.insert(*id, port);
            }
        }
        Ok(ports)
    }

    /// The descriptor of the TPM emulator's control line, after the network cards'.
    pub fn tpm_descriptor(&self) -> i32 {
        network_descriptor(self.config.network_interfaces.len())
    }

    pub fn arguments(&self) -> Result<Vec<String>, QemuError> {
        let config = self.config;
        let windows = config.family() == Family::Windows;
        let linux = config.family() == Family::Linux;
        let accelerated = self.display == DisplayAdapter::VirtioGpu3d;
        if accelerated && !(self.installation.accelerates_graphics && self.spice_socket.is_some() && !self.restores_saved_state) {
            return Err(QemuError::DidNotStart(
                "Graphics acceleration needs QEMU with OpenGL and the app's display, and can't resume saved memory.".into(),
            ));
        }
        let memory = (config.memory_size >> 20).max(512);
        let mut arguments: Vec<String> = vec![
            "-nodefaults".into(),
            "-no-user-config".into(),
            // An option list, where a comma in the name would be read as more options.
            "-name".into(),
            format!("guest={}", escaped(&config.name)),
            "-machine".into(),
            MACHINE_TYPE.into(),
            "-accel".into(),
            accelerator(accelerated && windows).into(),
            "-cpu".into(),
            "host".into(),
            "-smp".into(),
            config.cpu_count.max(1).to_string(),
            "-m".into(),
            format!("{memory}M"),
            // The machine's identity in its firmware's tables, which Windows ties its activation to.
            "-uuid".into(),
            config.id.0.hyphenated().to_string(),
            "-L".into(),
            path(&self.installation.data_directory),
            "-bios".into(),
            path(&self.installation.firmware()),
            "-drive".into(),
            format!("if=pflash,unit=1,format=raw,file={}", escaped(&path(&self.bundle.efi_variable_store()))),
            // Windows keeps its clock in local time, Linux in UTC.
            "-rtc".into(),
            if windows { "base=localtime" } else { "base=utc" }.into(),
            "-display".into(),
            "none".into(),
            // Nothing runs until the service has its lines in place and says so.
            "-S".into(),
            // A guest that restarts ends QEMU instead, and it is started anew with the machine as it is
            // configured by then: a display driver that setup installed is used from there on.
            "-no-reboot".into(),
            "-chardev".into(),
            format!("socket,id=monitor,path={},server=on,wait=off", escaped(&path(&self.monitor_socket))),
            "-chardev".into(),
            if self.has_console { format!("socket,id=console,fd={CONSOLE_DESCRIPTOR}") } else { "null,id=console".into() },
        ];
        // Linux writes to a virtio console (hvc0); Windows to the serial port.
        if !linux {
            arguments.extend(["-serial".into(), "chardev:console".into()]);
        }
        arguments.extend(["-object".into(), json(&json!({"qom-type": "monitor-qmp", "id": "monitor", "chardev": "monitor"}))]);
        match (&self.spice_socket, accelerated) {
            (Some(socket), true) => arguments.extend(["-spice".into(), format!(
                "unix=on,addr={},disable-ticketing=on,gl=on,streaming-video=off,agent-mouse=off,disable-copy-paste=on,disable-agent-file-xfer=on",
                escaped(&path(socket))
            )]),
            // The VNC server listens nowhere: the app hands it the one client it has.
            _ => arguments.extend(["-vnc".into(), "none".into()]),
        }
        if self.restores_saved_state {
            arguments.extend(["-incoming".into(), "defer".into()]);
        }

        let ports = self.starting_usb_ports()?;
        let mut devices: Vec<Value> = Vec::new();
        // As many ports as there can be, so that nothing ends up behind a hub. Each takes USB 2 and 3.
        devices.push(json!({"driver": "qemu-xhci", "id": "usb", "p2": USB_PORT_COUNT, "p3": USB_PORT_COUNT}));
        devices.push(json!({"driver": "usb-kbd", "bus": "usb.0", "port": KEYBOARD_PORT.to_string()}));
        // Absolute positions, so the pointer is where the host's is.
        devices.push(json!({"driver": "usb-tablet", "bus": "usb.0", "port": TABLET_PORT.to_string()}));
        let (width, height) = (config.display.width_in_pixels, config.display.height_in_pixels);
        match self.display {
            DisplayAdapter::Framebuffer => devices.push(json!({"driver": "ramfb"})),
            DisplayAdapter::VirtioGpu => devices.push(json!({"driver": "virtio-gpu-pci", "id": "gpu", "xres": width, "yres": height})),
            // Linux draws with OpenGL, which virglrenderer replays on the host's GPU.
            DisplayAdapter::VirtioGpu3d if linux => devices.push(with_refresh_rate(
                self.refresh_rate,
                json!({"driver": "virtio-gpu-gl-pci", "id": "gpu", "xres": width, "yres": height}),
            )),
            DisplayAdapter::VirtioGpu3d => devices.push(with_refresh_rate(
                self.refresh_rate,
                json!({"driver": "virtio-ramfb-gl", "id": "gpu", "hostmem": 8u64 << 30, "blob": true, "neptune": true, "xres": width, "yres": height}),
            )),
        }

        for (index, disk) in config.disks.iter().enumerate() {
            let source = self
                .disk_sources
                .get(&disk.id)
                .ok_or_else(|| QemuError::DidNotStart(format!("The disk “{}” isn't there.", disk.file_name)))?;
            let node = disk_node_name(index);
            arguments.extend(["-blockdev".into(), json(&disk_node(&node, source, disk.read_only))]);
            devices.push(disk_device(&node, disk.bus, &format!("swiftvm{index}"), ports.get(&disk.id).copied()));
        }
        for image in self.starting_drives() {
            arguments.extend(["-blockdev".into(), json(&image_node(&image))]);
            devices.extend(image_devices(&image, ports.get(&image.id).copied().unwrap_or(FIRST_DRIVE_PORT)));
        }
        // cloud-init looks for its setup disc early, before the system has looked for drives on USB. A
        // virtio disk is there from the beginning.
        if linux && let Some(seed) = self.seed_image() {
            arguments.extend(["-blockdev".into(), json(&image_node(&seed))]);
            devices.push(json!({"driver": "virtio-blk-pci", "drive": image_node_name(&seed.id), "serial": "swiftvm-seed"}));
        }

        // A Linux guest's shared folders, a 9p device each, by the tags its agent mounts them by: those the
        // machine starts with, and that are there. QEMU doesn't start with a folder that isn't.
        if linux {
            let present = config.shared_folders.iter().filter(|folder| std::path::Path::new(&folder.path).is_dir());
            for (index, folder) in present.enumerate() {
                let mut options = format!("local,id=share{index},path={},security_model=none", escaped(&folder.path));
                if folder.read_only {
                    options.push_str(",readonly=on");
                }
                arguments.extend(["-fsdev".into(), options]);
                devices.push(json!({"driver": "virtio-9p-pci", "fsdev": format!("share{index}"), "mount_tag": folder.device_tag()}));
            }
        }

        for (index, interface) in config.network_interfaces.iter().enumerate() {
            arguments.extend([
                "-netdev".into(),
                json(&json!({
                    "type": "dgram", "id": format!("net{index}"),
                    "local": {"type": "fd", "str": network_descriptor(index).to_string()},
                })),
            ]);
            // The firmware has a driver of its own for the card: the one QEMU would load from a file that
            // isn't there is no use.
            devices.push(json!({
                "driver": "virtio-net-pci", "id": network_device_id(index), "netdev": format!("net{index}"),
                "mac": interface.mac_address, "romfile": "",
            }));
        }

        // The agent's line, a serial port of its own that only the service is at the other end of.
        devices.push(json!({"driver": "virtio-serial-pci", "id": "serial"}));
        arguments.extend(["-chardev".into(), format!("socket,id=agent,path={},server=on,wait=off", escaped(&path(&self.agent_socket)))]);
        devices.push(json!({"driver": "virtserialport", "bus": "serial.0", "chardev": "agent", "name": AGENT_PORT_NAME}));
        if linux {
            devices.push(json!({"driver": "virtconsole", "bus": "serial.0", "chardev": "console"}));
        }
        if accelerated {
            // SPICE settles monitor sizes with the guest tools. Input stays on the USB tablet.
            arguments.extend(["-chardev".into(), "spicevmc,id=display-agent,name=vdagent".into()]);
            devices.push(json!({"driver": "virtserialport", "bus": "serial.0", "chardev": "display-agent", "name": "com.redhat.spice.0"}));
        }

        devices.push(json!({"driver": "virtio-rng-pci"}));
        if self.attaches_tpm {
            // A TPM on the platform bus, which the firmware and Windows find through ACPI.
            arguments.extend([
                "-chardev".into(),
                format!("socket,id=tpm,fd={}", self.tpm_descriptor()),
                "-tpmdev".into(),
                "emulator,id=tpm0,chardev=tpm".into(),
            ]);
            // Its command response buffer interface, which Windows on Arm drives (qemu-tpm-crb.patch).
            devices.push(json!({"driver": "tpm-crb-device", "tpmdev": "tpm0"}));
        }
        if config.audio.output_enabled {
            arguments.extend(["-audiodev".into(), format!("{},id=audio", audio_backend())]);
            // A restored machine was saved without it, and has it plugged in once it is back.
            if !self.restores_saved_state {
                devices.push(audio_device());
            }
        }

        for device in devices {
            arguments.extend(["-device".into(), json(&device)]);
        }
        Ok(arguments)
    }
}

/// The hypervisor QEMU runs the guest on. Windows' Direct3D driver places GPU memory at 4K offsets, which
/// guest memory mapped in a Mac's 16K pages can't follow.
fn accelerator(windows_3d: bool) -> &'static str {
    if cfg!(target_os = "macos") { if windows_3d { "hvf,ipa-granule-size=4096" } else { "hvf" } } else { "kvm" }
}

fn audio_backend() -> &'static str {
    if cfg!(target_os = "macos") { "coreaudio" } else { "none" }
}

/// A GPU whose EDID names `rate` frames a second, in mHz (qemu-virtio-gpu-refresh-rate.patch).
fn with_refresh_rate(rate: Option<u32>, mut gpu: Value) -> Value {
    if let (Some(rate), Some(object)) = (rate, gpu.as_object_mut()) {
        object.insert("refresh_rate".into(), json!(rate.clamp(1, HIGHEST_REFRESH_RATE) * 1000));
    }
    gpu
}

fn disk_node_name(index: usize) -> String {
    format!("disk{index}")
}

fn disk_node(id: &str, source: &DiskSource, read_only: bool) -> Value {
    let file = match source {
        DiskSource::File(file) => json!({"driver": "file", "filename": path(file)}),
        DiskSource::Nbd(socket) => json!({"driver": "nbd", "server": {"type": "unix", "path": socket}, "export": NBD_EXPORT_NAME}),
    };
    // What the guest frees is given back to the host: the image stays as small as what is in it.
    json!({"driver": "raw", "node-name": id, "read-only": read_only, "discard": "unmap", "file": file})
}

/// No device is given a place in the order the firmware starts from. Given one, the firmware looks at
/// nothing else: not at an installer disc.
fn disk_device(node: &str, bus: Bus, serial: &str, port: Option<u32>) -> Value {
    match bus {
        Bus::Nvme => json!({"driver": "nvme", "drive": node, "serial": serial}),
        Bus::Virtio => json!({"driver": "virtio-blk-pci", "drive": node, "serial": serial}),
        Bus::Usb => json!({
            "driver": "usb-storage", "bus": "usb.0", "port": port.unwrap_or(FIRST_DRIVE_PORT).to_string(),
            "drive": node, "serial": serial,
        }),
    }
}

/// A drive's identifier, short enough for QEMU's names (31 characters at most).
fn short_name(id: &Id) -> String {
    id.0.simple().to_string()[..16].to_string()
}

/// The name of the block node that holds a drive's image.
pub fn image_node_name(id: &Id) -> String {
    format!("image-{}", short_name(id))
}

/// The device QEMU knows a drive by, which unplugging it names. Discs are CD drives: Windows reads the
/// file system of a disc image only from a drive for discs.
pub fn image_device_id(image: &RemovableImage) -> String {
    let kind = if crate::config::is_disc_image(&image.path) { "disc-" } else { "drive-" };
    format!("{kind}{}", short_name(&image.id))
}

pub fn image_node(image: &RemovableImage) -> Value {
    json!({
        "driver": "raw", "node-name": image_node_name(&image.id), "read-only": image.read_only,
        "file": {"driver": "file", "filename": image.path, "read-only": image.read_only},
    })
}

/// The devices a drive is, in USB port `port`: a USB drive for a disk image, and for a disc a bare USB
/// storage device with a CD drive on its bus.
pub fn image_devices(image: &RemovableImage, port: u32) -> Vec<Value> {
    let id = image_device_id(image);
    let node = image_node_name(&image.id);
    let port = port.to_string();
    if !crate::config::is_disc_image(&image.path) {
        return vec![json!({"driver": "usb-storage", "id": id, "bus": "usb.0", "port": port, "drive": node, "removable": true})];
    }
    vec![
        json!({"driver": "usb-bot", "id": id, "bus": "usb.0", "port": port}),
        json!({"driver": "scsi-cd", "id": format!("{id}-cd"), "bus": format!("{id}.0"), "drive": node}),
    ]
}

pub fn network_device_id(index: usize) -> String {
    format!("nic{index}")
}

/// Keys in order, no spaces: what QEMU is given for a device, and the same text the app gave it.
pub fn json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".into())
}

/// A value in QEMU's option syntax, where a comma ends it unless it is doubled.
pub fn escaped(value: &str) -> String {
    value.replace(',', ",,")
}

fn path(path: &std::path::Path) -> String {
    path.to_string_lossy().into_owned()
}

/// A JSON object, for QMP arguments.
pub fn object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}
