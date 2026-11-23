//! The messages as the Swift app writes and reads them. The fixtures are shared with
//! `Packages/SwiftVMKit/Tests/VMControlTests/WireFixtureTests.swift`, which reads them with the app's
//! own types: a message both sides take back unchanged is one they agree on.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::Duration;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use swiftvm_protocol::*;

fn fixture(name: &str) -> Value {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
}

/// Equal as JSON, where `2` and `2.0` are one number, as they are to Swift.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        (Value::Array(a), Value::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b)),
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len() && a.iter().all(|(key, value)| b.get(key).is_some_and(|other| same(value, other)))
        }
        _ => a == b,
    }
}

fn round_trip<T: Serialize + DeserializeOwned>(original: &Value) -> T {
    let decoded: T = serde_json::from_value(original.clone()).unwrap_or_else(|error| panic!("{error}: {original}"));
    let encoded = serde_json::to_value(&decoded).unwrap();
    assert!(same(original, &encoded), "\n  sent:  {original}\n  again: {encoded}");
    decoded
}

#[test]
fn requests_go_out_as_the_app_reads_them() {
    let requests: Vec<ControlRequest> = fixture("requests.json").as_array().unwrap().iter().map(round_trip).collect();
    let steps = &requests.last().unwrap().control.as_ref().unwrap().steps;
    assert_eq!(steps[0].target, Some(ControlTarget::Number(12)));
    assert_eq!(steps[1].target, Some(ControlTarget::Point { x: 10, y: 20 }));
    assert_eq!(steps[1].to, Some(ControlTarget::Text("Trash".into())));
    assert_eq!(steps[2].target, Some(ControlTarget::Id("search".into())));
    assert_eq!(requests[1].command, Command::ForceStop);
}

#[test]
fn responses_are_read_as_the_app_writes_them() {
    let responses: Vec<ControlResponse> = fixture("responses.json").as_array().unwrap().iter().map(round_trip).collect();
    assert_eq!(responses[1].machines[0].id.to_string(), "E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
    // 2001-01-01 plus the seconds Swift counts from then.
    assert_eq!(responses[3].snapshots.as_ref().unwrap()[0].created_at.unix_seconds(), 978_307_200.0 + 785_000_000.5);
}

#[test]
fn an_outcome_brings_its_picture_and_reads_as_text() {
    let outcome: ControlOutcome = round_trip(&fixture("outcome.json"));
    assert_eq!(
        outcome.results[1].image.as_deref(),
        Some(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01][..])
    );
    assert_eq!(control_exit::status(&outcome), control_exit::TIMED_OUT);
    let look = outcome.results[1].look.as_ref().unwrap();
    assert_eq!(
        look.text(),
        [
            "desk · macOS 27 · screen 1440x900 (2x) · look 4",
            "apps: Finder, Safari*",
            "note: accessibility is limited",
            "+ [1] window \"Start Page\" 0,25 1440x875",
            "~ [2] button \"Save\" focused #settings-save 640,400 80x24",
            "+ [3] textfield =\"swiftvm\"",
            "- [9] text \"Loading\"",
            "… 5 more: narrow it with --app, or see them with --all",
        ]
        .join("\n")
    );
}

#[test]
fn every_command_goes_by_its_name_on_the_wire() {
    for command in Command::ALL {
        assert_eq!(Command::from_raw_value(&command.raw_value()), Some(command));
    }
    assert_eq!(Command::DiscardState.raw_value(), "discard-state");
    assert_eq!(Command::from_raw_value("usb"), None);
}

fn socket_pair() -> (UnixStream, UnixStream) {
    UnixStream::pair().unwrap()
}

