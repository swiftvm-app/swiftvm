//! The service's QEMU engine, with a stand-in for QEMU that speaks its machine protocol: a machine handed
//! to the service keeps running when the service restarts, and the next service takes it on.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use swiftvm_protocol::ControlPaths;
use swiftvm_qemu::installation::Installation;

static COUNT: AtomicUsize = AtomicUsize::new(0);

/// QEMU, pretended, by this test program when it is started under QEMU's name: it listens where its command
/// line says, answers its machine protocol, remembers whether it was let run, and ends when asked to quit
/// or when the guest is told to power down.
fn fake_qemu() -> ! {
    use std::os::unix::net::UnixListener;
    let arguments: Vec<String> = std::env::args().collect();
    let path_of = |name: &str| {
        let prefix = format!("socket,id={name},");
        let value = arguments.iter().find(|value| value.starts_with(&prefix)).unwrap();
        value.split(',').find_map(|part| part.strip_prefix("path=")).unwrap().to_string()
    };
    let agent = UnixListener::bind(path_of("agent")).unwrap();
    std::thread::spawn(move || {
        for connection in agent.incoming().flatten() {
            let _ = std::io::copy(&mut &connection, &mut std::io::sink());
        }
    });
    let monitor = UnixListener::bind(path_of("monitor")).unwrap();
    let mut status = "prelaunch";
    for connection in monitor.incoming().flatten() {
        let mut writer = connection.try_clone().unwrap();
        let mut send = |message: Value| writer.write_all(format!("{message}\n").as_bytes()).is_ok();
        send(json!({"QMP": {"version": {}, "capabilities": []}}));
        for line in BufReader::new(connection).lines() {
            let Ok(line) = line else { break };
            let request: Value = serde_json::from_str(&line).unwrap();
            let id = request["id"].clone();
            match request["execute"].as_str().unwrap() {
                "query-status" => send(json!({"return": {"status": status, "running": status == "running"}, "id": id})),
                "cont" => {
                    status = "running";
                    send(json!({"return": {}, "id": id}))
                }
                "qom-list" => send(json!({"return": [], "id": id})),
                command @ ("quit" | "system_powerdown") => {
                    send(json!({"return": {}, "id": id}));
                    let reason = if command == "quit" { "host-qmp-quit" } else { "guest-shutdown" };
                    send(json!({"event": "SHUTDOWN", "data": {"reason": reason}}));
                    std::process::exit(0);
                }
                _ => send(json!({"return": {}, "id": id})),
            };
        }
    }
    std::process::exit(0)
}

fn main() {
    if std::env::args().next().is_some_and(|program| program.ends_with("qemu-system-aarch64")) {
        fake_qemu();
    }
    let tests: [(&str, fn()); 2] = [
        ("a_machine_outlives_the_service_and_the_next_one_takes_it_on", a_machine_outlives_the_service_and_the_next_one_takes_it_on),
        ("a_machine_that_cannot_start_says_why", a_machine_that_cannot_start_says_why),
    ];
    for (name, test) in tests {
        test();
        println!("test {name} ... ok");
    }
}

struct Setup {
    folder: PathBuf,
    paths: ControlPaths,
    installation: Installation,
    runtime: PathBuf,
    bundle: PathBuf,
}

