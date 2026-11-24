//! One client's connection: the handshake, then its requests, each answered by the service or passed on
//! to the app.

use std::sync::Arc;

use serde_json::Value;
use swiftvm_protocol::api::{self, PROTOCOLS};
use swiftvm_protocol::client::app_not_running_message;
use swiftvm_protocol::wire::{AppStatus, Command, ControlResponse, ErrorCode, ServiceInfo};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

use crate::transport::{DescriptorReader, Peer};
use crate::{Service, engine, events, lines, log};

pub(crate) struct Connection {
    pub reader: BufReader<DescriptorReader>,
    pub writer: OwnedWriteHalf,
    pub service: Arc<Service>,
}

impl Connection {
    pub async fn answer(&mut self, answer: &ControlResponse) -> bool {
        lines::write_value(&mut self.writer, answer).await
    }

    /// The next line from the client. `None` when it has gone, or, between requests, when the service
    /// is stopping.
    async fn next_line(&mut self) -> Option<Vec<u8>> {
        let mut stopping = self.service.stopping.subscribe();
        // What has arrived is answered, even when the service is stopping meanwhile.
        tokio::select! {
            biased;
            line = lines::read(&mut self.reader) => line,
            _ = crate::until_stopped(&mut stopping) => None,
        }
    }

    /// The connection whole again, with what was read from it and not used yet.
    pub fn into_stream(self) -> Option<(UnixStream, Vec<u8>)> {
        let left = self.reader.buffer().to_vec();
        let stream = self.reader.into_inner().into_inner().reunite(self.writer).ok()?;
        Some((stream, left))
    }

    /// The descriptors that came with what was read since this was last asked.
    pub fn take_descriptors(&mut self) -> Vec<std::os::fd::OwnedFd> {
        std::mem::take(&mut self.reader.get_mut().descriptors)
    }
}

/// What a request was turned into.
fn request_of(line: &[u8]) -> Result<(u64, String, Value), Box<ControlResponse>> {
    let value: Value = serde_json::from_slice(line)
        .ok()
        .filter(Value::is_object)
        .ok_or_else(|| Box::new(ControlResponse::failure(None, ErrorCode::BadRequest, "The request couldn't be understood.")))?;
    let id = value.get("id").and_then(Value::as_u64);
    let Some(command) = value.get("command").and_then(Value::as_str).map(str::to_string) else {
        return Err(Box::new(ControlResponse::failure(id, ErrorCode::BadRequest, "The request has no command.")));
    };
    let Some(id) = id else {
        return Err(Box::new(ControlResponse::failure(None, ErrorCode::BadRequest, "Every request needs an id, a whole number.")));
    };
    Ok((id, command, value))
}

pub(crate) async fn handle(stream: UnixStream, service: Arc<Service>) {
    let peer = Peer::of(&stream);
    if !peer.is_this_user() {
        return;
    }
    let (reader, writer) = stream.into_split();
    let mut connection = Connection { reader: BufReader::new(DescriptorReader::new(reader)), writer, service };
    if !hello(&mut connection, &peer).await {
        return;
    }
    loop {
        let Some(line) = connection.next_line().await else { return };
        let (id, command, request) = match request_of(&line) {
            Ok(request) => request,
            Err(failure) => {
                if !connection.answer(&failure).await {
                    return;
                }
                continue;
            }
        };
        let answered = match Command::from_raw_value(&command) {
            Some(Command::Hello) => {
                let answer = hello_answer(&connection.service, id, PROTOCOLS[PROTOCOLS.len() - 1]).await;
                connection.answer(&answer).await
            }
            Some(Command::Watch) => return events::watch(connection, id).await,
            Some(command @ (Command::Clients | Command::ClientsAllow | Command::ClientsDeny | Command::ClientsRemove)) => {
                let program = request.get("program").and_then(Value::as_str);
                let answer = connection.service.permission.change(command, program, id);
                connection.answer(&answer).await
            }
            Some(Command::ServiceStop) => {
                log("Stopping, as a client asked.");
                connection.service.stop();
                connection.answer(&ControlResponse::success(Some(id))).await
            }
            Some(Command::AskPermission) => {
                connection.answer(&ControlResponse::failure(Some(id), ErrorCode::BadRequest, "Only the service asks the app that.")).await
            }
            Some(command) if command.is_qemu() => match engine::handle(connection, id, command, request).await {
                Some(back) => {
                    connection = back;
                    true
                }
                None => return,
            },
            known => match forward(connection, id, known.is_some_and(Command::opens_stream), request).await {
                Some(back) => {
                    connection = back;
                    true
                }
                None => return,
            },
        };
        if !answered {
            return;
        }
        // Descriptors nobody took are closed.
        drop(connection.take_descriptors());
    }
}

