//! The line to a running QEMU over its machine protocol (QMP): commands and their answers, one JSON object
//! a line each, and the events QEMU sends of its own accord in between. Answers find their command by `id`.

use std::collections::HashMap;
use std::os::fd::{AsRawFd, BorrowedFd};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::{mpsc, oneshot};

use crate::QemuError;

/// Something QEMU says unasked: that the guest shut down, that a device is gone.
#[derive(Debug, Clone, PartialEq)]
pub struct QmpEvent {
    pub name: String,
    pub data: Value,
}

type Waiting = oneshot::Sender<Result<Value, QemuError>>;

/// The longest QEMU is given to answer a command. What takes longer, such as saving memory, is asked about
/// again and again instead.
const ANSWER_TIME: Duration = Duration::from_secs(60);

pub struct Qmp {
    writer: tokio::sync::Mutex<Option<OwnedWriteHalf>>,
    pending: Arc<Mutex<Option<HashMap<u64, Waiting>>>>,
    next_id: AtomicU64,
}

impl Qmp {
    /// Connects to QEMU's monitor at `socket`, trying again while QEMU makes it, for `timeout` at most or
    /// until `is_alive` says QEMU is gone. Waits for QEMU's greeting and switches the line into command mode.
    /// The events come on the receiver, which ends once QEMU has hung up.
    pub async fn connect(
        socket: &Path,
        timeout: Duration,
        is_alive: impl Fn() -> bool,
    ) -> Result<(Arc<Qmp>, mpsc::UnboundedReceiver<QmpEvent>), QemuError> {
        let deadline = tokio::time::Instant::now() + timeout;
        let stream = loop {
            match UnixStream::connect(socket).await {
                Ok(stream) => break stream,
                Err(_) if tokio::time::Instant::now() < deadline && is_alive() => {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                Err(_) => return Err(QemuError::Disconnected),
            }
        };
        Self::open(stream, deadline.saturating_duration_since(tokio::time::Instant::now()).max(Duration::from_secs(1))).await
    }

    /// Takes over `stream`, a connection to QEMU's monitor, and waits for the greeting for `timeout`.
    pub async fn open(stream: UnixStream, timeout: Duration) -> Result<(Arc<Qmp>, mpsc::UnboundedReceiver<QmpEvent>), QemuError> {
        let (reader, writer) = stream.into_split();
        let pending = Arc::new(Mutex::new(Some(HashMap::new())));
        let (events, receiver) = mpsc::unbounded_channel();
        let (greeted, greeting) = oneshot::channel();
        tokio::spawn(read_loop(BufReader::new(reader), pending.clone(), events, greeted));
        let qmp = Arc::new(Qmp { writer: tokio::sync::Mutex::new(Some(writer)), pending, next_id: AtomicU64::new(1) });
        match tokio::time::timeout(timeout, greeting).await {
            Ok(Ok(())) => {}
            _ => {
                qmp.close().await;
                return Err(QemuError::Disconnected);
            }
        }
        qmp.execute("qmp_capabilities", None).await?;
        Ok((qmp, receiver))
    }

    /// Runs `command` and returns what it returned.
    pub async fn execute(&self, command: &str, arguments: Option<Value>) -> Result<Value, QemuError> {
        self.send(command, arguments, None).await
    }

    /// Runs `command` with a copy of `descriptor` riding along, for one such as `getfd` that takes one.
    pub async fn execute_passing(&self, command: &str, arguments: Option<Value>, descriptor: BorrowedFd<'_>) -> Result<Value, QemuError> {
        self.send(command, arguments, Some(descriptor)).await
    }

    async fn send(&self, command: &str, arguments: Option<Value>, descriptor: Option<BorrowedFd<'_>>) -> Result<Value, QemuError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (answered, answer) = oneshot::channel();
        {
            let mut pending = self.pending.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let Some(pending) = pending.as_mut() else { return Err(QemuError::Disconnected) };
            pending.insert(id, answered);
        }
        let mut message = Map::new();
        message.insert("execute".into(), json!(command));
        message.insert("id".into(), json!(id));
        if let Some(arguments) = arguments {
            message.insert("arguments".into(), arguments);
        }
        let mut line = serde_json::to_vec(&Value::Object(message)).unwrap_or_default();
        line.push(b'\n');
        let sent = {
            let mut writer = self.writer.lock().await;
            match writer.as_mut() {
                Some(writer) => write(writer, &line, descriptor).await,
                None => false,
            }
        };
        if !sent {
            self.forget(id);
            return Err(QemuError::Disconnected);
        }
        match tokio::time::timeout(ANSWER_TIME, answer).await {
            Ok(answer) => answer.unwrap_or(Err(QemuError::Disconnected)),
            Err(_) => {
                self.forget(id);
                Err(QemuError::Refused(format!("QEMU didn't answer “{command}” in time.")))
            }
        }
    }

    fn forget(&self, id: u64) {
        let mut pending = self.pending.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(pending) = pending.as_mut() {
            pending.remove(&id);
        }
    }

    /// Hangs up. Whatever waits for an answer is told none will come, and the events end.
    pub async fn close(&self) {
        if let Some(mut writer) = self.writer.lock().await.take() {
            let _ = writer.shutdown().await;
            // Shutting the socket both ways ends the reader's wait.
            // SAFETY: shutdown on a descriptor this connection owns.
            unsafe {
                libc::shutdown(writer.as_ref().as_raw_fd(), libc::SHUT_RDWR);
            }
        }
        fail_everything(&self.pending);
    }
}

async fn write(writer: &mut OwnedWriteHalf, line: &[u8], descriptor: Option<BorrowedFd<'_>>) -> bool {
    let mut rest = line;
    if let Some(descriptor) = descriptor {
        let stream: &UnixStream = writer.as_ref();
        let sent = loop {
            if stream.writable().await.is_err() {
                return false;
            }
            match stream.try_io(tokio::io::Interest::WRITABLE, || crate::fdpass::send(stream.as_raw_fd(), rest, &[descriptor.as_raw_fd()]))
            {
                Ok(sent) => break sent,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => return false,
            }
        };
        rest = &rest[sent..];
    }
    rest.is_empty() || writer.write_all(rest).await.is_ok()
}

fn fail_everything(pending: &Mutex<Option<HashMap<u64, Waiting>>>) {
    let waiting = pending.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
    for (_, waiting) in waiting.into_iter().flatten() {
        let _ = waiting.send(Err(QemuError::Disconnected));
    }
}

async fn read_loop(
    mut reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    pending: Arc<Mutex<Option<HashMap<u64, Waiting>>>>,
    events: mpsc::UnboundedSender<QmpEvent>,
    greeted: oneshot::Sender<()>,
) {
    let mut greeted = Some(greeted);
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let Ok(message) = serde_json::from_slice::<Value>(&line) else { continue };
        if message.get("QMP").is_some() {
            if let Some(greeted) = greeted.take() {
                let _ = greeted.send(());
            }
        } else if let Some(name) = message.get("event").and_then(Value::as_str) {
            let data = message.get("data").cloned().unwrap_or_else(|| json!({}));
            let _ = events.send(QmpEvent { name: name.to_string(), data });
        } else if let Some(id) = message.get("id").and_then(Value::as_u64) {
            let waiting = pending.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).as_mut().and_then(|pending| pending.remove(&id));
            if let Some(waiting) = waiting {
                let result = match message.get("error") {
                    Some(error) => {
                        Err(QemuError::Refused(error.get("desc").and_then(Value::as_str).unwrap_or("QEMU didn't say why.").to_string()))
                    }
                    None => Ok(message.get("return").cloned().unwrap_or(Value::Null)),
                };
                let _ = waiting.send(result);
            }
        }
    }
    fail_everything(&pending);
}
