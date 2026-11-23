//! The service, run as it runs for real, in front of a pretend app on a control socket of its own.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use swiftvm_protocol::ControlPaths;

static COUNT: AtomicUsize = AtomicUsize::new(0);

struct Running {
    paths: ControlPaths,
    service: Option<JoinHandle<i32>>,
}

impl Running {
    /// A service of its own, in a folder of its own. `trusts_itself` is whether this test program, which
    /// is the service's program here, needs no permission.
    fn start(trusts_itself: bool) -> Self {
        let folder = std::env::temp_dir().join(format!("swiftvm-svc-{}-{}", std::process::id(), COUNT.fetch_add(1, Ordering::Relaxed)));
        std::fs::create_dir_all(&folder).unwrap();
        let paths = ControlPaths { data: folder };
        let mut config = swiftvm_service::Config::new(paths.clone(), "SwiftVM Test", std::env::current_exe().unwrap());
        config.watches_program = false;
        config.trusts_own_program = trusts_itself;
        let service = std::thread::spawn(move || swiftvm_service::run(config));
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(paths.service_socket()).is_err() {
            assert!(Instant::now() < deadline, "the service didn't listen");
            std::thread::sleep(Duration::from_millis(10));
        }
        Running { paths, service: Some(service) }
    }

    fn connect(&self) -> Client {
        let stream = UnixStream::connect(self.paths.service_socket()).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        Client { reader: BufReader::new(stream.try_clone().unwrap()), stream }
    }

    /// A connection that has said hello and been let in.
    fn hello(&self) -> Client {
        let mut client = self.connect();
        let answer = client.ask(json!({"id": 0, "command": "hello", "protocol": 1, "client": "test"}));
        assert_eq!(answer["ok"], true, "{answer}");
        client
    }

    /// The app, pretended: each request it gets goes to `serve`, with the connection it came on.
    fn app(&self, serve: impl Fn(Value, UnixStream) + Send + Sync + 'static) -> App {
        let listener = UnixListener::bind(self.paths.socket()).unwrap();
        listener.set_nonblocking(true).unwrap();
        let (stop, stopped) = mpsc::channel::<()>();
        let serve = Arc::new(serve);
        let socket = self.paths.socket();
        let thread = std::thread::spawn(move || {
            while stopped.try_recv().is_err() {
                match listener.accept() {
                    Ok((connection, _)) => {
                        connection.set_nonblocking(false).unwrap();
                        let serve = serve.clone();
                        std::thread::spawn(move || {
                            let mut reader = BufReader::new(connection.try_clone().unwrap());
                            let mut line = String::new();
                            if reader.read_line(&mut line).unwrap_or(0) > 0 {
                                serve(serde_json::from_str(&line).unwrap(), connection);
                            }
                        });
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(5)),
                }
            }
            let _ = std::fs::remove_file(socket);
        });
        App { stop, thread: Some(thread) }
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        if let Some(service) = self.service.take() {
            if let Ok(stream) = UnixStream::connect(self.paths.service_socket()) {
                stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
                let mut client = Client { reader: BufReader::new(stream.try_clone().unwrap()), stream };
                client.ask(json!({"id": 0, "command": "hello", "protocol": 1, "client": "test"}));
                client.ask(json!({"id": 1, "command": "service-stop"}));
            }
            let _ = service.join();
        }
        let _ = std::fs::remove_dir_all(&self.paths.data);
    }
}

struct App {
    stop: mpsc::Sender<()>,
    thread: Option<JoinHandle<()>>,
}