impl Setup {
    fn new() -> Self {
        let number = COUNT.fetch_add(1, Ordering::Relaxed);
        let folder = std::env::temp_dir().join(format!("swiftvm-engine-{}-{number}", std::process::id()));
        let qemu = folder.join("qemu");
        std::fs::create_dir_all(qemu.join("share")).unwrap();
        // This program, under QEMU's name, so that the next service knows it for the machine's.
        let program = qemu.join("qemu-system-aarch64");
        std::os::unix::fs::symlink(std::env::current_exe().unwrap(), &program).unwrap();
        for file in ["edk2-aarch64-code.fd", "edk2-arm-vars.fd"] {
            std::fs::write(qemu.join("share").join(file), [0u8; 64]).unwrap();
        }
        let bundle = folder.join("Windows.swiftvm");
        std::fs::create_dir_all(&bundle).unwrap();
        let config = json!({
            "id": "4F2B1C9E-3A5D-4E6F-8A7B-9C0D1E2F3A4B", "name": "Windows", "os": {"family": "windows"}, "engine": "qemu",
            "cpuCount": 2, "memorySize": 2147483648u64, "disks": [], "removableImages": [],
            "display": {"widthInPixels": 1024, "heightInPixels": 768, "pixelsPerInch": 144},
            "audio": {"outputEnabled": false, "inputEnabled": false}, "boot": {"tpm": false},
        });
        std::fs::write(bundle.join("config.json"), config.to_string()).unwrap();
        let data = folder.join("data");
        std::fs::create_dir_all(&data).unwrap();
        Setup {
            paths: ControlPaths { data },
            installation: Installation::new(program, qemu.join("share")),
            // Short, as sockets' paths are.
            runtime: PathBuf::from(format!("/tmp/svt-{}-{number}", std::process::id())),
            bundle,
            folder,
        }
    }

    fn start_service(&self) -> Service {
        let mut config = swiftvm_service::Config::new(self.paths.clone(), "SwiftVM Test", std::env::current_exe().unwrap());
        config.watches_program = false;
        config.qemu = Some(self.installation.clone());
        config.runtime = self.runtime.clone();
        let thread = std::thread::spawn(move || swiftvm_service::run(config));
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(self.paths.service_socket()).is_err() {
            assert!(Instant::now() < deadline, "the service didn't listen");
            std::thread::sleep(Duration::from_millis(10));
        }
        Service { socket: self.paths.service_socket(), thread: Some(thread) }
    }
}

impl Drop for Setup {
    fn drop(&mut self) {
        // A stand-in left running by a test that failed.
        if let Ok(pid) = std::fs::read_to_string(self.bundle.join("qemu.pid")) {
            // SAFETY: kill has no memory effects.
            unsafe { libc::kill(pid.trim().parse().unwrap_or(0), libc::SIGKILL) };
        }
        let _ = std::fs::remove_dir_all(&self.folder);
        let _ = std::fs::remove_dir_all(&self.runtime);
    }
}

struct Service {
    socket: PathBuf,
    thread: Option<JoinHandle<i32>>,
}

impl Service {
    fn client(&self) -> Client {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut client = Client { reader: BufReader::new(stream.try_clone().unwrap()), stream };
        let answer = client.ask(json!({"id": 0, "command": "hello", "protocol": 1, "client": "test"}), &[]);
        assert_eq!(answer["ok"], true, "{answer}");
        client
    }

    fn stop(mut self) {
        let answer = self.client().ask(json!({"id": 1, "command": "service-stop"}), &[]);
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(self.thread.take().unwrap().join().unwrap(), 0);
    }
}

struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Client {
    /// Sends `request`, with `descriptors` riding along, and reads the answer.
    fn ask(&mut self, request: Value, descriptors: &[i32]) -> Value {
        let mut line = request.to_string().into_bytes();
        line.push(b'\n');
        let sent = swiftvm_qemu::fdpass::send(self.stream.as_raw_fd(), &line, descriptors).unwrap();
        self.stream.write_all(&line[sent..]).unwrap();
        self.line()
    }

    fn line(&mut self) -> Value {
        let mut line = String::new();
        self.reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or(Value::Null)
    }
}

fn machines(service: &Service) -> Vec<Value> {
    let answer = service.client().ask(json!({"id": 1, "command": "qemu-list"}), &[]);
    answer["qemuMachines"].as_array().cloned().unwrap_or_default()
}

