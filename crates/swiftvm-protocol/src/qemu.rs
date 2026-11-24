//! The engine requests: how the app hands a QEMU machine to the service, and what the service says about
//! the machines it runs. They are the app's for now, not yet for other clients: see `docs/tech/api.md`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::wire::Id;

/// What a `qemu-` request carries besides its `id` and `command`. Each request reads the fields it needs.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QemuRequest {
    /// The machine, by its identifier. Every request but `qemu-start` and `qemu-list` names one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<Id>,
    /// `qemu-start`: the machine's bundle, whose `config.json` says what it is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bundle: Option<String>,
    /// `qemu-start`: resume from this saved state instead of booting.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub saved_state: Option<String>,
    /// `qemu-start`: where a Windows guest's Direct3D is drawn.
    #[serde(rename = "directX", skip_serializing_if = "Option::is_none")]
    pub direct_x: Option<DirectX>,
    /// `qemu-start`: the frames a second a guest on the GPU draws.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_rate: Option<u32>,
    /// `qemu-start`: the NBD socket that serves each compressed disk, by the disk's identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disk_sources: Option<BTreeMap<String, String>>,
    /// `qemu-start`: what each descriptor that comes with the request is, in the order they come.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub descriptors: Option<Vec<DescriptorRole>>,
    /// `qemu-stop`: end QEMU at once, without asking it to quit.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub force: Option<bool>,
    /// `qemu-save`: the file the machine's memory goes to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// `qemu-link`: the network card, by its place among the machine's interfaces.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
    /// `qemu-link`: whether its cable is plugged in.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connected: Option<bool>,
    /// `qemu-attach-image`: the image to plug in as a USB drive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<RemovableImage>,
    /// `qemu-detach-image`: the drive to unplug, by its identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_id: Option<Id>,
    /// `qemu-connect`: the port in the guest.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u32>,
    /// `qemu-pointer`: what the mouse does.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pointer: Option<Pointer>,
    /// `qemu-keys`: what the keyboard types.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keys: Option<Keys>,
    /// `qemu-pointer`: the display's size in pixels, for a display the service can't take a picture of:
    /// one the guest draws with the GPU.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<Size>,
}

/// Where a Windows guest's Direct3D is drawn on a Mac.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DirectX {
    /// `dxmt`, or `d3dmetal` with `framework`.
    pub backend: String,
    /// D3DMetal.framework, for `d3dmetal`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub framework: Option<String>,
}

/// What a descriptor that comes with `qemu-start` is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DescriptorRole {
    /// A stream socket: the machine's serial console.
    Console,
    /// A datagram socket: the next network card's Ethernet frames, one to a datagram.
    Network,
    /// A stream socket: the one client of the machine's VNC display.
    Display,
}

/// A disc or disk image plugged in as a USB drive, as `config.json` has it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemovableImage {
    pub id: Id,
    pub path: String,
    #[serde(default)]
    pub read_only: bool,
}

/// Something done with the mouse, in the pixels of the display from its top left corner. The same as a
/// guest job's `GuestPointer`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pointer {
    pub action: PointerAction,
    pub x: i64,
    pub y: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub button: Option<PointerButton>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    #[serde(rename = "toX", skip_serializing_if = "Option::is_none")]
    pub to_x: Option<i64>,
    #[serde(rename = "toY", skip_serializing_if = "Option::is_none")]
    pub to_y: Option<i64>,
    #[serde(rename = "deltaX", skip_serializing_if = "Option::is_none")]
    pub delta_x: Option<i64>,
    #[serde(rename = "deltaY", skip_serializing_if = "Option::is_none")]
    pub delta_y: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PointerAction {
    Move,
    Click,
    Drag,
    Scroll,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PointerButton {
    Left,
    Right,
    Middle,
}

/// Text to type, and keys to press one after the other (`Return`, `ctrl+c`). The same as a guest job's.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Keys {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keys: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Size {
    pub width: u32,
    pub height: u32,
}

/// What shows a QEMU machine's display. The names are those `config.json` keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DisplayAdapter {
    /// A framebuffer that the firmware sets up, at one size.
    #[serde(rename = "framebuffer")]
    Framebuffer,
    /// A virtio GPU, whose size a driver in the guest changes.
    #[serde(rename = "virtioGPU")]
    VirtioGpu,
    /// A virtio GPU that draws with the host's GPU, shown over SPICE.
    #[serde(rename = "virtioGPU3D")]
    VirtioGpu3d,
}

/// Where a machine the service runs is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum QemuState {
    /// QEMU is up and the guest is held, until `qemu-continue`.
    Held,
    Running,
    Paused,
    /// QEMU has ended.
    Exited,
}

/// A machine the service runs on QEMU.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QemuMachine {
    pub machine: Id,
    pub name: String,
    pub bundle: String,
    /// QEMU's process.
    pub pid: i32,
    pub state: QemuState,
    pub adapter: DisplayAdapter,
    /// Whether its memory can be saved: not while the guest draws with the GPU.
    pub can_save_state: bool,
    /// For a display shown over SPICE, the socket to connect to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spice_socket: Option<String>,
}

/// How QEMU ended.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QemuExit {
    /// The reason QEMU gave for the guest going down, such as `guest-shutdown` or `guest-reset`. None when
    /// it didn't give one, as when it crashed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// The service had been asked to stop it.
    pub expected: bool,
    /// What QEMU said last that tells what went wrong, if anything.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// A line of the stream that follows `qemu-start` and `qemu-attach`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QemuEvent {
    /// `qemu-exited`, the last line of the stream.
    pub event: String,
    pub machine: Id,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<QemuExit>,
}

/// The picture `qemu-frame` answers with: `length` bytes follow the answer's line, four a pixel, blue first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub bytes_per_row: u32,
    pub length: u64,
}