impl App {
    /// Quits the app: nothing listens on its socket any more.
    fn quit(mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

impl Drop for App {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Client {
    fn send(&mut self, request: Value) {
        let _ = self.stream.write_all(format!("{request}\n").as_bytes());
    }

    fn line(&mut self) -> Value {
        let mut line = String::new();
        self.reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or(Value::Null)
    }

    fn ask(&mut self, request: Value) -> Value {
        self.send(request);
        self.line()
    }

    /// Whether the service has hung up.
    fn is_closed(&mut self) -> bool {
        let mut rest = Vec::new();
        matches!(self.reader.read_to_end(&mut rest), Ok(0))
    }
}

fn reply(connection: &mut UnixStream, answer: Value) {
    connection.write_all(format!("{answer}\n").as_bytes()).unwrap();
}

#[test]
fn a_client_says_hello_first_in_a_version_the_service_speaks() {
    let service = Running::start(true);
    let mut client = service.connect();
    let answer = client.ask(json!({"id": 3, "command": "list"}));
    assert_eq!((answer["id"].as_u64(), answer["error"]["code"].as_str()), (Some(3), Some("bad-request")));
    assert!(client.is_closed());

    let mut client = service.connect();
    let answer = client.ask(json!({"id": 0, "command": "hello", "protocol": 2, "client": "test"}));
    assert_eq!(answer["error"]["code"], "unsupported-protocol");
    assert!(client.is_closed());

    let mut client = service.connect();
    let answer = client.ask(json!({"id": 0, "command": "hello", "protocol": 1, "client": "test"}));
    assert_eq!(answer["service"]["protocol"], 1);
    assert_eq!(answer["service"]["app"]["running"], false);
}

#[test]
fn a_request_goes_to_the_app_and_its_answer_comes_back_with_the_id_and_code() {
    let service = Running::start(true);
    let mut client = service.hello();
    let answer = client.ask(json!({"id": 7, "command": "list"}));
    assert_eq!(answer["id"], 7);
    assert_eq!(answer["error"]["code"], "app-not-running");
    assert_eq!(answer["error"]["message"], "SwiftVM Test isn't running. Open the app first.");

    let _app = service.app(|request, mut connection| {
        // The app gets what it reads: no id, and targets in its own coding.
        assert!(request.get("id").is_none());
        match request["command"].as_str() {
            Some("control") => {
                assert_eq!(request["control"]["steps"][0]["target"], json!({"number": {"_0": 4}}));
                reply(&mut connection, json!({"ok": false, "error": "Automation is off.", "code": "automation-off", "machines": []}));
            }
            _ => reply(
                &mut connection,
                json!({"ok": true, "machines": [], "snapshots": [
                    {"id": "11111111-2222-3333-4444-555555555555", "name": "before", "createdAt": 785000000.5, "includesMemory": true}
                ]}),
            ),
        }
    });
    let answer = client.ask(json!({"id": 8, "command": "snapshots", "machine": "desk"}));
    assert_eq!((answer["id"].as_u64(), answer["ok"].as_bool()), (Some(8), Some(true)));
    assert_eq!(answer["snapshots"][0]["createdAt"], "2025-11-16T15:33:20.5Z");
    let control =
        json!({"id": 9, "command": "control", "machine": "desk", "control": {"steps": [{"action": "click", "target": {"number": 4}}]}});
    let answer = client.ask(control);
    assert_eq!(answer, json!({"id": 9, "ok": false, "error": {"code": "automation-off", "message": "Automation is off."}, "machines": []}));
}

#[test]
fn a_stream_is_carried_both_ways_and_its_end_passed_on() {
    let service = Running::start(true);
    let _app = service.app(|request, mut connection| {
        assert_eq!(request["command"], "job");
        // The answer and the first of the stream in one go: the service mustn't lose what follows it.
        connection.write_all(b"{\"ok\":true,\"machines\":[]}\nearly ").unwrap();
        let mut received = Vec::new();
        connection.read_to_end(&mut received).unwrap();
        connection.write_all(&received.to_ascii_uppercase()).unwrap();
        connection.write_all(b" done").unwrap();
    });
    let mut client = service.hello();
    let answer = client.ask(json!({"id": 1, "command": "job", "machine": "desk", "job": {"type": "exec", "arguments": ["cat"]}}));
    assert_eq!((answer["id"].as_u64(), answer["ok"].as_bool()), (Some(1), Some(true)));
    client.stream.write_all(b"hello").unwrap();
    client.stream.shutdown(std::net::Shutdown::Write).unwrap();
    let mut rest = String::new();
    client.reader.read_to_string(&mut rest).unwrap();
    assert_eq!(rest, "early HELLO done");
}

#[test]
fn a_watcher_hears_what_the_app_says_and_when_it_goes_away() {
    let service = Running::start(true);
    let (quit, quitting) = mpsc::channel::<()>();
    let quitting = Arc::new(std::sync::Mutex::new(quitting));
    let app = service.app(move |request, mut connection| match request["command"].as_str() {
        Some("list") => reply(&mut connection, json!({"ok": true, "machines": [], "creations": []})),
        Some("watch") => {
            reply(&mut connection, json!({"ok": true, "machines": []}));
            reply(
                &mut connection,
                json!({"event": "creation", "creation": {"name": "new", "system": "debian-13", "status": "Downloading", "fraction": 0.5}}),
            );
            let _ = quitting.lock().unwrap().recv();
        }
        _ => reply(&mut connection, json!({"ok": false, "error": "No.", "machines": []})),
    });
    let mut client = service.hello();
    let answer = client.ask(json!({"id": 2, "command": "watch"}));
    assert_eq!((answer["id"].as_u64(), answer["ok"].as_bool()), (Some(2), Some(true)));
    // The app was there when watching started, which the answer said: no event says it again.
    assert_eq!(client.line()["creation"]["fraction"], 0.5);
    app.quit();
    quit.send(()).unwrap();
    assert_eq!(client.line(), json!({"event": "app", "running": false}));
}

#[test]
fn a_program_is_asked_about_once_and_refused_without_the_app() {
    let service = Running::start(false);
    let mut client = service.connect();
    let answer = client.ask(json!({"id": 0, "command": "hello", "protocol": 1, "client": "test"}));
    assert_eq!(answer["error"]["code"], "not-allowed");
    assert!(answer["error"]["message"].as_str().unwrap().contains("swiftvm clients allow"), "{answer}");

    let asked = Arc::new(AtomicUsize::new(0));
    let counted = asked.clone();
    let program = std::env::current_exe().unwrap().canonicalize().unwrap();
    let expected: PathBuf = program.clone();
    let _app = service.app(move |request, mut connection| {
        assert_eq!(request["command"], "ask-permission");
        assert_eq!(request["program"].as_str().map(PathBuf::from), Some(expected.clone()));
        counted.fetch_add(1, Ordering::Relaxed);
        reply(&mut connection, json!({"ok": true, "machines": []}));
    });
    let mut client = service.hello();
    service.hello();
    assert_eq!(asked.load(Ordering::Relaxed), 1);
    let clients = client.ask(json!({"id": 1, "command": "clients"}));
    assert_eq!(clients["clients"][0]["path"].as_str().map(PathBuf::from), Some(program.clone()));
    assert_eq!(clients["clients"][0]["allowed"], true);
    // Refused from here on, without asking.
    let denied = client.ask(json!({"id": 2, "command": "clients-deny", "program": program.to_string_lossy()}));
    assert_eq!(denied["clients"][0]["allowed"], false);
    let answer = service.connect().ask(json!({"id": 0, "command": "hello", "protocol": 1, "client": "test"}));
    assert_eq!(answer["error"]["code"], "not-allowed");
    assert_eq!(asked.load(Ordering::Relaxed), 1);
    // This program may no longer say hello, so it stops the service on the connection it still has.
    assert_eq!(client.ask(json!({"id": 3, "command": "service-stop"}))["ok"], true);
}

#[test]
fn a_second_service_for_the_same_folder_leaves_it_to_the_first() {
    let service = Running::start(true);
    let config = swiftvm_service::Config::new(service.paths.clone(), "SwiftVM Test", std::env::current_exe().unwrap());
    assert_eq!(swiftvm_service::run(config), 0);
    // The first still listens.
    service.hello();
}
