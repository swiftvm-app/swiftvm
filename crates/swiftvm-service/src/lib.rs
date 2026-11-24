//! `swiftvm serve`: the one service that SwiftVM's clients talk to, over API v1 on `service.sock`.
//!
//! It answers the handshake, events and the permission of programs itself, and runs the QEMU machines the
//! app hands it (`engine`). It passes every other request on to the app's `control.sock`, which still does
//! that work. See `docs/tech/api.md`.

mod connection;
mod engine;
mod events;
mod lines;
mod permission;
mod transport;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use swiftvm_protocol::ControlPaths;
use tokio::sync::watch;

/// What a service is for, and what it may do.
#[derive(Debug, Clone)]
pub struct Config {
    pub paths: ControlPaths,
    /// What the app is called, for when it isn't running.
    pub app_name: String,
    /// The service's own program. It stops when the file is replaced, and is always allowed to connect,
    /// with the rest of the app it is in.
    pub program: PathBuf,
    /// Whether to stop when the program file is replaced, by an update or a new build.
    pub watches_program: bool,
    /// Whether the service's own program, and the app it is in, need no permission.
    pub trusts_own_program: bool,
    /// The QEMU that runs machines: the one next to the program, unless another is named. `None` without one.
    pub qemu: Option<swiftvm_qemu::installation::Installation>,
    /// Where the machines' runtime folders are, with their sockets.
    pub runtime: PathBuf,
}

impl Config {
    pub fn new(paths: ControlPaths, app_name: impl Into<String>, program: PathBuf) -> Self {
        let qemu = swiftvm_qemu::installation::Installation::find(&program);
        let runtime = swiftvm_qemu::runtime::root_for(&paths.data);
        Config { paths, app_name: app_name.into(), program, watches_program: true, trusts_own_program: true, qemu, runtime }
    }
}

/// What every connection shares.
pub(crate) struct Service {
    pub config: Config,
    pub permission: permission::Permission,
    pub events: Arc<events::Events>,
    pub engine: Arc<engine::Engine>,
    /// Becomes `true` when the service is to stop: it listens no more, and lets the work under way end.
    pub stopping: watch::Sender<bool>,
}

impl Service {
    pub fn stop(&self) {
        self.stopping.send_replace(true);
    }

    pub fn is_stopping(&self) -> bool {
        *self.stopping.borrow()
    }
}

/// Returns once the service is stopping.
pub(crate) async fn until_stopped(stopping: &mut watch::Receiver<bool>) {
    let _ = stopping.wait_for(|stop| *stop).await;
}

/// A line in the service's log, which is its error output.
pub(crate) fn log(message: &str) {
    eprintln!("{} swiftvm serve[{}]: {message}", swiftvm_protocol::wire::Timestamp::now().rfc3339(), std::process::id());
}

/// Runs the service until it is told to stop, its program is replaced, or a signal ends it. Returns the
/// status to exit with. Another service that is already running for the same folder is no failure.
pub fn run(config: Config) -> i32 {
    let runtime = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            log(&format!("The service couldn't start: {error}"));
            return 1;
        }
    };
    runtime.block_on(serve(config))
}

async fn serve(config: Config) -> i32 {
    if let Err(error) = transport::make_private_folder(&config.paths.data) {
        log(&format!("{} couldn't be made: {error}", config.paths.data.display()));
        return 1;
    }
    let lock = match transport::lock(&config.paths.service_lock()) {
        Ok(Some(lock)) => lock,
        Ok(None) => {
            log("Another service is already running for this folder.");
            return 0;
        }
        Err(error) => {
            log(&format!("{} couldn't be locked: {error}", config.paths.service_lock().display()));
            return 1;
        }
    };
    let listener = match transport::Listener::bind(&config.paths.service_socket()) {
        Ok(listener) => listener,
        Err(error) => {
            log(&format!("Couldn't listen on {}: {error}", config.paths.service_socket().display()));
            return 1;
        }
    };
    log(&format!("Listening on {}, for {}.", config.paths.service_socket().display(), config.app_name));
    let (stopping, mut stopped) = watch::channel(false);
    let engine = engine::Engine::new(config.runtime.clone(), config.qemu.clone());
    // The machines an earlier service left running, before anyone asks about them.
    engine.adopt_all().await;
    let service = Arc::new(Service {
        permission: permission::Permission::new(&config),
        events: Arc::new(events::Events::new()),
        engine,
        config,
        stopping,
    });
    tokio::spawn(stop_on_signals(service.clone()));
    if service.config.watches_program {
        tokio::spawn(stop_when_replaced(service.clone()));
    }
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok(stream) => {
                    connections.spawn(connection::handle(stream, service.clone()));
                }
                Err(error) => log(&format!("A connection couldn't be taken: {error}")),
            },
            _ = crate::until_stopped(&mut stopped) => break,
        }
        while connections.try_join_next().is_some() {}
    }
    // The machines go on running, for the next service to take on: it may begin as soon as the lock is free.
    service.engine.shutdown().await;
    // The next client starts another service, which may begin at once: the socket and the lock are its.
    listener.remove();
    drop(lock);
    if !connections.is_empty() {
        log(&format!("Stopping, once the {} connection(s) still at work are done.", connections.len()));
    }
    while connections.join_next().await.is_some() {}
    log("Stopped.");
    0
}

/// Stops at SIGINT or SIGTERM, letting the work under way end. A second one ends the service at once.
async fn stop_on_signals(service: Arc<Service>) {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut interrupt), Ok(mut terminate)) = (signal(SignalKind::interrupt()), signal(SignalKind::terminate())) else {
        return;
    };
    for count in 0.. {
        tokio::select! {
            _ = interrupt.recv() => {}
            _ = terminate.recv() => {}
        }
        if count > 0 {
            log("Stopped at once, by a second signal.");
            std::process::exit(130);
        }
        log("Stopping, as a signal asked.");
        service.stop();
    }
}

/// Stops when the program file changes, so that the next client starts the new one: after an update of
/// the app, or a new build of the tool.
async fn stop_when_replaced(service: Arc<Service>) {
    let program = service.config.program.clone();
    let original = transport::FileIdentity::of(&program);
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if service.is_stopping() {
            return;
        }
        if transport::FileIdentity::of(&program) != original {
            log(&format!("Stopping: {} has been replaced.", program.display()));
            service.stop();
            return;
        }
    }
}