/// The handshake: the client's first line is `hello`, in a version of the API the service speaks, from a
/// program that may use SwiftVM. Returns whether the connection goes on.
async fn hello(connection: &mut Connection, peer: &Peer) -> bool {
    let Some(line) = connection.next_line().await else { return false };
    let (id, command, request) = match request_of(&line) {
        Ok(request) => request,
        Err(failure) => {
            connection.answer(&failure).await;
            return false;
        }
    };
    if command != Command::Hello.raw_value() {
        let message = "Say hello first: the first request is `hello`, with the version of the API the client speaks.";
        connection.answer(&ControlResponse::failure(Some(id), ErrorCode::BadRequest, message)).await;
        return false;
    }
    let protocol = request.get("protocol").and_then(Value::as_u64).and_then(|protocol| u32::try_from(protocol).ok());
    let Some(protocol) = protocol.filter(|protocol| PROTOCOLS.contains(protocol)) else {
        let spoken = PROTOCOLS.iter().map(u32::to_string).collect::<Vec<_>>().join(", ");
        let asked = request.get("protocol").map(Value::to_string).unwrap_or_else(|| "none".into());
        let message = format!("This service speaks version {spoken} of the API, and the client asked for {asked}.");
        connection.answer(&ControlResponse::failure(Some(id), ErrorCode::UnsupportedProtocol, message)).await;
        return false;
    };
    if let Err(message) = connection.service.permission.check(peer, &connection.service).await {
        let program = peer.program.as_ref().map(|program| program.display().to_string()).unwrap_or_else(|| "an unknown program".into());
        log(&format!("Refused {program}: {message}"));
        connection.answer(&ControlResponse::failure(Some(id), ErrorCode::NotAllowed, message)).await;
        return false;
    }
    let answer = hello_answer(&connection.service, id, protocol).await;
    connection.answer(&answer).await
}

async fn hello_answer(service: &Service, id: u64, protocol: u32) -> ControlResponse {
    let offers = Command::ALL.into_iter().filter(|command| command.is_the_services()).map(Command::raw_value).collect();
    let running = UnixStream::connect(service.config.paths.socket()).await.is_ok();
    ControlResponse {
        service: Some(ServiceInfo {
            version: env!("CARGO_PKG_VERSION").into(),
            protocol,
            platform: api::platform().into(),
            offers,
            app: AppStatus { running },
        }),
        ..ControlResponse::success(Some(id))
    }
}

/// A connection to the app's control socket, or the answer to give when there is none.
pub(crate) async fn connect_app(service: &Service, id: Option<u64>) -> Result<UnixStream, Box<ControlResponse>> {
    UnixStream::connect(service.config.paths.socket()).await.map_err(|error| {
        Box::new(match error.raw_os_error() {
            Some(libc::ENOENT | libc::ECONNREFUSED) => {
                ControlResponse::failure(id, ErrorCode::AppNotRunning, app_not_running_message(&service.config.app_name))
            }
            _ => ControlResponse::failure(id, ErrorCode::Failed, format!("The app couldn't be reached: {error}")),
        })
    })
}

/// Sends `request`, in the app's coding, to the app, and reads its answer, as the client is to have it.
/// Returns the app's connection with it, which carries a stream after an answer that opens one.
pub(crate) async fn ask_app(
    service: &Service,
    id: Option<u64>,
    request: &Value,
) -> Result<(Value, BufReader<OwnedReadHalf>, OwnedWriteHalf), Box<ControlResponse>> {
    let app = connect_app(service, id).await?;
    let (reader, mut writer) = app.into_split();
    let mut reader = BufReader::new(reader);
    let lost = || Box::new(ControlResponse::failure(id, ErrorCode::Failed, "The app closed the connection before answering."));
    if !lines::write_value(&mut writer, request).await {
        return Err(lost());
    }
    let line = lines::read(&mut reader).await.ok_or_else(lost)?;
    let answer: Value = serde_json::from_slice(&line).ok().filter(Value::is_object).ok_or_else(|| {
        Box::new(ControlResponse::failure(id, ErrorCode::Failed, "Received a message from the app that couldn't be understood."))
    })?;
    Ok((api::answer_from_app(answer, id), reader, writer))
}

/// Passes a request on to the app, and its answer back. After an answer that opens a stream, carries it
/// both ways until both sides are done, and the connection with it. Returns the connection when it
/// goes on.
async fn forward(mut connection: Connection, id: u64, opens_stream: bool, request: Value) -> Option<Connection> {
    let service = connection.service.clone();
    let (answer, app_reader, app_writer) = match ask_app(&service, Some(id), &api::request_for_app(request)).await {
        Ok(asked) => asked,
        Err(failure) => return connection.answer(&failure).await.then_some(connection),
    };
    if !lines::write_value(&mut connection.writer, &answer).await {
        return None;
    }
    if !(opens_stream && answer.get("ok") == Some(&Value::Bool(true))) {
        return Some(connection);
    }
    let app_left = app_reader.buffer().to_vec();
    let mut app = app_reader.into_inner().reunite(app_writer).ok()?;
    let (mut client, client_left) = connection.into_stream()?;
    if (!app_left.is_empty() && client.write_all(&app_left).await.is_err())
        || (!client_left.is_empty() && app.write_all(&client_left).await.is_err())
    {
        return None;
    }
    let _ = tokio::io::copy_bidirectional(&mut client, &mut app).await;
    None
}
