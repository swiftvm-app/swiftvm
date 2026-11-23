//! `watch`: what changes, as the app tells it, passed on to every client that watches.
//!
//! While anyone watches, one connection to the app carries its events, and a broadcast hands each to
//! every watcher. Without the app, the watchers hear that it isn't running, and the service tries again
//! every second.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use swiftvm_protocol::wire::{ControlResponse, ErrorCode, Event, EventKind};
use tokio::io::AsyncReadExt;
use tokio::sync::broadcast;

use crate::connection::{Connection, ask_app};
use crate::{Service, lines};

/// Events a watcher may fall behind by before it is let go.
const BACKLOG: usize = 1024;

pub(crate) struct Events {
    sender: broadcast::Sender<Arc<[u8]>>,
    /// Whether the connection to the app's events is up or being made.
    is_following: Mutex<bool>,
    /// Whether following has found out whether the app is there, and is listening to it if it is. A
    /// watcher lists the machines only then, so that nothing changes unheard between its list and the
    /// first event.
    is_ready: tokio::sync::watch::Sender<bool>,
}

impl Events {
    pub fn new() -> Self {
        Events { sender: broadcast::channel(BACKLOG).0, is_following: Mutex::new(false), is_ready: tokio::sync::watch::channel(false).0 }
    }

    /// Returns once following is ready, or after a few seconds if it doesn't get there.
    async fn until_ready(&self) {
        let mut ready = self.is_ready.subscribe();
        let _ = tokio::time::timeout(Duration::from_secs(3), ready.wait_for(|ready| *ready)).await;
    }

    /// The events from here on, following the app's if nothing does yet.
    fn subscribe(self: &Arc<Self>, service: &Arc<Service>) -> broadcast::Receiver<Arc<[u8]>> {
        let mut is_following = self.is_following.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let receiver = self.sender.subscribe();
        if !*is_following {
            *is_following = true;
            tokio::spawn(follow(self.clone(), service.clone()));
        }
        receiver
    }

    /// Whether anyone still watches. When nobody does, following stops, and the next watcher starts it.
    fn keeps_following(&self) -> bool {
        let mut is_following = self.is_following.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.sender.receiver_count() == 0 {
            *is_following = false;
            self.is_ready.send_replace(false);
        }
        *is_following
    }

    fn send(&self, line: Vec<u8>) {
        let _ = self.sender.send(line.into());
    }

    fn app_event(running: bool) -> Event {
        Event { event: EventKind::App, machine: None, creation: None, guest_tools: None, setup: None, running: Some(running) }
    }

    fn send_app(&self, running: bool) {
        if let Ok(line) = serde_json::to_vec(&Self::app_event(running)) {
            self.send(line);
        }
    }
}

/// Follows the app's events for as long as anyone watches. Tells the watchers when the app goes away or
/// comes back, but not what it was when following started: they have just been told that.
async fn follow(events: Arc<Events>, service: Arc<Service>) {
    let mut was_running: Option<bool> = None;
    let mut stopping = service.stopping.subscribe();
    let mut note_running = |running: bool| {
        if was_running.is_some_and(|was| was != running) {
            events.send_app(running);
        }
        was_running = Some(running);
        events.is_ready.send_replace(true);
    };
    let mut checks = tokio::time::interval(Duration::from_secs(1));
    while events.keeps_following() && !service.is_stopping() {
        match ask_app(&service, None, &json!({"command": "watch"})).await {
            Ok((answer, mut reader, _writer)) => {
                note_running(true);
                if answer.get("ok") != Some(&Value::Bool(true)) {
                    // An app from before events: it is there, and has nothing to tell.
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(5)) => {}
                        _ = crate::until_stopped(&mut stopping) => return,
                    }
                    continue;
                }
                loop {
                    tokio::select! {
                        line = lines::read(&mut reader) => match line {
                            // Written the way the service writes its answers, with the keys in order.
                            Some(line) => match serde_json::from_slice::<Value>(&line) {
                                Ok(event) if event.is_object() => events.send(serde_json::to_vec(&event).unwrap_or(line)),
                                _ => {}
                            },
                            None => break,
                        },
                        _ = checks.tick() => {
                            if !events.keeps_following() {
                                return;
                            }
                        }
                        _ = crate::until_stopped(&mut stopping) => return,
                    }
                }
            }
            Err(_) => {
                note_running(false);
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {}
                    _ = crate::until_stopped(&mut stopping) => return,
                }
            }
        }
    }
}

/// Answers `watch` with the machines and creations there are, and then passes the events on until the
/// client hangs up, falls too far behind, or the service stops.
pub(crate) async fn watch(mut connection: Connection, id: u64) {
    let service = connection.service.clone();
    // Listening before asking, so that nothing that happens in between is missed. What happens is told
    // as it is now, so hearing of it twice does no harm.
    let mut receiver = service.events.subscribe(&service);
    service.events.until_ready().await;
    let mut is_app_missing = false;
    let answer = match ask_app(&service, Some(id), &json!({"command": "list"})).await {
        Ok((answer, _, _)) => answer,
        Err(failure) if failure.error.as_ref().is_some_and(|error| error.code == ErrorCode::AppNotRunning) => {
            // Nothing to list without the app. The first event says so.
            is_app_missing = true;
            serde_json::to_value(ControlResponse { creations: Some(Vec::new()), ..ControlResponse::success(Some(id)) }).unwrap_or_default()
        }
        Err(failure) => {
            connection.answer(&failure).await;
            return;
        }
    };
    if !lines::write_value(&mut connection.writer, &answer).await || answer.get("ok") != Some(&Value::Bool(true)) {
        return;
    }
    if is_app_missing && !lines::write_value(&mut connection.writer, &Events::app_event(false)).await {
        return;
    }
    let mut stopping = service.stopping.subscribe();
    let mut ignored = [0u8; 1024];
    loop {
        tokio::select! {
            event = receiver.recv() => match event {
                Ok(line) => {
                    if !lines::write(&mut connection.writer, &line).await {
                        return;
                    }
                }
                // Fallen behind, or the service is going: the watcher watches again to catch up.
                Err(_) => return,
            },
            read = connection.reader.read(&mut ignored) => {
                if matches!(read, Ok(0) | Err(_)) {
                    return;
                }
            }
            _ = crate::until_stopped(&mut stopping) => return,
        }
    }
}