fn wait_until(condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "waited too long");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn is_alive(pid: i64) -> bool {
    // SAFETY: kill with signal 0 only checks.
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn a_machine_outlives_the_service_and_the_next_one_takes_it_on() {
    let setup = Setup::new();
    let service = setup.start_service();
    let machine = "4F2B1C9E-3A5D-4E6F-8A7B-9C0D1E2F3A4B";

    // Started held, with its console's line handed over.
    let (console, qemu_end) = swiftvm_qemu::fdpass::socket_pair(libc::SOCK_STREAM).unwrap();
    let mut events = service.client();
    let started =
        events.ask(json!({"id": 1, "command": "qemu-start", "bundle": setup.bundle, "descriptors": ["console"]}), &[qemu_end.as_raw_fd()]);
    drop(qemu_end);
    assert_eq!(started["ok"], true, "{started}");
    assert_eq!(started["qemu"]["state"], "held");
    assert_eq!(started["qemu"]["adapter"], "framebuffer");
    let pid = started["qemu"]["pid"].as_i64().unwrap();
    // The bundle names it, for whoever finds it left behind.
    assert_eq!(std::fs::read_to_string(setup.bundle.join("qemu.pid")).unwrap().trim(), pid.to_string());
    let again = service.client().ask(json!({"id": 1, "command": "qemu-start", "bundle": setup.bundle}), &[]);
    assert_eq!(again["error"]["code"], "wrong-state", "{again}");

    let resumed = service.client().ask(json!({"id": 1, "command": "qemu-continue", "machine": machine}), &[]);
    assert_eq!(resumed["ok"], true, "{resumed}");
    assert_eq!(machines(&service)[0]["state"], "running");

    // The service stops: the stream that followed the start ends, and QEMU goes on.
    service.stop();
    assert_eq!(events.line(), Value::Null);
    assert!(is_alive(pid));

    // The next service finds it running, and hears it end.
    let service = setup.start_service();
    let found = machines(&service);
    assert_eq!(found.len(), 1);
    assert_eq!((found[0]["pid"].as_i64(), found[0]["state"].clone()), (Some(pid), json!("running")));
    let mut events = service.client();
    let attached = events.ask(json!({"id": 1, "command": "qemu-attach", "machine": machine}), &[]);
    assert_eq!(attached["ok"], true, "{attached}");
    let asked = service.client().ask(json!({"id": 1, "command": "qemu-powerdown", "machine": machine}), &[]);
    assert_eq!(asked["ok"], true, "{asked}");
    let ended = events.line();
    assert_eq!(ended["event"], "qemu-exited", "{ended}");
    assert_eq!(ended["exit"]["reason"], "guest-shutdown");
    assert_eq!(ended["exit"]["expected"], false);
    wait_until(|| machines(&service).is_empty());
    assert!(!Path::new(&setup.bundle.join("qemu.pid")).exists());
    drop(console);
    service.stop();
}

fn a_machine_that_cannot_start_says_why() {
    let setup = Setup::new();
    let service = setup.start_service();
    // Its network cards weren't handed over.
    let mut config: Value = serde_json::from_slice(&std::fs::read(setup.bundle.join("config.json")).unwrap()).unwrap();
    config["networkInterfaces"] = json!([{"id": "C3D4E5F6-A7B8-4C9D-8E0F-1A2B3C4D5E6F", "macAddress": "02:00:00:00:00:01"}]);
    std::fs::write(setup.bundle.join("config.json"), config.to_string()).unwrap();
    let answer = service.client().ask(json!({"id": 1, "command": "qemu-start", "bundle": setup.bundle}), &[]);
    assert_eq!(answer["error"]["code"], "bad-request", "{answer}");
    // A request about a machine the service doesn't run.
    let answer = service.client().ask(json!({"id": 1, "command": "qemu-pause", "machine": "4F2B1C9E-3A5D-4E6F-8A7B-9C0D1E2F3A4B"}), &[]);
    assert_eq!(answer["error"]["code"], "wrong-state", "{answer}");
    service.stop();
}
