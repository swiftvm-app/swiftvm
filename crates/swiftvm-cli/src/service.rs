//! The commands about the service itself: `serve`, `service`, `watch` and `clients`.

use std::os::fd::AsRawFd;

use swiftvm_protocol::paths::standardized_path;
use swiftvm_protocol::wire::{Event, EventKind};
use swiftvm_protocol::{ClientError, Command, ControlRequest, ControlResponse, ServiceClient, io};

use crate::format::{LocalTime, print_rows};
use crate::print_table;
use crate::util::{answer, client, client_name, exit, fail, failure_answer, identity, paths, prints_json, say, say_json, tool_path};

/// `swiftvm serve`: runs the service here, until it is stopped.
pub fn serve(arguments: &[String]) -> ! {
    if !arguments.is_empty() {
        fail("Usage: swiftvm serve");
    }
    let config = swiftvm_service::Config::new(paths().clone(), identity().name(), tool_path());
    exit(swiftvm_service::run(config))
}

/// `swiftvm service [stop]`: whether the service runs, and what it is; or stops it. Neither starts it.
pub fn service(arguments: &[String]) -> ! {
    let existing = ServiceClient::new(paths().clone(), client_name(), None);
    match arguments.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        [] => {
            let hello = ControlRequest {
                protocol: Some(swiftvm_protocol::api::PROTOCOL),
                client: Some(client_name()),
                ..ControlRequest::new(Command::Hello)
            };
            let response = match existing.send(&hello) {
                Ok(response) => response,
                Err(ClientError::ServiceNotRunning(_)) => {
                    if prints_json() {
                        say_json(&failure_answer(&ClientError::ServiceNotRunning(paths().service_log())));
                    } else {
                        say("The service isn't running. Any command starts it.");
                    }
                    exit(1)
                }
                Err(error) => fail(&error.to_string()),
            };
            if prints_json() {
                say_json(&response);
                exit(if response.ok { 0 } else { 1 });
            }
            let Some(info) = response.service.clone().filter(|_| response.ok) else {
                fail(response.error_message().unwrap_or("The service didn't say what it is."))
            };
            let app = if info.app.running { "running" } else { "not running" };
            // The machines the service runs on QEMU itself.
            let qemu = existing
                .send(&ControlRequest::new(Command::QemuList))
                .ok()
                .and_then(|response| response.qemu_machines)
                .map(|machines| {
                    let names: Vec<String> = machines.iter().map(|machine| format!("{} (process {})", machine.name, machine.pid)).collect();
                    if names.is_empty() { "none".to_string() } else { names.join(", ") }
                })
                .unwrap_or_else(|| "unknown".into());
            print_rows(&[
                vec!["Service:".into(), format!("swiftvm {}, API {}, on {}", info.version, info.protocol, info.platform)],
                vec![format!("{}:", identity().name()), app.into()],
                vec!["On QEMU:".into(), qemu],
                vec!["Socket:".into(), paths().service_socket().display().to_string()],
                vec!["Log:".into(), paths().service_log().display().to_string()],
            ]);
        }
        ["stop"] => match existing.send(&ControlRequest::new(Command::ServiceStop)) {
            Ok(response) if prints_json() => {
                say_json(&response);
                exit(if response.ok { 0 } else { 1 })
            }
            Ok(response) if response.ok => say("The service is stopping, once the work under way is done."),
            Ok(response) => fail(response.error_message().unwrap_or("The service didn't stop.")),
            Err(ClientError::ServiceNotRunning(_)) => say("The service isn't running."),
            Err(error) => fail(&error.to_string()),
        },
        _ => fail("Usage: swiftvm service [stop]"),
    }
    exit(0)
}

