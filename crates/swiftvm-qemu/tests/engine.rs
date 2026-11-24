//! The QEMU engine's critical paths: what QEMU is told about a machine (states saved by the app must
//! resume), the files it shares with the app, and the lines it talks to QEMU and the guest's agent over.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::{Value, json};
use swiftvm_protocol::qemu::{DisplayAdapter, Keys, Pointer, PointerAction, RemovableImage};
use swiftvm_protocol::wire::Id;
use swiftvm_qemu::agent_channel::{AgentChannel, ChannelError, ChannelFrame, FrameKind, FrameReader};
use swiftvm_qemu::command_line::{self, CommandLine, DiskSource};
use swiftvm_qemu::config::{Bundle, MachineConfig};
use swiftvm_qemu::input::{self, InputStep};
use swiftvm_qemu::installation::Installation;
use swiftvm_qemu::qmp::Qmp;
use swiftvm_qemu::saved_state::{self, SavedStateHeader};
use swiftvm_qemu::{QemuError, process, tpm};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

static COUNT: AtomicUsize = AtomicUsize::new(0);

fn scratch() -> PathBuf {
    let folder = std::env::temp_dir().join(format!("swiftvm-qemu-{}-{}", std::process::id(), COUNT.fetch_add(1, Ordering::Relaxed)));
    std::fs::create_dir_all(&folder).unwrap();
    folder
}

/// The machine of the shared fixture, which the app's own tests read too: as the app writes it.
fn fixture() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../swiftvm-protocol/tests/fixtures/machine/config.json");
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn config(value: &Value) -> MachineConfig {
    MachineConfig::parse(&serde_json::to_vec(value).unwrap()).unwrap()
}

fn installation(accelerates_graphics: bool) -> Installation {
    Installation {
        program: "/App/Contents/Helpers/QEMU/bin/qemu-system-aarch64".into(),
        data_directory: "/App/Contents/Resources/QEMU/share".into(),
        accelerates_graphics,
    }
}

struct Line<'a> {
    config: &'a MachineConfig,
    bundle: &'a Bundle,
    installation: &'a Installation,
    display: DisplayAdapter,
    restoring: bool,
    usb_ports: HashMap<Id, u32>,
    tpm: bool,
    spice: Option<PathBuf>,
    refresh_rate: Option<u32>,
}

impl<'a> Line<'a> {
    fn new(config: &'a MachineConfig, bundle: &'a Bundle, installation: &'a Installation) -> Self {
        Line {
            config,
            bundle,
            installation,
            display: DisplayAdapter::Framebuffer,
            restoring: false,
            usb_ports: HashMap::new(),
            tpm: false,
            spice: None,
            refresh_rate: None,
        }
    }

    fn command_line(&self) -> CommandLine<'a> {
        CommandLine {
            config: self.config,
            bundle: self.bundle,
            installation: self.installation,
            disk_sources: self.config.disks.iter().map(|disk| (disk.id, DiskSource::File(self.bundle.disk(disk)))).collect(),
            display: self.display,
            restores_saved_state: self.restoring,
            usb_ports: self.usb_ports.clone(),
            spice_socket: self.spice.clone(),
            attaches_tpm: self.tpm,
            refresh_rate: self.refresh_rate,
            monitor_socket: "/tmp/swiftvm-501/00000000/0123456789abcdef/qmp.sock".into(),
            agent_socket: "/tmp/swiftvm-501/00000000/0123456789abcdef/agent.sock".into(),
            has_console: true,
        }
    }

    fn arguments(&self) -> Result<Vec<String>, QemuError> {
        self.command_line().arguments()
    }
}

fn values(option: &str, arguments: &[String]) -> Vec<String> {
    arguments.windows(2).filter(|pair| pair[0] == option).map(|pair| pair[1].clone()).collect()
}

fn objects(option: &str, arguments: &[String]) -> Vec<Value> {
    values(option, arguments).iter().filter_map(|value| serde_json::from_str(value).ok()).collect()
}

fn image(fixture: &Value, index: usize) -> RemovableImage {
    serde_json::from_value(fixture["removableImages"][index].clone()).unwrap()
}

// MARK: - The command line

