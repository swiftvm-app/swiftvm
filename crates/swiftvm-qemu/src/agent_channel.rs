//! The service's end of the serial line that a guest's agent talks over, with the connections opened on it.
//!
//! It stands in for the socket device QEMU doesn't have on a Mac: `connect` gives a socket, as connecting
//! over a socket device does, and what goes over it travels in frames that say which connection they
//! belong to (`GuestChannel/ChannelFrame.swift` is the agent's side). Each direction of a connection ends
//! on its own, so that a job's agent can say it has no more to send and still hear the other side hang up.

use std::collections::HashMap;
use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{mpsc, oneshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameKind {
    /// From the agent, first, whenever it has opened the line, and in answer to the service's: whatever
    /// was open before is gone. From the service when it opens its end, to hear it.
    Hello = 0,
    /// From the service: a new connection, to the port the payload names in four bytes.
    Open = 1,
    /// From the agent: it took the connection.
    Accept = 2,
    /// From the agent: nothing listens on that port.
    Refuse = 3,
    Data = 4,
    /// The sender has no more to send on this connection. It still reads.
    End = 5,
    /// The sender is done with the connection both ways.
    Close = 6,
}

impl FrameKind {
    fn of(byte: u8) -> Option<FrameKind> {
        Some(match byte {
            0 => FrameKind::Hello,
            1 => FrameKind::Open,
            2 => FrameKind::Accept,
            3 => FrameKind::Refuse,
            4 => FrameKind::Data,
            5 => FrameKind::End,
            6 => FrameKind::Close,
            _ => return None,
        })
    }
}

/// A byte for its kind, four for the connection and four for the length of what follows, most significant
/// first, and then that many bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelFrame {
    pub kind: FrameKind,
    pub connection: u32,
    pub payload: Vec<u8>,
}

/// No frame carries more than this. More is sent as several.
pub const MAXIMUM_PAYLOAD: usize = 64 * 1024;
const HEADER: usize = 9;
const HELLO_WORDS: &[u8] = b"swiftvm-agent-channel";

impl ChannelFrame {
    pub fn new(kind: FrameKind, connection: u32, payload: Vec<u8>) -> Self {
        ChannelFrame { kind, connection, payload }
    }

    /// The frame either side opens the line with. It carries words of its own, so that a reader that has
    /// lost its way in what an agent before left half sent finds the start of what this one sends.
    pub fn hello() -> Self {
        ChannelFrame::new(FrameKind::Hello, 0, HELLO_WORDS.to_vec())
    }

    pub fn open(connection: u32, port: u32) -> Self {
        ChannelFrame::new(FrameKind::Open, connection, port.to_be_bytes().to_vec())
    }

    pub fn encoded(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(HEADER + self.payload.len());
        data.push(self.kind as u8);
        data.extend_from_slice(&self.connection.to_be_bytes());
        data.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        data.extend_from_slice(&self.payload);
        data
    }
}

/// Cuts the bytes that arrive into frames. What isn't frames is passed over up to the next hello.
#[derive(Debug, Default)]
pub struct FrameReader {
    pending: Vec<u8>,
    /// The bytes are no frames: the next hello is looked for.
    pub is_lost: bool,
}

impl FrameReader {
    pub fn receive(&mut self, bytes: &[u8]) -> Vec<ChannelFrame> {
        self.pending.extend_from_slice(bytes);
        let mut frames = Vec::new();
        let mut offset = 0;
        loop {
            if self.is_lost {
                let marker = ChannelFrame::hello().encoded();
                match self.pending[offset..].windows(marker.len()).position(|window| window == marker.as_slice()) {
                    Some(found) => {
                        offset += found;
                        self.is_lost = false;
                    }
                    None => {
                        // What is left may be the start of one.
                        offset = offset.max(self.pending.len().saturating_sub(marker.len() - 1));
                        break;
                    }
                }
            }
            if self.pending.len() - offset < HEADER {
                break;
            }
            let header = &self.pending[offset..offset + HEADER];
            let connection = u32::from_be_bytes([header[1], header[2], header[3], header[4]]);
            let length = u32::from_be_bytes([header[5], header[6], header[7], header[8]]) as usize;
            let Some(kind) = FrameKind::of(header[0]).filter(|_| length <= MAXIMUM_PAYLOAD) else {
                self.is_lost = true;
                offset += 1;
                continue;
            };
            if self.pending.len() - offset < HEADER + length {
                break;
            }
            let payload = self.pending[offset + HEADER..offset + HEADER + length].to_vec();
            frames.push(ChannelFrame::new(kind, connection, payload));
            offset += HEADER + length;
        }
        self.pending.drain(..offset);
        frames
    }