/// `swiftvm watch`: the machines there are, and then what changes, one line each, until stopped.
pub fn watch(arguments: &[String]) -> ! {
    if !arguments.is_empty() {
        fail("Usage: swiftvm watch");
    }
    let (response, connection) = match client().open_stream(&ControlRequest::new(Command::Watch)) {
        Ok(opened) => opened,
        Err(error) if prints_json() => {
            say_json(&failure_answer(&error));
            exit(1)
        }
        Err(error) => fail(&error.to_string()),
    };
    if prints_json() {
        say_json(&response);
    }
    let Some(connection) = connection else {
        if prints_json() {
            exit(1);
        }
        fail(response.error_message().unwrap_or("The service didn't take that on."))
    };
    if !prints_json() {
        print_table(&response.machines, response.creations.as_deref().unwrap_or_default());
        say("");
    }
    while let Some(line) = io::read_line(connection.as_raw_fd()) {
        if prints_json() {
            say(&String::from_utf8_lossy(&line));
        } else if let Ok(event) = serde_json::from_slice::<Event>(&line)
            && let Some(text) = event_text(&event)
        {
            say(&format!("{}  {text}", time_of_day()));
        }
        use std::io::Write;
        let _ = std::io::stdout().flush();
    }
    if !prints_json() {
        say("The service ended the watch.");
    }
    exit(1)
}

fn time_of_day() -> String {
    let now = LocalTime::now();
    format!("{:02}:{:02}:{:02}", now.hour, now.minute, now.second)
}

/// An event as a person reads it: `desk: running, 192.168.64.5`.
pub fn event_text(event: &Event) -> Option<String> {
    let machine = event.machine.as_ref();
    let name = machine.map(|machine| machine.name.as_str()).unwrap_or("?");
    Some(match event.event {
        EventKind::MachineAdded => format!("{name}: added, {}", machine?.state),
        EventKind::MachineChanged => {
            let machine = machine?;
            match &machine.address {
                Some(address) => format!("{name}: {}, {address}", machine.state),
                None => format!("{name}: {}", machine.state),
            }
        }
        EventKind::MachineRemoved => format!("{name}: removed"),
        EventKind::GuestTools => {
            let tools = match event.guest_tools.as_ref().and_then(|tools| tools.version.as_ref()) {
                Some(version) => format!("guest tools {version}"),
                None => "guest tools not connected".into(),
            };
            match &event.setup {
                Some(setup) => {
                    let what = setup.name.as_ref().map(|name| format!(" {name}")).unwrap_or_default();
                    let step = setup.step.as_ref().map(|step| format!(", {step}")).unwrap_or_default();
                    format!("{name}: {tools}, setup{what} {}{step}", setup.state)
                }
                None => format!("{name}: {tools}"),
            }
        }
        EventKind::Creation => {
            let creation = event.creation.as_ref()?;
            if let Some(error) = &creation.error {
                format!("{}: failed to create: {error}", creation.name)
            } else if let Some(fraction) = creation.fraction {
                format!("{}: creating ({}%), {}", creation.name, (fraction * 100.0).round() as i64, creation.status)
            } else {
                format!("{}: creating, {}", creation.name, creation.status)
            }
        }
        EventKind::CreationEnded => format!("{}: no longer being created", event.creation.as_ref()?.name),
        EventKind::App => {
            if event.running == Some(true) {
                format!("{} is running", identity().name())
            } else {
                format!("{} isn't running", identity().name())
            }
        }
        EventKind::Unknown => return None,
    })
}

/// `swiftvm clients [allow | deny | remove <program>]`.
pub fn clients(arguments: &[String]) -> ! {
    let usage = "Usage: swiftvm clients [allow <program> | deny <program> | remove <program>]";
    let request = match arguments.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        [] => ControlRequest::new(Command::Clients),
        [action, program] => {
            let command = match *action {
                "allow" => Command::ClientsAllow,
                "deny" => Command::ClientsDeny,
                "remove" => Command::ClientsRemove,
                _ => fail(usage),
            };
            ControlRequest { program: Some(standardized_path(program)), ..ControlRequest::new(command) }
        }
        _ => fail(usage),
    };
    let response: ControlResponse = answer(request);
    let programs = response.clients.unwrap_or_default();
    if programs.is_empty() {
        say("No program has been allowed or refused. The swiftvm tool and the app need no permission.");
        exit(0);
    }
    let mut rows = vec![["NAME", "ALLOWED", "DECIDED", "PROGRAM"].map(String::from).to_vec()];
    rows.extend(programs.iter().map(|program| {
        vec![
            program.name.clone(),
            if program.allowed { "yes" } else { "no" }.into(),
            LocalTime::at_unix_seconds(program.decided_at.unix_seconds()).readable(),
            program.path.clone(),
        ]
    }));
    print_rows(&rows);
    exit(0)
}