#[test]
fn frames_keep_their_bytes_and_skip_kinds_they_dont_know() {
    let (sender, receiver) = socket_pair();
    let binary: Vec<u8> = (0..=255).collect();
    let large = vec![7u8; JobFrame::MAXIMUM_PAYLOAD_LENGTH * 2 + 1];
    assert!(JobFrame::write(JobFrameKind::Output, &binary, sender.as_raw_fd()));
    // A kind from a later build is passed over.
    (&sender).write_all(&[9, 0, 0, 0, 1, 42]).unwrap();
    let writer = std::thread::spawn(move || {
        assert!(JobFrame::write(JobFrameKind::ErrorOutput, &large, sender.as_raw_fd()));
        assert!(JobFrame::write(JobFrameKind::End, br#"{"status":3}"#, sender.as_raw_fd()));
    });
    let read = |timeout| JobFrame::read(receiver.as_raw_fd(), timeout).unwrap().unwrap();
    assert_eq!(read(None), JobFrame::new(JobFrameKind::Output, binary));
    let mut errors = Vec::new();
    loop {
        let frame = read(Some(Duration::from_secs(5)));
        if frame.kind == JobFrameKind::End {
            assert_eq!(frame.end(), Some(JobEnd { status: Some(3), ..Default::default() }));
            break;
        }
        errors.extend(frame.payload);
    }
    assert_eq!(errors.len(), JobFrame::MAXIMUM_PAYLOAD_LENGTH * 2 + 1);
    writer.join().unwrap();
    // Hung up between frames: the end of the stream, not an error.
    assert_eq!(JobFrame::read(receiver.as_raw_fd(), None), Ok(None));
}

#[test]
fn a_frame_cut_short_or_late_is_no_frame() {
    let (sender, receiver) = socket_pair();
    (&sender).write_all(&[1, 0, 0, 0, 10, 1, 2]).unwrap();
    assert_eq!(JobFrame::read(receiver.as_raw_fd(), Some(Duration::from_millis(50))), Err(FrameError::TimedOut));
    drop(sender);
    let (sender, receiver) = socket_pair();
    (&sender).write_all(&[1, 0, 0, 0, 10, 1, 2]).unwrap();
    drop(sender);
    assert_eq!(JobFrame::read(receiver.as_raw_fd(), None), Err(FrameError::Malformed));
    let end = JobFrame::new(JobFrameKind::End, b"not JSON".to_vec()).end().unwrap();
    assert!(end.error.is_some() && end.status.is_none());
}

#[test]
fn the_client_hands_over_the_connection_for_a_stream() {
    let folder = std::env::temp_dir().join(format!("swiftvm-client-{}", std::process::id()));
    std::fs::create_dir_all(&folder).unwrap();
    let socket = folder.join("control.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        for _ in 0..2 {
            let (connection, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(connection.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: ControlRequest = serde_json::from_str(&line).unwrap();
            let mut connection = connection;
            if request.command == Command::Job {
                connection.write_all(b"{\"ok\":true,\"machines\":[]}\n").unwrap();
                JobFrame::write(JobFrameKind::Output, b"streamed", connection.as_raw_fd());
            } else {
                connection.write_all(b"{\"ok\":false,\"error\":\"No.\",\"machines\":[]}\n").unwrap();
            }
        }
    });
    let client = ControlClient::new(&socket, "SwiftVM");
    let (response, connection) = client.open_stream(&ControlRequest::for_machine(Command::Job, "desk")).unwrap();
    assert!(response.ok);
    let frame = JobFrame::read(connection.unwrap().as_raw_fd(), Some(Duration::from_secs(5))).unwrap().unwrap();
    assert_eq!(frame.payload, b"streamed");
    let (response, connection) = client.open_stream(&ControlRequest::for_machine(Command::Console, "desk")).unwrap();
    assert_eq!((response.error.as_deref(), connection.is_none()), (Some("No."), true));
    server.join().unwrap();
    std::fs::remove_dir_all(&folder).unwrap();
    assert_eq!(client.send(&ControlRequest::new(Command::List)), Err(ClientError::AppNotRunning("SwiftVM".into())));
}