    /// Lets go of what has arrived and looks for the next hello: the agent that sent it is gone.
    pub fn reset(&mut self) {
        self.pending.clear();
        self.is_lost = true;
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelError {
    /// No agent has said hello on the line since it was last opened.
    NoAgent,
    /// The agent has nothing listening on that port.
    Refused(u32),
    TimedOut,
    Closed,
}

impl std::fmt::Display for ChannelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ChannelError::NoAgent => f.write_str("The guest tools don't answer."),
            ChannelError::Refused(port) => write!(f, "Nothing listens on port {port} in the guest."),
            ChannelError::TimedOut => f.write_str("The guest tools didn't answer in time."),
            ChannelError::Closed => f.write_str("The line to the guest is gone."),
        }
    }
}

enum ToLocal {
    Data(Vec<u8>),
    End,
    Drop,
}

#[derive(Default)]
struct Flags {
    local_has_ended: bool,
    guest_has_ended: bool,
    is_dropped: bool,
}

struct Connection {
    id: u32,
    to_local: mpsc::UnboundedSender<ToLocal>,
    flags: Mutex<Flags>,
}

struct Opening {
    done: oneshot::Sender<Result<(), ChannelError>>,
    /// The channel's end of the new connection.
    local: UnixStream,
    port: u32,
}

#[derive(Default)]
struct State {
    is_closed: bool,
    has_agent: bool,
    next_connection: u32,
    connections: HashMap<u32, Arc<Connection>>,
    opening: HashMap<u32, Opening>,
    reader: FrameReader,
}