#[test]
fn a_windows_machine_gets_the_hardware_the_app_gave_it() {
    let fixture = fixture();
    let config = config(&fixture);
    let bundle = Bundle::new("/Machines/Windows.swiftvm");
    let installation = installation(false);
    let arguments = Line::new(&config, &bundle, &installation).arguments().unwrap();

    // What a saved machine resumes on: the same machine type, the same devices.
    assert_eq!(values("-machine", &arguments), [command_line::MACHINE_TYPE]);
    assert_eq!(values("-rtc", &arguments), ["base=localtime"]);
    assert_eq!(values("-uuid", &arguments), ["4f2b1c9e-3a5d-4e6f-8a7b-9c0d1e2f3a4b"]);
    assert!(arguments.contains(&"-no-reboot".to_string()) && arguments.contains(&"-S".to_string()));
    assert_eq!(values("-serial", &arguments), ["chardev:console"]);
    // QEMU listens for its machine protocol and the agent's line, so that a service that restarts finds them.
    let chardevs = values("-chardev", &arguments);
    assert!(chardevs.contains(&"socket,id=monitor,path=/tmp/swiftvm-501/00000000/0123456789abcdef/qmp.sock,server=on,wait=off".into()));
    assert!(chardevs.contains(&"socket,id=agent,path=/tmp/swiftvm-501/00000000/0123456789abcdef/agent.sock,server=on,wait=off".into()));
    assert!(chardevs.contains(&"socket,id=console,fd=3".into()));
    // One card per interface, the one whose cable is out too, on the descriptors after the console.
    let netdevs = objects("-netdev", &arguments);
    assert_eq!(netdevs.iter().map(|netdev| netdev["local"]["str"].clone()).collect::<Vec<_>>(), [json!("4"), json!("5")]);
    let devices = objects("-device", &arguments);
    let cards: Vec<_> = devices.iter().filter(|device| device["driver"] == "virtio-net-pci").map(|device| device["mac"].clone()).collect();
    assert_eq!(cards, [json!("02:00:00:00:00:01"), json!("02:00:00:00:00:02")]);
    // The app hands the display's one client over itself.
    assert_eq!(values("-vnc", &arguments), ["none"]);
    // Devices are written as the app wrote them, keys in order.
    assert!(arguments.contains(&r#"{"driver":"qemu-xhci","id":"usb","p2":15,"p3":15}"#.to_string()));
    assert!(
        arguments.contains(&r#"{"bus":"serial.0","chardev":"agent","driver":"virtserialport","name":"org.swiftvm.agent"}"#.to_string())
    );
    assert!(devices.contains(&json!({"driver": "nvme", "drive": "disk0", "serial": "swiftvm0"})));
    // No device has a place in the boot order: given one, the firmware wouldn't look at the installer.
    assert!(devices.iter().all(|device| device.get("bootindex").is_none()));
    // Windows reads a disc image's file system only from a drive for discs.
    let disc = command_line::image_device_id(&image(&fixture, 0));
    assert!(devices.iter().any(|device| device["driver"] == "usb-bot" && device["id"] == disc.as_str()));
    assert!(devices.iter().any(|device| device["driver"] == "scsi-cd" && device["bus"] == format!("{disc}.0")));
    assert!(
        devices
            .iter()
            .any(|device| device["driver"] == "usb-storage" && device["id"] == command_line::image_device_id(&image(&fixture, 1)))
    );
    // Node names fit in QEMU's 31 characters.
    let nodes: Vec<String> = objects("-blockdev", &arguments).iter().map(|node| node["node-name"].as_str().unwrap().to_string()).collect();
    assert_eq!(nodes.len(), 3);
    assert!(nodes.iter().all(|node| node.len() <= 31));
    // The sound card is there for a fresh start, and left out of a restore, which plugs it in after.
    assert!(devices.iter().any(|device| device["driver"] == "usb-audio"));
    let mut restoring = Line::new(&config, &bundle, &installation);
    restoring.restoring = true;
    let restored = restoring.arguments().unwrap();
    assert!(!objects("-device", &restored).iter().any(|device| device["driver"] == "usb-audio"));
    assert_eq!(values("-incoming", &restored), ["defer"]);
}

#[test]
fn a_tpm_is_on_the_line_after_the_network_cards() {
    let config = config(&fixture());
    let bundle = Bundle::new("/Machines/Windows.swiftvm");
    let installation = installation(false);
    let mut line = Line::new(&config, &bundle, &installation);
    line.tpm = true;
    let arguments = line.arguments().unwrap();
    assert!(values("-chardev", &arguments).contains(&"socket,id=tpm,fd=6".into()));
    assert_eq!(values("-tpmdev", &arguments), ["emulator,id=tpm0,chardev=tpm"]);
    assert!(objects("-device", &arguments).iter().any(|device| device["driver"] == "tpm-crb-device"));

    // A machine resumes with the TPM it was saved with, whatever its settings say by then.
    assert!(command_line::attaches_tpm(&config, true, None).unwrap());
    assert!(!command_line::attaches_tpm(&config, false, None).unwrap());
    assert!(!command_line::attaches_tpm(&config, true, Some(false)).unwrap());
    assert!(command_line::attaches_tpm(&config, false, Some(true)).is_err());
    let mut linux = fixture();
    linux["os"]["family"] = json!("linux");
    assert!(!command_line::attaches_tpm(&self::config(&linux), true, None).unwrap());
}

#[test]
fn a_restored_machine_has_each_drive_in_the_port_it_was_saved_in() {
    let fixture = fixture();
    let config = config(&fixture);
    let bundle = Bundle::new("/Machines/Windows.swiftvm");
    let installation = installation(false);
    let (installer, stick) = (image(&fixture, 0), image(&fixture, 1));
    let mut line = Line::new(&config, &bundle, &installation);
    line.restoring = true;
    line.usb_ports = HashMap::from([(stick.id, 4), (installer.id, 6)]);
    let ports = line.command_line().starting_usb_ports().unwrap();
    assert_eq!((ports[&stick.id], ports[&installer.id]), (4, 6));
    let devices = objects("-device", &line.arguments().unwrap());
    let port = |image: &RemovableImage| {
        devices.iter().find(|device| device["id"] == command_line::image_device_id(image).as_str()).map(|device| device["port"].clone())
    };
    assert_eq!((port(&installer), port(&stick)), (Some(json!("6")), Some(json!("4"))));
}

#[test]
fn graphics_acceleration_needs_its_qemu_and_cannot_resume_memory() {
    let mut fixture = fixture();
    fixture["installation"]["hasAcceleratedDisplayDriver"] = json!(true);
    let config = config(&fixture);
    let bundle = Bundle::new("/Machines/One, Two.swiftvm");
    let plain = installation(false);
    let mut line = Line::new(&config, &bundle, &plain);
    line.display = DisplayAdapter::VirtioGpu3d;
    line.spice = Some("/tmp/private,display/display.sock".into());
    assert!(line.arguments().is_err());

    let accelerated = installation(true);
    line.installation = &accelerated;
    let arguments = line.arguments().unwrap();
    assert_eq!(values("-accel", &arguments), [if cfg!(target_os = "macos") { "hvf,ipa-granule-size=4096" } else { "kvm" }]);
    assert!(values("-spice", &arguments)[0].starts_with("unix=on,addr=/tmp/private,,display/display.sock,"));
    assert!(values("-vnc", &arguments).is_empty());
    let gpu = objects("-device", &arguments).into_iter().find(|device| device["id"] == "gpu").unwrap();
    assert_eq!((gpu["driver"].clone(), gpu["hostmem"].clone()), (json!("virtio-ramfb-gl"), json!(8u64 << 30)));
    assert!(gpu.get("refresh_rate").is_none());
    line.refresh_rate = Some(120);
    let fast = objects("-device", &line.arguments().unwrap()).into_iter().find(|device| device["id"] == "gpu").unwrap();
    assert_eq!(fast["refresh_rate"], json!(120_000));
    // A comma in a path stays part of it.
    assert_eq!(values("-drive", &arguments), ["if=pflash,unit=1,format=raw,file=/Machines/One,, Two.swiftvm/efi-vars.fd"]);
    line.restoring = true;
    assert!(line.arguments().is_err());

    // Which adapter a start gets: memory saved expects the one it was saved with.
    assert_eq!(command_line::display_adapter(&config, &plain, false).unwrap(), DisplayAdapter::Framebuffer);
    assert_eq!(command_line::display_adapter(&config, &plain, true).unwrap(), DisplayAdapter::VirtioGpu);
    let mut driver = fixture.clone();
    driver["installation"]["hasAcceleratedDisplayDriver"] = json!(false);
    assert_eq!(command_line::display_adapter(&self::config(&driver), &plain, false).unwrap(), DisplayAdapter::VirtioGpu);
}

#[test]
fn a_linux_machine_has_its_own_clock_console_setup_disc_and_folders() {
    let folder = scratch();
    let projects = folder.join("Projects, old");
    std::fs::create_dir_all(&projects).unwrap();
    let mut fixture = fixture();
    fixture["os"]["family"] = json!("linux");
    fixture["removableImages"] = json!([]);
    fixture["installation"]["attachesSeedImage"] = json!(true);
    fixture["sharedFolders"] = json!([
        {"id": "E5F6A7B8-C9D0-4E1F-8A2B-3C4D5E6F7081", "name": "Projects", "path": projects, "readOnly": false},
        {"id": "F6A7B8C9-D0E1-4F2A-8B3C-4D5E6F708192", "name": "Away", "path": "/Volumes/Gone/Away", "readOnly": true},
    ]);
    let config = config(&fixture);
    let bundle = Bundle::new(folder.join("Arch.swiftvm"));
    std::fs::create_dir_all(&bundle.path).unwrap();
    std::fs::write(bundle.seed_image(), [0u8; 16]).unwrap();
    let installation = installation(false);
    let mut line = Line::new(&config, &bundle, &installation);
    line.display = DisplayAdapter::VirtioGpu;
    let arguments = line.arguments().unwrap();
    assert_eq!(values("-rtc", &arguments), ["base=utc"]);
    assert!(values("-serial", &arguments).is_empty());
    let devices = objects("-device", &arguments);
    assert!(devices.iter().any(|device| device["driver"] == "virtconsole"));
    // The setup disc is a virtio disk, there before cloud-init looks for it.
    assert!(devices.iter().any(|device| device["driver"] == "virtio-blk-pci" && device["serial"] == "swiftvm-seed"));
    // Only the folder that is there, by the tag its agent mounts it by.
    let escaped = projects.to_string_lossy().replace(',', ",,");
    assert_eq!(values("-fsdev", &arguments), [format!("local,id=share0,path={escaped},security_model=none")]);
    assert!(devices.iter().any(|device| device["driver"] == "virtio-9p-pci" && device["mount_tag"] == "swiftvm-e5f6a7b8"));
}

#[test]
fn an_installer_disc_gets_its_key_only_while_the_disk_is_empty() {
    let folder = scratch();
    let config = config(&fixture());
    let bundle = Bundle::new(folder.clone());
    std::fs::write(folder.join("disk.img"), []).unwrap();
    assert!(command_line::boots_installer(&config, &bundle));
    std::fs::write(folder.join("disk.img"), vec![1u8; 32 << 20]).unwrap();
    assert!(!command_line::boots_installer(&config, &bundle));
}

// MARK: - Files shared with the app

#[test]
fn the_configuration_reads_as_the_app_wrote_it_old_bundles_too() {
    let config = config(&fixture());
    assert_eq!(config.name, "Windows");
    assert_eq!(config.network_interfaces.len(), 2);
    assert!(!config.network_interfaces[1].is_connected);
    assert_eq!(config.display.adapter, Some(DisplayAdapter::VirtioGpu));
    assert_eq!(config.removable_images().len(), 2);
    // Before drives, the one installer disc was part of the installation section.
    let mut old = fixture();
    let object = old.as_object_mut().unwrap();
    object.remove("removableImages");
    object.remove("audio");
    object.remove("boot");
    old["installation"]["installMediaPath"] = json!("/Downloads/Windows.iso");
    let old = self::config(&old);
    assert_eq!(old.removable_images(), [RemovableImage { id: old.id, path: "/Downloads/Windows.iso".into(), read_only: true }]);
    assert!(old.audio.output_enabled && old.boot.tpm);
    let mut newer = fixture();
    newer["schemaVersion"] = json!(2);
    assert!(MachineConfig::parse(&serde_json::to_vec(&newer).unwrap()).is_err());
}

#[test]
fn a_state_the_app_saved_resumes_with_its_drives_ports_and_tpm() {
    let folder = scratch();
    let path = folder.join("state.vzvmsave");
    // As the app wrote it: its header, then QEMU's part from 4096 on.
    let stick = "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E";
    let mut file = b"SwiftVM QEMU machine state 1\n".to_vec();
    file.extend(format!(r#"{{"usbPorts":{{"{stick}":4}},"hasTPM":true}}"#).as_bytes());
    file.resize(saved_state::SIZE as usize, 0);
    file.extend(b"QEVM");
    std::fs::write(&path, &file).unwrap();
    let header = SavedStateHeader::read(&path).unwrap();
    assert!(header.has_tpm);
    assert_eq!(header.usb_ports.values().copied().collect::<Vec<_>>(), [4]);

    // Written over what QEMU wrote, without touching it.
    let written = SavedStateHeader { usb_ports: HashMap::from([(Id(uuid::Uuid::new_v4()), 9)]), has_tpm: false };
    written.write_into(&path).unwrap();
    assert_eq!(SavedStateHeader::read(&path).unwrap(), written);
    assert_eq!(&std::fs::read(&path).unwrap()[saved_state::SIZE as usize..], b"QEVM");
    // Saved before machines had a TPM.
    std::fs::write(&path, b"SwiftVM QEMU machine state 1\n{\"usbPorts\":{}}").unwrap();
    assert!(!SavedStateHeader::read(&path).unwrap().has_tpm);
    std::fs::write(&path, b"QEVM").unwrap();
    assert!(SavedStateHeader::read(&path).is_err());
}

#[test]
fn only_the_machines_own_qemu_and_tpm_are_taken_for_leftovers() {
    let id = uuid::Uuid::new_v4();
    let arguments =
        |program: &str, uuid: &str| vec![program.to_string(), "-name".into(), "Windows".into(), "-uuid".into(), uuid.to_string()];
    assert!(process::is_qemu(&arguments("/Old App.app/Contents/Helpers/QEMU/bin/qemu-system-aarch64", &id.to_string()), &id));
    assert!(!process::is_qemu(&arguments("qemu-system-aarch64", &uuid::Uuid::new_v4().to_string()), &id));
    assert!(!process::is_qemu(&arguments("/bin/sleep", &id.to_string()), &id));
    // What swtpm says whenever QEMU goes is no reason.
    assert_eq!(tpm::complaint("swtpm: Data client disconnected\n"), None);
    assert_eq!(
        tpm::complaint("swtpm: SWTPM_NVRAM_Lock_Linear: Could not lock backend-uri\nswtpm: Data client disconnected\n").as_deref(),
        Some("SWTPM_NVRAM_Lock_Linear: Could not lock backend-uri")
    );
    assert_eq!(
        process::complaint("qemu-system-aarch64: -device nvme: warning: x\nqemu-system-aarch64: Could not open 'disk.img'").as_deref(),
        Some("Could not open 'disk.img'")
    );
}

#[test]
fn a_process_gets_its_lines_as_three_and_on_and_writes_its_log_itself() {
    let folder = scratch();
    let log = folder.join("logs/out.log");
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let (ours, theirs) = swiftvm_qemu::fdpass::socket_pair(libc::SOCK_STREAM).unwrap();
        let mut child = process::launch(process::Launch {
            program: Path::new("/bin/sh"),
            arguments: &["-c".into(), "echo said; echo line >&3".into()],
            descriptors: vec![theirs],
            log: &log,
            pid_file: &folder.join("sh.pid"),
            directory: &folder,
            environment: Default::default(),
        })
        .unwrap();
        child.wait().await.unwrap();
        let mut line = String::new();
        let stream = std::os::unix::net::UnixStream::from(ours);
        std::io::BufRead::read_line(&mut std::io::BufReader::new(stream), &mut line).unwrap();
        assert_eq!(line, "line\n");
    });
    assert_eq!(process::last_output(&log), "said");
    assert!(process::read_pid_file(&folder.join("sh.pid")).is_some());
}

// MARK: - The mouse, the keyboard and pictures

#[test]
fn keys_are_pressed_where_a_pc_has_them() {
    let codes = |steps: &[InputStep]| -> Vec<(u16, bool)> {
        steps.iter().filter_map(|step| if let InputStep::Key { code, down } = step { Some((*code, *down)) } else { None }).collect()
    };
    // A capital letter is its key with Shift; Command is the Windows key, after 0xE0.
    let typed = input::key_steps(&Keys { text: Some("A!".into()), keys: Some(vec!["cmd+r".into(), "ctrl++".into()]) }).unwrap();
    assert_eq!(
        codes(&typed),
        [
            (0x2A, true),
            (0x1E, true),
            (0x1E, false),
            (0x2A, false),
            (0x2A, true),
            (0x02, true),
            (0x02, false),
            (0x2A, false),
            (0xDB, true),
            (0x13, true),
            (0x13, false),
            (0xDB, false),
            (0x1D, true),
            (0x2A, true),
            (0x0D, true),
            (0x0D, false),
            (0x2A, false),
            (0x1D, false),
        ]
    );
    assert!(matches!(input::key_steps(&Keys { text: Some("é".into()), keys: None }), Err(input::InputError::NotOnTheKeyboard('é'))));
    assert!(input::key_steps(&Keys { text: None, keys: Some(vec!["hyper+a".into()]) }).is_err());
    assert!(input::key_steps(&Keys::default()).is_err());
}

#[test]
fn a_click_arrives_from_aside_and_stays_on_the_screen() {
    let click = Pointer {
        action: PointerAction::Click,
        x: 99,
        y: 10,
        button: None,
        count: Some(2),
        to_x: None,
        to_y: None,
        delta_x: None,
        delta_y: None,
    };
    let pointers: Vec<(i64, i64, u8)> = input::pointer_steps(&click, 100, 50)
        .unwrap()
        .into_iter()
        .filter_map(|step| if let InputStep::Pointer { x, y, buttons } = step { Some((x, y, buttons)) } else { None })
        .collect();
    assert_eq!(pointers, [(97, 10, 0), (99, 10, 0), (99, 10, 1), (99, 10, 0), (99, 10, 1), (99, 10, 0)]);
    assert!(input::pointer_steps(&Pointer { x: 100, ..click.clone() }, 100, 50).is_err());
    assert!(input::pointer_steps(&Pointer { count: Some(4), ..click }, 100, 50).is_err());
}

#[test]
fn a_picture_of_the_display_has_four_bytes_a_pixel_blue_first() {
    let mut ppm = b"P6\n2 1\n255\n".to_vec();
    ppm.extend([10, 20, 30, 40, 50, 60]);
    assert_eq!(input::ppm_to_bgrx(&ppm), Some((2, 1, vec![30, 20, 10, 255, 60, 50, 40, 255])));
    assert_eq!(input::ppm_to_bgrx(b"P6\n2 1\n255\n\x01"), None);
}

// MARK: - The lines

#[tokio::test]
async fn qmp_answers_commands_by_id_passes_events_on_and_says_when_qemu_has_gone() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    let qemu = tokio::spawn(async move {
        let (reader, mut writer) = theirs.into_split();
        let mut reader = BufReader::new(reader);
        writer.write_all(b"{\"QMP\": {\"version\": {}}}\n").await.unwrap();
        let mut line = String::new();
        for _ in 0..3 {
            line.clear();
            reader.read_line(&mut line).await.unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            let id = request["id"].clone();
            let answer = match request["execute"].as_str().unwrap() {
                "query-status" => {
                    writer.write_all(b"{\"event\": \"SHUTDOWN\", \"data\": {\"reason\": \"guest-reset\"}}\n").await.unwrap();
                    json!({"return": {"running": true}, "id": id})
                }
                "nonsense" => json!({"error": {"class": "CommandNotFound", "desc": "The command nonsense has not been found"}, "id": id}),
                _ => json!({"return": {}, "id": id}),
            };
            writer.write_all(format!("{answer}\n").as_bytes()).await.unwrap();
        }
    });
    let (qmp, mut events) = Qmp::open(ours, Duration::from_secs(5)).await.unwrap();
    assert_eq!(qmp.execute("query-status", None).await.unwrap(), json!({"running": true}));
    assert_eq!(events.recv().await.unwrap().data["reason"], "guest-reset");
    assert_eq!(qmp.execute("nonsense", None).await, Err(QemuError::Refused("The command nonsense has not been found".into())));
    qemu.await.unwrap();
    // QEMU hung up: the events end, and nothing waits for an answer.
    assert!(events.recv().await.is_none());
    assert_eq!(qmp.execute("cont", None).await, Err(QemuError::Disconnected));
}

/// The agent's end of the line, pretended: it says hello, takes connections to port 7, which echoes, and
/// refuses the rest.
async fn agent(line: UnixStream) {
    let (mut reader, mut writer) = line.into_split();
    writer.write_all(&ChannelFrame::hello().encoded()).await.unwrap();
    let mut frames = FrameReader::default();
    let mut buffer = vec![0u8; 65536];
    loop {
        let count = match reader.read(&mut buffer).await {
            Ok(0) | Err(_) => return,
            Ok(count) => count,
        };
        for frame in frames.receive(&buffer[..count]) {
            let answer = match frame.kind {
                FrameKind::Open if frame.payload == 7u32.to_be_bytes() => ChannelFrame::new(FrameKind::Accept, frame.connection, vec![]),
                FrameKind::Open => ChannelFrame::new(FrameKind::Refuse, frame.connection, vec![]),
                FrameKind::Data => ChannelFrame::new(FrameKind::Data, frame.connection, frame.payload.to_ascii_uppercase()),
                FrameKind::End => ChannelFrame::new(FrameKind::End, frame.connection, vec![]),
                _ => continue,
            };
            writer.write_all(&answer.encoded()).await.unwrap();
        }
    }
}

#[tokio::test]
async fn a_connection_over_the_agents_line_carries_both_ways_and_each_way_ends_by_itself() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    let channel = AgentChannel::start(ours);
    tokio::spawn(agent(theirs));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !channel.has_agent() {
        assert!(tokio::time::Instant::now() < deadline, "the agent didn't say hello");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(channel.connect(9, Duration::from_secs(2)).await.err(), Some(ChannelError::Refused(9)));
    let mut connection = channel.connect(7, Duration::from_secs(2)).await.unwrap();
    connection.write_all(b"hello").await.unwrap();
    connection.shutdown().await.unwrap();
    let mut answer = String::new();
    connection.read_to_string(&mut answer).await.unwrap();
    assert_eq!(answer, "HELLO");

    // Once the agent has left, nothing opens until one says hello again.
    channel.agent_left();
    assert_eq!(channel.connect(7, Duration::from_secs(1)).await.err(), Some(ChannelError::NoAgent));
}

#[test]
fn frames_found_again_after_what_an_agent_left_half_sent() {
    let mut reader = FrameReader::default();
    let mut bytes = vec![4, 0, 0, 0, 1, 0, 0, 0, 9, 1, 2];
    reader.reset();
    bytes.extend(ChannelFrame::hello().encoded());
    bytes.extend(ChannelFrame::new(FrameKind::Data, 3, b"ok".to_vec()).encoded());
    let frames = reader.receive(&bytes);
    assert_eq!(frames.iter().map(|frame| frame.kind).collect::<Vec<_>>(), [FrameKind::Hello, FrameKind::Data]);
    assert_eq!(frames[1].payload, b"ok");
}

#[test]
fn each_direct3d_backend_tells_the_render_server_which_half_and_library_to_run() {
    let installation = installation(true);
    let libraries = ["NPT_D3D11_LIBRARY_PATH", "NPT_D3D12_LIBRARY_PATH", "NPT_DXGI_LIBRARY_PATH"];
    let dxmt = installation.environment(Path::new("/tmp/gpu"), None);
    assert_eq!(dxmt["NPT_BACKEND"], "dxmt");
    assert!(libraries.iter().all(|name| dxmt[*name] == "/App/Contents/Helpers/QEMU/lib/libdxmt-native.dylib"));
    // The guest is offered Direct3D 12 only by a backend that has it.
    assert!(!dxmt.contains_key("NPT_CAPSET_D3D12") && !dxmt.contains_key("D3DMETAL_FRAMEWORK_PATH"));
    assert_eq!(dxmt["XDG_RUNTIME_DIR"], "/tmp/gpu");
    let framework = swiftvm_protocol::qemu::DirectX { backend: "d3dmetal".into(), framework: Some("/Support/D3DMetal.framework".into()) };
    let d3d_metal = installation.environment(Path::new("/tmp/gpu"), Some(&framework));
    assert_eq!((d3d_metal["NPT_BACKEND"].as_str(), d3d_metal["NPT_CAPSET_D3D12"].as_str()), ("d3dmetal", "1"));
    assert_eq!(d3d_metal["D3DMETAL_FRAMEWORK_PATH"], "/Support/D3DMetal.framework");
    assert!(libraries.iter().all(|name| d3d_metal[*name] == "/App/Contents/Helpers/QEMU/lib/libd3dmetal-native.dylib"));
}

#[test]
fn a_process_that_ended_counts_as_ended_before_it_is_collected() {
    // QEMU stays its first service's child, uncollected while that service lets go of it: the next one must
    // still see it end.
    let child = std::process::Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
    let pid = child.id() as i32;
    std::thread::sleep(Duration::from_millis(300));
    assert!(process::is_alive(pid));
    assert!(process::has_ended(pid));
    drop(child);
}