pub struct AgentChannel {
    state: Mutex<State>,
    /// Encoded frames, to the task that writes them onto the line whole and in order.
    line: Mutex<Option<mpsc::UnboundedSender<Vec<u8>>>>,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl AgentChannel {
    /// Takes over `line`, a connection to the agent's serial port, starts reading it, and says hello. An
    /// agent that was running all along believes its connections are still open: it hears the hello and
    /// says its own.
    pub fn start(line: UnixStream) -> Arc<AgentChannel> {
        let (reader, writer) = line.into_split();
        let (frames, outgoing) = mpsc::unbounded_channel();
        let channel =
            Arc::new(AgentChannel { state: Mutex::new(State { next_connection: 1, ..State::default() }), line: Mutex::new(Some(frames)) });
        tokio::spawn(write_loop(writer, outgoing));
        tokio::spawn(read_loop(reader, channel.clone()));
        channel.send(&ChannelFrame::hello());
        channel
    }

    /// Whether an agent has said hello since the line was last opened.
    pub fn has_agent(&self) -> bool {
        lock(&self.state).has_agent
    }

    /// Opens a connection to `port` in the guest, and returns the caller's end of it.
    pub async fn connect(self: &Arc<Self>, port: u32, timeout: Duration) -> Result<UnixStream, ChannelError> {
        let (caller, local) = UnixStream::pair().map_err(|_| ChannelError::Closed)?;
        let (done, answer) = oneshot::channel();
        let id = {
            let mut state = lock(&self.state);
            if state.is_closed {
                return Err(ChannelError::Closed);
            }
            if !state.has_agent {
                return Err(ChannelError::NoAgent);
            }
            let id = state.next_connection;
            state.next_connection = if id == u32::MAX { 1 } else { id + 1 };
            state.opening.insert(id, Opening { done, local, port });
            id
        };
        if !self.send(&ChannelFrame::open(id, port)) {
            self.finish_opening(id, Err(ChannelError::Closed));
        }
        match tokio::time::timeout(timeout, answer).await {
            Ok(Ok(Ok(()))) => Ok(caller),
            Ok(Ok(Err(error))) => Err(error),
            Ok(Err(_)) => Err(ChannelError::Closed),
            Err(_) => {
                self.finish_opening(id, Err(ChannelError::TimedOut));
                Err(ChannelError::TimedOut)
            }
        }
    }

    /// Hangs up on the guest and drops every connection.
    pub fn close(self: &Arc<Self>) {
        {
            let mut state = lock(&self.state);
            if state.is_closed {
                return;
            }
            state.is_closed = true;
        }
        self.drop_everything(ChannelError::Closed);
        // The writer ends once it has written what it has, and shuts the line, which ends the reader.
        lock(&self.line).take();
    }

    /// The agent's side of the line was closed in the guest: whatever was open is gone, what the agent was
    /// sending may have stopped half way through a frame, and nothing new opens until an agent says hello.
    pub fn agent_left(self: &Arc<Self>) {
        lock(&self.state).reader.reset();
        self.drop_everything(ChannelError::NoAgent);
    }

    /// The agent's side of the line was opened in the guest. The agent says hello, and is asked to again.
    pub fn agent_arrived(&self) {
        self.send(&ChannelFrame::hello());
    }

    fn send(&self, frame: &ChannelFrame) -> bool {
        lock(&self.line).as_ref().is_some_and(|line| line.send(frame.encoded()).is_ok())
    }

    /// Ends the wait for an answer to an open, once: with the agent's answer, the timeout, or the line
    /// going away, whichever comes first.
    fn finish_opening(self: &Arc<Self>, id: u32, result: Result<(), ChannelError>) {
        let Some(opening) = lock(&self.state).opening.remove(&id) else { return };
        match result {
            Ok(()) => {
                let (to_local, from_channel) = mpsc::unbounded_channel();
                let connection = Arc::new(Connection { id, to_local, flags: Mutex::new(Flags::default()) });
                {
                    let mut state = lock(&self.state);
                    if state.is_closed {
                        let _ = opening.done.send(Err(ChannelError::Closed));
                        return;
                    }
                    state.connections.insert(id, connection.clone());
                }
                let (reader, writer) = opening.local.into_split();
                tokio::spawn(output(self.clone(), connection.clone(), writer, from_channel));
                tokio::spawn(pump(self.clone(), connection, reader));
                let _ = opening.done.send(Ok(()));
            }
            Err(error) => {
                // The agent may yet take a connection that was given up on: it is told it is closed.
                if error == ChannelError::TimedOut {
                    self.send(&ChannelFrame::new(FrameKind::Close, id, Vec::new()));
                }
                let _ = opening.done.send(Err(error));
            }
        }
    }

    /// Lets go of a connection: tells the guest unless it was the guest's doing, and closes the local end
    /// once what the guest sent before has gone out to it.
    fn drop_connection(&self, connection: &Connection, telling_guest: bool) {
        {
            let mut flags = lock(&connection.flags);
            if flags.is_dropped {
                return;
            }
            flags.is_dropped = true;
        }
        lock(&self.state).connections.remove(&connection.id);
        if telling_guest {
            self.send(&ChannelFrame::new(FrameKind::Close, connection.id, Vec::new()));
        }
        let _ = connection.to_local.send(ToLocal::Drop);
    }

    fn drop_everything(self: &Arc<Self>, error: ChannelError) {
        let (open, waiting) = {
            let mut state = lock(&self.state);
            state.has_agent = false;
            let open: Vec<Arc<Connection>> = state.connections.drain().map(|(_, connection)| connection).collect();
            (open, state.opening.keys().copied().collect::<Vec<_>>())
        };
        for connection in open {
            self.drop_connection(&connection, false);
        }
        for id in waiting {
            self.finish_opening(id, Err(error.clone()));
        }
    }

    fn handle(self: &Arc<Self>, frame: ChannelFrame) {
        let connection = || lock(&self.state).connections.get(&frame.connection).cloned();
        match frame.kind {
            FrameKind::Hello => {
                // Either way, what was open before is gone.
                self.drop_everything(ChannelError::NoAgent);
                lock(&self.state).has_agent = true;
            }
            FrameKind::Accept => self.finish_opening(frame.connection, Ok(())),
            FrameKind::Refuse => {
                let port = lock(&self.state).opening.get(&frame.connection).map_or(0, |opening| opening.port);
                self.finish_opening(frame.connection, Err(ChannelError::Refused(port)));
            }
            FrameKind::Data => {
                if let Some(connection) = connection() {
                    let _ = connection.to_local.send(ToLocal::Data(frame.payload));
                }
            }
            FrameKind::End => {
                if let Some(connection) = connection() {
                    let is_done = {
                        let mut flags = lock(&connection.flags);
                        flags.guest_has_ended = true;
                        flags.local_has_ended
                    };
                    if is_done {
                        self.drop_connection(&connection, true);
                    } else {
                        let _ = connection.to_local.send(ToLocal::End);
                    }
                }
            }
            FrameKind::Close => {
                if let Some(connection) = connection() {
                    self.drop_connection(&connection, false);
                }
            }
            // Only the service opens connections.
            FrameKind::Open => {
                self.send(&ChannelFrame::new(FrameKind::Refuse, frame.connection, Vec::new()));
            }
        }
    }
}

async fn write_loop(mut writer: OwnedWriteHalf, mut frames: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(frame) = frames.recv().await {
        if writer.write_all(&frame).await.is_err() {
            break;
        }
    }
    // SAFETY: shutdown on a descriptor this task's half keeps open.
    unsafe {
        libc::shutdown(writer.as_ref().as_raw_fd(), libc::SHUT_RDWR);
    }
}

async fn read_loop(mut reader: OwnedReadHalf, channel: Arc<AgentChannel>) {
    let mut buffer = vec![0u8; 128 * 1024];
    loop {
        let count = match reader.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(count) => count,
        };
        let (frames, is_lost) = {
            let mut state = lock(&channel.state);
            let frames = state.reader.receive(&buffer[..count]);
            (frames, state.reader.is_lost)
        };
        if is_lost {
            // What came isn't frames. Until the next hello nothing on the line can be trusted.
            channel.drop_everything(ChannelError::NoAgent);
            channel.send(&ChannelFrame::hello());
        }
        for frame in frames {
            channel.handle(frame);
        }
    }
    channel.close();
}

/// Writes what the guest sends to the local end, in order, and closes it when the connection is dropped.
async fn output(
    channel: Arc<AgentChannel>,
    connection: Arc<Connection>,
    mut writer: OwnedWriteHalf,
    mut from_channel: mpsc::UnboundedReceiver<ToLocal>,
) {
    while let Some(message) = from_channel.recv().await {
        match message {
            ToLocal::Data(bytes) => {
                if writer.write_all(&bytes).await.is_err() {
                    // Nobody listens at the local end any more.
                    channel.drop_connection(&connection, true);
                }
            }
            ToLocal::End => {
                let _ = writer.shutdown().await;
            }
            ToLocal::Drop => break,
        }
    }
    // Whoever reads the other end learns nothing more is coming, and so does the pump.
    // SAFETY: shutdown on a descriptor this task's half keeps open.
    unsafe {
        libc::shutdown(writer.as_ref().as_raw_fd(), libc::SHUT_RDWR);
    }
}

/// Passes what the local end sends on to the guest, until it has no more.
async fn pump(channel: Arc<AgentChannel>, connection: Arc<Connection>, mut reader: OwnedReadHalf) {
    let mut buffer = vec![0u8; MAXIMUM_PAYLOAD];
    loop {
        match reader.read(&mut buffer).await {
            Ok(0) => {
                // The local end has no more to send. It may still be listening.
                let is_done = {
                    let mut flags = lock(&connection.flags);
                    flags.local_has_ended = true;
                    flags.guest_has_ended || flags.is_dropped
                };
                if is_done {
                    channel.drop_connection(&connection, true);
                } else {
                    channel.send(&ChannelFrame::new(FrameKind::End, connection.id, Vec::new()));
                }
                return;
            }
            Ok(count) => {
                if !channel.send(&ChannelFrame::new(FrameKind::Data, connection.id, buffer[..count].to_vec())) {
                    channel.drop_connection(&connection, false);
                    return;
                }
            }
            Err(_) => {
                channel.drop_connection(&connection, true);
                return;
            }
        }
    }
}
