//! swiftvm: control the running SwiftVM app from the command line.

mod console;
mod control;
mod exec_completion;
mod format;
mod guest_jobs;
mod mcp;
mod skill;
mod stream;
mod util;

use std::ffi::CString;
use std::os::fd::IntoRawFd;
use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};

use swiftvm_protocol::paths::standardized_path;
use swiftvm_protocol::text::shell_word;
use swiftvm_protocol::{
    Command, ControlRequest, CreateParameters, CreationSummary, DriveParameters, ForwardParameters, MachineSummary, MachineUsage,
    SetupScriptSummary, ShareParameters, SnapshotSummary, TemplateSummary, UsbDeviceSummary,
};

use crate::format::{LocalTime, bytes, pad, print_rows};
use crate::util::{client, exit, fail, identity, paths, restore_broken_pipe_signal, say, send, tool_path};

/// Every command and option, as `swiftvm help all` prints it.
const USAGE: &str = include_str!("help/usage.txt");
/// What `swiftvm help` says: enough to find the way, and short, as an agent reads it all.
const OVERVIEW: &str = include_str!("help/overview.txt");

fn usage() -> &'static str {
    USAGE.strip_suffix('\n').unwrap_or(USAGE)
}

fn overview() -> &'static str {
    OVERVIEW.strip_suffix('\n').unwrap_or(OVERVIEW)
}

/// What the usage says of the commands called `topic`.
fn help(topic: &str) -> Option<String> {
    match topic {
        "control" => return Some(control::USAGE.into()),
        "mcp" => return Some(mcp::USAGE.into()),
        "skill" => return Some(skill::USAGE.into()),
        "all" => return Some(usage().into()),
        _ => {}
    }
    let mut blocks = Vec::new();
    let mut is_in_block = false;
    for line in usage().split('\n') {
        if line.starts_with("  ") && !line.starts_with("   ") {
            let words: Vec<&str> = line[2..].split(' ').filter(|word| !word.is_empty()).collect();
            is_in_block = words.first() == Some(&topic)
                || (words.len() > 2 && words[1] == "<machine>" && words.get(2) == Some(&"|") && line.contains(&format!("| {topic} ")));
        } else if !line.starts_with("   ") {
            is_in_block = false;
        }
        if is_in_block {
            blocks.push(line);
        }
    }
    (!blocks.is_empty()).then(|| blocks.join("\n"))
}

// MARK: Tables

/// The table's row for a machine the app is still creating, or failed to create. Its numbers aren't known
/// before it is made.
fn creation_row(creation: &CreationSummary) -> Vec<String> {
    let state = if creation.error.is_some() {
        "failed to create".to_string()
    } else if let Some(fraction) = creation.fraction {
        format!("creating ({}%)", (fraction * 100.0).round() as i64)
    } else {
        "creating".to_string()
    };
    let mut row = vec![creation.name.clone(), state];
    row.extend(["-"; 5].map(String::from));
    row.push(creation.system.clone());
    row
}

fn print_table(machines: &[MachineSummary], creations: &[CreationSummary]) {
    if machines.is_empty() && creations.is_empty() {
        say("No virtual machines.");
        return;
    }
    let mut rows = vec![["NAME", "STATE", "ADDRESS", "SSH", "CPU", "MEMORY", "DISK", "SYSTEM"].map(String::from).to_vec()];
    rows.extend(machines.iter().map(|machine| {
        vec![
            machine.name.clone(),
            machine.state.clone(),
            machine.address.clone().unwrap_or_else(|| "-".into()),
            machine.ssh_alias.clone().unwrap_or_else(|| "-".into()),
            machine.cpu_count.to_string(),
            bytes(machine.memory_size),
            format!("{} of {}", bytes(machine.disk_allocated), bytes(machine.disk_capacity)),
            machine.system.clone(),
        ]
    }));
    rows.extend(creations.iter().map(creation_row));
    print_rows(&rows);
    // What holds a name that no machine has yet, and how to let it go.
    if !creations.is_empty() {
        say("");
        for creation in creations {
            let name = shell_word(&creation.name);
            if let Some(error) = &creation.error {
                let error = if error.trim().ends_with('.') { error.clone() } else { format!("{error}.") };
                say(&format!("“{}” couldn't be created: {error} `swiftvm delete {name}` clears it.", creation.name));
            } else {
                say(&format!(
                    "“{}” is being created: {} `swiftvm wait {name}` waits for it, `swiftvm delete {name}` cancels it.",
                    creation.name, creation.status
                ));
            }
        }
    }
}

/// What the machines take of this computer. A machine that isn't running, or has only just started,
/// takes nothing that can be told yet.
fn print_usage(machines: &[MachineSummary]) {
    let mut rows = vec![["NAME", "STATE", "CPU", "MEMORY"].map(String::from).to_vec()];
    rows.extend(machines.iter().map(|machine| {
        vec![
            machine.name.clone(),
            machine.state.clone(),
            machine.usage.as_ref().map(|usage| MachineUsage::percent(usage.cpu_percent)).unwrap_or_else(|| "-".into()),
            machine.usage.as_ref().map(|usage| bytes(usage.memory_bytes)).unwrap_or_else(|| "-".into()),
        ]
    }));
    print_rows(&rows);
}

fn print_snapshots(snapshots: &[SnapshotSummary]) {
    if snapshots.is_empty() {
        say("No snapshots.");
        return;
    }
    let mut rows = vec![["NAME", "TAKEN", "RESUMES", "ID"].map(String::from).to_vec()];
    rows.extend(snapshots.iter().map(|snapshot| {
        vec![
            snapshot.name.clone(),
            LocalTime::at_unix_seconds(snapshot.created_at.unix_seconds()).readable(),
            if snapshot.includes_memory { "yes" } else { "no" }.into(),
            snapshot.id.to_string(),
        ]
    }));
    print_rows(&rows);
}

fn print_templates(templates: &[TemplateSummary]) {
    if templates.is_empty() {
        say("No templates.");
        return;
    }
    let mut rows = vec![["NAME", "SYSTEM", "CPU", "MEMORY", "DISK", "SAVED", "ID"].map(String::from).to_vec()];
    rows.extend(templates.iter().map(|template| {
        vec![
            template.name.clone(),
            template.system.clone(),
            template.cpu_count.to_string(),
            bytes(template.memory_size),
            format!("{} of {}", bytes(template.disk_allocated), bytes(template.disk_capacity)),
            LocalTime::at_unix_seconds(template.created_at.unix_seconds()).readable(),
            template.id.to_string(),
        ]
    }));
    print_rows(&rows);
}

fn print_usb_devices(devices: &[UsbDeviceSummary]) {
    if devices.is_empty() {
        say("No USB devices.");
        return;
    }
    let mut rows = vec![["NUMBER", "DEVICE", "MAKER", "VENDOR:PRODUCT", "SERIAL NUMBER", "USED BY"].map(String::from).to_vec()];
    rows.extend(devices.iter().map(|device| {
        // Some sticks give a serial number of over a hundred characters. Its beginning tells them apart.
        let serial_number = match &device.serial_number {
            Some(serial) if format::characters(serial) > 24 => format!("{}…", format::prefix(serial, 24)),
            Some(serial) => serial.clone(),
            None => "-".into(),
        };
        vec![
            device.id.to_string(),
            device.name.clone(),
            device.manufacturer.clone().unwrap_or_else(|| "-".into()),
            device.identifier.clone(),
            serial_number,
            device.machine.clone().unwrap_or_else(|| "-".into()),
        ]
    }));
    print_rows(&rows);
}

fn print_scripts(scripts: &[SetupScriptSummary]) {
    if scripts.is_empty() {
        say("No setup scripts.");
        return;
    }
    let mut rows = vec![["NAME", "SETS UP", "KIND", "FOR", "NEEDS", "FROM", "ABOUT"].map(String::from).to_vec()];
    rows.extend(scripts.iter().map(|script| {
        let needs: Vec<String> = [
            script.minimum_memory_gigabytes.map(|gigabytes| format!("{gigabytes} GB memory")),
            script.minimum_disk_gigabytes.map(|gigabytes| format!("{gigabytes} GB disk")),
        ]
        .into_iter()
        .flatten()
        .collect();
        vec![
            script.id.clone(),
            script.name.clone(),
            script.category.clone().unwrap_or_else(|| "-".into()),
            if script.systems.is_empty() { "any".into() } else { script.systems.join(", ") },
            if needs.is_empty() { "-".into() } else { needs.join(", ") },
            if script.is_built_in { "SwiftVM" } else { "your folder" }.into(),
            script.summary.clone().unwrap_or_else(|| "-".into()),
        ]
    }));
    print_rows(&rows);
}

fn print_details(machine: &MachineSummary) {
    let mut lines: Vec<(String, String)> = vec![
        ("Name".into(), machine.name.clone()),
        ("State".into(), machine.state.clone()),
        ("System".into(), machine.system.clone()),
        ("Hardware".into(), format!("{} CPU, {} RAM", machine.cpu_count, bytes(machine.memory_size))),
        ("Disk".into(), format!("{} of {}", bytes(machine.disk_allocated), bytes(machine.disk_capacity))),
        ("Address".into(), machine.address.clone().unwrap_or_else(|| "-".into())),
        ("SSH".into(), machine.ssh_alias.as_ref().map(|alias| format!("swiftvm ssh {alias}")).unwrap_or_else(|| "-".into())),
    ];
    if let Some(usage) = &machine.usage {
        lines.push(("Usage".into(), format!("{} CPU, {} memory", MachineUsage::percent(usage.cpu_percent), bytes(usage.memory_bytes))));
    }
    if let Some(details) = &machine.details {
        // The first of several lines has the label; the others go under it.
        fn labelled<T>(lines: &mut Vec<(String, String)>, label: &str, items: &[T], text: impl Fn(&T) -> String) {
            for (index, item) in items.iter().enumerate() {
                lines.push((if index == 0 { label.into() } else { String::new() }, text(item)));
            }
        }
        lines.push(("MAC address".into(), details.mac_address.clone().unwrap_or_else(|| "-".into())));
        if let Some(mode) = &details.network_mode {
            let interface = details.bridged_interface_identifier.as_ref().map(|interface| format!(" ({interface})")).unwrap_or_default();
            lines.push(("Network".into(), format!("{mode}{interface}")));
        }
        labelled(&mut lines, "Drives", &details.drives, |drive| {
            format!("{}{}", drive.path, if drive.read_only { " (read-only)" } else { "" })
        });
        labelled(&mut lines, "USB", details.usb_devices.as_deref().unwrap_or_default(), |device| {
            format!("{} ({})", device.name, device.identifier)
        });
        labelled(&mut lines, "USB, by itself", details.usb_auto_connect.as_deref().unwrap_or_default(), Clone::clone);
        labelled(&mut lines, "Shared", &details.shared_folders, |folder| {
            format!("{}{}", folder.path, if folder.read_only { " (read-only)" } else { "" })
        });
        labelled(&mut lines, "Forwards", details.forwards.as_deref().unwrap_or_default(), |forward| {
            let mut text =
                format!("{}:{} → {}", if forward.allows_other_devices { "*" } else { "localhost" }, forward.host_port, forward.guest_port);
            if forward.udp {
                text += " udp";
            }
            if let Some(status) = &forward.status {
                text += &format!(" ({status})");
            }
            text
        });
        if let Some(tools) = &details.guest_tools {
            lines.push(("Guest tools".into(), tools.version.clone().unwrap_or_else(|| "not connected".into())));
            if let Some(kernel) = &tools.kernel {
                lines.push(("Kernel".into(), kernel.clone()));
            }
        }
        if let Some(setup) = &details.setup {
            // `KDE Plasma: running, Installing KDE Plasma`
            let progress = std::iter::once(setup.state.clone()).chain(setup.step.clone()).collect::<Vec<_>>().join(", ");
            lines.push(("Setup".into(), setup.name.iter().cloned().chain(std::iter::once(progress)).collect::<Vec<_>>().join(": ")));
        }
        if let Some(shares) = details.shares_clipboard {
            lines.push(("Clipboard".into(), if shares { "shared" } else { "not shared" }.into()));
        }
        if let Some(automation) = &details.automation {
            // `on (exec, input, accessibility)`, with what the connected guest tools do.
            let features = if automation.features.is_empty() || !automation.is_allowed {
                String::new()
            } else {
                format!(" ({})", automation.features.join(", "))
            };
            lines.push(("Automation".into(), format!("{}{features}", if automation.is_allowed { "on" } else { "off" })));
        }
        lines.push(("Snapshots".into(), details.snapshot_count.to_string()));
        lines.push(("Location".into(), details.location.clone()));
    }
    let width = lines.iter().map(|(label, _)| format::characters(label)).max().unwrap_or(0);
    for (label, value) in lines {
        let label = if label.is_empty() { String::new() } else { format!("{label}:") };
        say(&format!("{}{value}", pad(&label, width + 3)));
    }
}

// MARK: Reading the arguments

fn require_machine(arguments: &[String]) -> String {
    match arguments.first() {
        Some(machine) => machine.clone(),
        None => fail(&format!("Missing machine name.\n\n{}", usage())),
    }
}

/// Stops with a message if `options` holds anything but the `allowed` flags. A misspelt flag that is
/// quietly ignored does the opposite of what was meant (`--readonly` attaching an image writable).
fn reject_unknown_options(options: &[String], allowed: &[&str]) {
    if let Some(unknown) = options.iter().find(|option| !allowed.contains(&option.as_str())) {
        fail(&format!("Unknown option {unknown}."));
    }
}

/// Takes `--<name> <value>` out of `words`, if it is there.
fn take_option(words: &mut Vec<String>, name: &str) -> Option<String> {
    let index = words.iter().position(|word| word == name)?;
    if index + 1 >= words.len() {
        fail(&format!("{name} needs a value."));
    }
    let value = words[index + 1].clone();
    words.drain(index..=index + 1);
    Some(value)
}

fn on_or_off(arguments: &[String], usage: &str) -> bool {
    match arguments.get(1).map(String::as_str) {
        Some(state @ ("on" | "off")) if arguments.len() == 2 => state == "on",
        _ => fail(usage),
    }
}

fn first_machine(request: ControlRequest) -> Option<MachineSummary> {
    send(request).machines.into_iter().next()
}

fn print_note(note: Option<String>) {
    if let Some(note) = note {
        say(&format!("\n{note}"));
    }
}

// MARK: create

/// What `create` prints when a signal stops it while the app goes on creating the machine. Kept where
/// the signal handler finds it without taking a lock.
static STOP_MESSAGE: AtomicPtr<u8> = AtomicPtr::new(std::ptr::null_mut());
static STOP_MESSAGE_LENGTH: AtomicUsize = AtomicUsize::new(0);

/// Installed with the default action put back as it starts, and without the signal held back while it
/// runs, so that raising it again ends the program.
extern "C" fn stop_waiting(signal: libc::c_int) {
    let message = STOP_MESSAGE.load(Ordering::Relaxed);
    // SAFETY: write, raise and _exit are safe in a signal handler, and the message was leaked, so it
    // lives for as long as the program.
    unsafe {
        if !message.is_null() {
            libc::write(libc::STDERR_FILENO, message.cast(), STOP_MESSAGE_LENGTH.load(Ordering::Relaxed));
        }
        // Ended by the signal itself, not by exiting with its number: a shell that runs this in a loop
        // stops at Ctrl-C only when the tool it waited for died of it.
        libc::raise(signal);
        libc::_exit(128 + signal);
    }
}

/// The action for `signal` now, without changing it.
fn signal_action(signal: libc::c_int) -> libc::sigaction {
    // SAFETY: an all-zero sigaction is a valid value for sigaction to fill in, and a null new action
    // only reads the current one.
    unsafe {
        let mut current: libc::sigaction = std::mem::zeroed();
        libc::sigaction(signal, std::ptr::null(), &mut current);
        current
    }
}

fn create(arguments: &[String]) {
    // What the machine is made from: a system to install, which comes first, or a template.
    let system = arguments.first().filter(|first| !first.starts_with("--")).cloned();
    if system.is_none() && !arguments.iter().any(|argument| argument == "--template") {
        fail("Missing system: macos, windows, or a Linux image such as ubuntu-26.04. Or a template, with --template <template>.");
    }
    let mut parameters = CreateParameters::new(system.clone().unwrap_or_default());
    let mut options: Vec<String> = Vec::new();
    let mut index = if system.is_none() { 0 } else { 1 };
    let value = |index: &mut usize, option: &str| -> String {
        *index += 1;
        arguments.get(*index).cloned().unwrap_or_else(|| fail(&format!("{option} needs a value.")))
    };
    let number = |index: &mut usize, option: &str| -> i64 {
        match value(index, option).parse::<i64>() {
            Ok(number) if number > 0 => number,
            _ => fail(&format!("{option} needs a positive number.")),
        }
    };
    while index < arguments.len() {
        let option = arguments[index].clone();
        options.push(option.clone());
        match option.as_str() {
            "--template" => parameters.template = Some(value(&mut index, &option)),
            "--name" => parameters.name = Some(value(&mut index, &option)),
            "--cpus" => parameters.cpu_count = Some(number(&mut index, &option)),
            "--memory" => parameters.memory_gigabytes = Some(number(&mut index, &option)),
            "--disk" => parameters.disk_gigabytes = Some(number(&mut index, &option)),
            "--user" => parameters.user = Some(value(&mut index, &option)),
            "--password" => parameters.password = Some(value(&mut index, &option)),
            "--location" => parameters.location = Some(standardized_path(&value(&mut index, &option))),
            "--no-ssh-key" => parameters.installs_ssh_key = Some(false),
            "--rosetta" => parameters.rosetta = Some(true),
            "--nested-virt" => parameters.nested_virtualization = Some(true),
            "--gpu" => parameters.accelerates_graphics = Some(true),
            "--no-gpu" => parameters.accelerates_graphics = Some(false),
            "--compressed" => parameters.compressed = Some(true),
            "--ipsw" => parameters.restore_image_path = Some(standardized_path(&value(&mut index, &option))),
            "--iso" => parameters.installer_path = Some(standardized_path(&value(&mut index, &option))),
            "--script" => {
                // A name is one from the list. What has a slash in it is a file: ./mine.sh, ~/scripts/mine.sh.
                // The app is told where the file is from the root, as it isn't in this folder.
                let script = value(&mut index, &option);
                let script = if script.contains('/') { standardized_path(&script) } else { script };
                parameters.scripts.get_or_insert_with(Vec::new).push(script);
            }
            "--no-start" => parameters.start = false,
            _ => fail(&format!("Unknown option {option}.")),
        }
        index += 1;
    }
    if options.iter().any(|option| option == "--gpu") && options.iter().any(|option| option == "--no-gpu") {
        fail("Use --gpu or --no-gpu, not both.");
    }
    if parameters.template.is_some() {
        if system.is_some() {
            fail("Give a system to install or a template, not both.");
        }
        // A template brings its system, its account and whatever was set up in it.
        let allowed = ["--template", "--name", "--cpus", "--memory", "--disk", "--location", "--no-start"];
        if let Some(option) = options.iter().find(|option| !allowed.contains(&option.as_str())) {
            fail(&format!("{option} isn't for a machine made from a template, which keeps the template's system and account."));
        }
    }
    // The app creates the machine, and goes on with it when this tool is stopped while it waits. Whoever
    // stopped it is told so, and how to wait for the machine or to call its creation off.
    let creating = match &parameters.name {
        Some(name) => format!("`swiftvm wait {0}` waits until it is ready, `swiftvm delete {0}` cancels it.", shell_word(name)),
        None => "`swiftvm list` shows it, `swiftvm delete <name>` cancels it.".into(),
    };
    let message = format!("\nswiftvm: Stopped waiting. {} goes on creating the machine: {creating}\n", identity().name()).into_bytes();
    STOP_MESSAGE_LENGTH.store(message.len(), Ordering::Relaxed);
    STOP_MESSAGE.store(Box::leak(message.into_boxed_slice()).as_mut_ptr(), Ordering::Relaxed);
    // A signal that was ignored when this tool started, as Ctrl-C is for `create &` in a script, stays so.
    // SAFETY: an all-zero sigaction is valid, and is filled in below.
    let mut stopping: libc::sigaction = unsafe { std::mem::zeroed() };
    stopping.sa_sigaction = stop_waiting as extern "C" fn(libc::c_int) as libc::sighandler_t;
    stopping.sa_flags = libc::SA_RESETHAND | libc::SA_NODEFER;
    let interruptions: Vec<(libc::c_int, libc::sigaction)> = [libc::SIGINT, libc::SIGTERM, libc::SIGHUP]
        .into_iter()
        .filter_map(|signal| {
            let previous = signal_action(signal);
            if previous.sa_sigaction == libc::SIG_IGN {
                return None;
            }
            // SAFETY: the handler only does what is safe in one.
            unsafe { libc::sigaction(signal, &stopping, std::ptr::null_mut()) };
            Some((signal, previous))
        })
        .collect();
    let start = parameters.start;
    let created = send(ControlRequest { create: Some(parameters), ..ControlRequest::new(Command::Create) });
    for (signal, previous) in interruptions {
        // SAFETY: puts back what was there before.
        unsafe { libc::sigaction(signal, &previous, std::ptr::null_mut()) };
    }
    print_table(&created.machines, &[]);
    print_note(created.note);
    // The system sets itself up from here on, which takes from seconds to half an hour.
    if start && let Some(machine) = created.machines.first() {
        let name = machine.ssh_alias.clone().unwrap_or_else(|| machine.id.to_string());
        say(&format!("\nNext: `swiftvm wait {name}` waits until it is set up and ready for exec, cp and control."));
    }
}

// MARK: The commands

fn main() {
    restore_broken_pipe_signal();
    let mut arguments: Vec<String> = std::env::args_os().skip(1).map(|argument| argument.to_string_lossy().into_owned()).collect();
    if arguments.is_empty() {
        say(overview());
        exit(0);
    }
    let command_name = arguments.remove(0);

    // `swiftvm exec --help` is `swiftvm help exec`.
    if arguments.first().is_some_and(|first| first == "--help" || first == "-h")
        && command_name != "help"
        && let Some(text) = help(&command_name)
    {
        say(&text);
        exit(0);
    }

    match command_name.as_str() {
        "help" | "--help" | "-h" => match arguments.first() {
            Some(topic) => match help(topic) {
                Some(text) => say(&text),
                None => fail(&format!("No command is called “{topic}”.\n\n{}", overview())),
            },
            None => say(overview()),
        },

        "list" | "ls" => {
            let listed = send(ControlRequest::new(Command::List));
            print_table(&listed.machines, listed.creations.as_deref().unwrap_or_default());
        }

        "create" => create(&arguments),

        "scripts" => {
            if arguments.len() > 1 {
                fail("Usage: swiftvm scripts [<system>]");
            }
            let response = send(ControlRequest { system: arguments.first().cloned(), ..ControlRequest::new(Command::Scripts) });
            print_scripts(response.setup_scripts.as_deref().unwrap_or_default());
            print_note(response.note);
        }

        "share" | "unshare" => {
            let machine = require_machine(&arguments);
            if arguments.len() < 2 {
                fail("Missing folder path.");
            }
            reject_unknown_options(&arguments[2..], if command_name == "share" { &["--read-only"] } else { &[] });
            let share = ShareParameters {
                path: standardized_path(&arguments[1]),
                read_only: arguments[2..].iter().any(|option| option == "--read-only"),
            };
            let command = if command_name == "share" { Command::Share } else { Command::Unshare };
            print_table(&send(ControlRequest { share: Some(share), ..ControlRequest::for_machine(command, machine) }).machines, &[]);
        }

        "info" => {
            if let Some(machine) = first_machine(ControlRequest::for_machine(Command::Info, require_machine(&arguments))) {
                print_details(&machine);
            }
        }

        "stats" => {
            if arguments.len() > 1 {
                fail("Usage: swiftvm stats [<machine>]");
            }
            if let Some(machine) = arguments.first() {
                print_usage(&send(ControlRequest::for_machine(Command::List, machine.as_str())).machines);
            } else {
                // The machines that hold a guest, as the app's own list has them.
                let running: Vec<MachineSummary> = send(ControlRequest::new(Command::List))
                    .machines
                    .into_iter()
                    .filter(|machine| machine.state != "stopped" && machine.state != "suspended")
                    .collect();
                if running.is_empty() {
                    say("No virtual machine is running.");
                } else {
                    print_usage(&running);
                }
            }
        }

        "attach" | "eject" => {
            let machine = require_machine(&arguments);
            if arguments.len() < 2 {
                fail("Missing disk image.");
            }
            reject_unknown_options(&arguments[2..], if command_name == "attach" { &["--read-only"] } else { &[] });
            // To eject, the file name is enough; the app looks it up among the attached images.
            let is_path = command_name == "attach" || arguments[1].contains('/');
            let path = if is_path { standardized_path(&arguments[1]) } else { arguments[1].clone() };
            let drive = DriveParameters { path, read_only: arguments[2..].iter().any(|option| option == "--read-only") };
            let command = if command_name == "attach" { Command::Attach } else { Command::Eject };
            if let Some(machine) = first_machine(ControlRequest { drive: Some(drive), ..ControlRequest::for_machine(command, machine) }) {
                print_details(&machine);
            }
        }

        "network-interfaces" => {
            if !arguments.is_empty() {
                fail("Usage: swiftvm network-interfaces");
            }
            let response = send(ControlRequest::new(Command::NetworkInterfaces));
            for interface in response.network_interfaces.iter().flatten() {
                say(&format!("{}  {}", interface.identifier, interface.name));
            }
            if response.network_interfaces.as_ref().is_some_and(Vec::is_empty) {
                say("No host interfaces are available for bridging.");
            }
            if let Some(note) = response.note {
                say(&note);
            }
        }

        "network" => {
            let machine = require_machine(&arguments);
            let usage = "Usage: swiftvm network <machine> shared | bridged <interface> | mac <address>";
            if arguments.len() < 2 {
                fail(usage);
            }
            let mode = arguments[1].clone();
            if !((mode == "shared" && arguments.len() == 2) || ((mode == "bridged" || mode == "mac") && arguments.len() == 3)) {
                fail(usage);
            }
            let request = ControlRequest {
                network_mode: Some(mode.clone()),
                bridged_interface_identifier: (mode == "bridged").then(|| arguments[2].clone()),
                mac_address: (mode == "mac").then(|| arguments[2].clone()),
                ..ControlRequest::for_machine(Command::Network, machine)
            };
            if let Some(machine) = first_machine(request) {
                print_details(&machine);
            }
        }

        "forward" | "unforward" => {
            let machine = require_machine(&arguments);
            if arguments.len() < 2 {
                fail("Missing port.");
            }
            let ports: Vec<Option<u16>> = arguments[1].split(':').map(|port| port.parse().ok()).collect();
            let host_port = match ports.first() {
                Some(Some(port)) if (1..=2).contains(&ports.len()) && *port > 0 && ports.iter().all(|port| port.unwrap_or(0) > 0) => *port,
                _ => fail(&format!("“{}” isn't a port. Use <port> or <port on this Mac>:<port in the machine>.", arguments[1])),
            };
            let options = &arguments[2..];
            reject_unknown_options(options, if command_name == "forward" { &["--udp", "--allow-others"] } else { &["--udp"] });
            let forward = ForwardParameters {
                host_port,
                guest_port: ports.get(1).copied().flatten(),
                udp: options.iter().any(|option| option == "--udp"),
                allows_other_devices: options.iter().any(|option| option == "--allow-others"),
            };
            let command = if command_name == "forward" { Command::Forward } else { Command::Unforward };
            if let Some(machine) = first_machine(ControlRequest { forward: Some(forward), ..ControlRequest::for_machine(command, machine) })
            {
                print_details(&machine);
            }
        }

        "install-tools" => {
            let machine = require_machine(&arguments);
            let mut options = arguments[1..].to_vec();
            let password = take_option(&mut options, "--password");
            reject_unknown_options(&options, &["--disc"]);
            let uses_disc = options.iter().any(|option| option == "--disc");
            if password.is_some() && uses_disc {
                fail("--password is for installing over SSH, not from the disc.");
            }
            let request = ControlRequest {
                uses_disc: uses_disc.then_some(true),
                password,
                ..ControlRequest::for_machine(Command::InstallTools, machine)
            };
            let response = send(request);
            if let Some(machine) = response.machines.first() {
                print_details(machine);
            }
            print_note(response.note);
        }

        "share-clipboard" | "automation" => {
            let machine = require_machine(&arguments);
            let is_on = on_or_off(&arguments, &format!("Usage: swiftvm {command_name} <machine> on|off"));
            let command = if command_name == "automation" { Command::Automation } else { Command::ShareClipboard };
            if let Some(machine) = first_machine(ControlRequest { is_on: Some(is_on), ..ControlRequest::for_machine(command, machine) }) {
                print_details(&machine);
            }
        }

        "wait" => {
            let machine = require_machine(&arguments);
            let mut options = arguments[1..].to_vec();
            let mut timeout = None;
            if let Some(index) = options.iter().position(|option| option == "--timeout") {
                match options.get(index + 1).and_then(|seconds| seconds.parse::<f64>().ok()) {
                    Some(seconds) if seconds > 0.0 && seconds <= ControlRequest::LONGEST_WAIT => timeout = Some(seconds),
                    _ => fail("--timeout needs a number of seconds, a day at most."),
                }
                options.drain(index..=index + 1);
            }
            reject_unknown_options(&options, &[]);
            print_table(&send(ControlRequest { timeout, ..ControlRequest::for_machine(Command::Wait, machine) }).machines, &[]);
        }

        "exec" => guest_jobs::exec(&arguments),
        "cp" => guest_jobs::copy(&arguments),
        "control" => control::run(&arguments),
        "mcp" => mcp::run(&arguments),
        "skill" => skill::run(&arguments),

        "usb" => {
            if arguments.is_empty() {
                let response = send(ControlRequest::new(Command::UsbList));
                print_usb_devices(response.usb_devices.as_deref().unwrap_or_default());
                print_note(response.note);
                exit(0);
            }
            let action = arguments.remove(0);
            let command = match action.as_str() {
                "attach" => Command::UsbAttach,
                "detach" => Command::UsbDetach,
                "auto" => Command::UsbAuto,
                _ => fail("Usage: swiftvm usb [attach <machine> <device> | detach <machine> <device> | auto <machine> <device> on|off]"),
            };
            let machine = require_machine(&arguments);
            let mut rest = arguments[1..].to_vec();
            let mut is_on = None;
            if command == Command::UsbAuto {
                match rest.pop().as_deref() {
                    Some(state @ ("on" | "off")) => is_on = Some(state == "on"),
                    _ => fail("Usage: swiftvm usb auto <machine> <device> on|off"),
                }
            }
            // A device's name can be several words.
            if rest.is_empty() {
                fail("Missing USB device. `swiftvm usb` lists them.");
            }
            let request = ControlRequest { is_on, usb_device: Some(rest.join(" ")), ..ControlRequest::for_machine(command, machine) };
            if let Some(machine) = first_machine(request) {
                print_details(&machine);
            }
        }

        "resize" => {
            let machine = require_machine(&arguments);
            let Some(gigabytes) = arguments.get(1).and_then(|size| size.parse::<i64>().ok()).filter(|gigabytes| *gigabytes > 0) else {
                fail("Missing disk size in GB.")
            };
            reject_unknown_options(&arguments[2..], &[]);
            print_table(
                &send(ControlRequest { disk_gigabytes: Some(gigabytes), ..ControlRequest::for_machine(Command::Resize, machine) }).machines,
                &[],
            );
        }

        "compression" => {
            let machine = require_machine(&arguments);
            let is_on = on_or_off(&arguments, "Usage: swiftvm compression <machine> on|off");
            print_table(
                &send(ControlRequest { is_on: Some(is_on), ..ControlRequest::for_machine(Command::Compression, machine) }).machines,
                &[],
            );
        }

        "move" => {
            let machine = require_machine(&arguments);
            if arguments.len() != 2 {
                fail("Usage: swiftvm move <machine> <folder>. Put a folder with spaces in quotes.");
            }
            // The app is told where the folder is from the root, as it isn't in this folder.
            let request =
                ControlRequest { location: Some(standardized_path(&arguments[1])), ..ControlRequest::for_machine(Command::Move, machine) };
            if let Some(machine) = first_machine(request) {
                print_details(&machine);
            }
        }

        "clone" | "duplicate" => {
            let machine = require_machine(&arguments);
            // The name can be given the way `create` takes it or the way `snapshot` does.
            let mut rest = arguments[1..].to_vec();
            let mut name = take_option(&mut rest, "--name");
            if let Some(option) = rest.iter().find(|word| word.starts_with("--")) {
                fail(&format!("Unknown option {option}."));
            }
            if !rest.is_empty() {
                if name.is_some() {
                    fail("Give the copy's name once.");
                }
                name = Some(rest.join(" "));
            }
            print_table(&send(ControlRequest { name, ..ControlRequest::for_machine(Command::Clone, machine) }).machines, &[]);
        }

        "snapshot" => {
            let machine = require_machine(&arguments);
            let name = (arguments.len() >= 2).then(|| arguments[1..].join(" "));
            print_snapshots(
                send(ControlRequest { name, ..ControlRequest::for_machine(Command::Snapshot, machine) })
                    .snapshots
                    .as_deref()
                    .unwrap_or_default(),
            );
        }

        "snapshots" => {
            print_snapshots(
                send(ControlRequest::for_machine(Command::Snapshots, require_machine(&arguments))).snapshots.as_deref().unwrap_or_default(),
            );
        }

        "revert" | "delete-snapshot" => {
            let machine = require_machine(&arguments);
            if arguments.len() < 2 {
                fail("Missing snapshot name.");
            }
            let command = if command_name == "revert" { Command::Revert } else { Command::DeleteSnapshot };
            let response =
                send(ControlRequest { snapshot: Some(arguments[1..].join(" ")), ..ControlRequest::for_machine(command, machine) });
            if command == Command::Revert {
                print_table(&response.machines, &[]);
            } else {
                print_snapshots(response.snapshots.as_deref().unwrap_or_default());
            }
        }

        "rename-snapshot" => {
            let machine = require_machine(&arguments);
            if arguments.len() != 3 {
                fail("Usage: swiftvm rename-snapshot <machine> <snapshot> <new name>. Put a name with spaces in quotes.");
            }
            let request = ControlRequest {
                name: Some(arguments[2].clone()),
                snapshot: Some(arguments[1].clone()),
                ..ControlRequest::for_machine(Command::RenameSnapshot, machine)
            };
            print_snapshots(send(request).snapshots.as_deref().unwrap_or_default());
        }

        "templates" => {
            if !arguments.is_empty() {
                fail("Usage: swiftvm templates");
            }
            let response = send(ControlRequest::new(Command::Templates));
            print_templates(response.templates.as_deref().unwrap_or_default());
            print_note(response.note);
        }

        "save-template" => {
            let machine = require_machine(&arguments);
            let mut rest = arguments[1..].to_vec();
            let snapshot = take_option(&mut rest, "--snapshot");
            if let Some(option) = rest.iter().find(|word| word.starts_with("--")) {
                fail(&format!("Unknown option {option}."));
            }
            // A name can be several words, as a snapshot's can.
            let name = (!rest.is_empty()).then(|| rest.join(" "));
            print_templates(
                send(ControlRequest { name, snapshot, ..ControlRequest::for_machine(Command::SaveTemplate, machine) })
                    .templates
                    .as_deref()
                    .unwrap_or_default(),
            );
        }

        "delete-template" => {
            if arguments.is_empty() {
                fail("Missing template name.");
            }
            let request = ControlRequest { template: Some(arguments.join(" ")), ..ControlRequest::new(Command::DeleteTemplate) };
            print_templates(send(request).templates.as_deref().unwrap_or_default());
        }

        "rename-template" => {
            if arguments.len() != 2 {
                fail("Usage: swiftvm rename-template <template> <new name>. Put a name with spaces in quotes.");
            }
            let request = ControlRequest {
                name: Some(arguments[1].clone()),
                template: Some(arguments[0].clone()),
                ..ControlRequest::new(Command::RenameTemplate)
            };
            print_templates(send(request).templates.as_deref().unwrap_or_default());
        }

        "console" => {
            let machine = require_machine(&arguments);
            let mut idle_timeout = None;
            if let Some(index) = arguments.iter().position(|argument| argument == "--wait") {
                match arguments.get(index + 1).and_then(|seconds| seconds.parse::<f64>().ok()) {
                    Some(seconds) if (0.0..=86_400.0).contains(&seconds) => idle_timeout = Some(seconds),
                    _ => fail("--wait needs a number of seconds, a day at most."),
                }
            }
            match client().open_stream(&ControlRequest::for_machine(Command::Console, machine.as_str())) {
                Ok((response, Some(connection))) => {
                    let name = response.machines.first().map(|machine| machine.name.clone()).unwrap_or(machine);
                    console::run(connection.into_raw_fd(), &name, idle_timeout)
                }
                Ok((response, None)) => fail(response.error.as_deref().unwrap_or("The console isn't available.")),
                Err(error) => fail(&error.to_string()),
            }
        }

        "quit" => {
            reject_unknown_options(&arguments, &["--cancel-creations"]);
            let cancels = arguments.iter().any(|argument| argument == "--cancel-creations");
            send(ControlRequest { cancels_creations: cancels.then_some(true), ..ControlRequest::new(Command::Quit) });
        }

        "ip" => {
            let response = send(ControlRequest::for_machine(Command::List, require_machine(&arguments)));
            match response.machines.first().and_then(|machine| machine.address.clone()) {
                Some(address) => say(&address),
                None => fail("The machine has no address yet."),
            }
        }

        "vsock" => {
            let machine = require_machine(&arguments);
            let Some(port) = arguments.get(1).and_then(|port| port.parse::<u32>().ok()).filter(|port| arguments.len() == 2 && *port > 0)
            else {
                fail("Usage: swiftvm vsock <machine> <port>")
            };
            match client().open_stream(&ControlRequest { port: Some(port), ..ControlRequest::for_machine(Command::Vsock, machine) }) {
                Ok((_, Some(connection))) => stream::run(connection.into_raw_fd()),
                Ok((response, None)) => fail(response.error.as_deref().unwrap_or("The connection couldn't be made.")),
                Err(error) => fail(&error.to_string()),
            }
        }

        "ssh" => ssh(&arguments),

        _ => {
            // What is left takes a machine and nothing else. The USB commands are spelled `usb …`, above.
            let others = [
                Command::Create,
                Command::List,
                Command::Quit,
                Command::UsbList,
                Command::UsbAttach,
                Command::UsbDetach,
                Command::UsbAuto,
                Command::Scripts,
                Command::Job,
                Command::Control,
                Command::AllowAccessibility,
                Command::Move,
                Command::Templates,
                Command::SaveTemplate,
                Command::DeleteTemplate,
                Command::RenameTemplate,
            ];
            let Some(command) = Command::from_raw_value(&command_name).filter(|command| !others.contains(command)) else {
                fail(&format!("Unknown command “{command_name}”.\n\n{}", overview()))
            };
            let response = send(ControlRequest::for_machine(command, require_machine(&arguments)));
            // `delete` of a machine that was still being created has no machine to show, only what it did.
            if !response.machines.is_empty() || response.note.is_none() {
                print_table(&response.machines, &[]);
            }
            if let Some(note) = response.note {
                say(&if response.machines.is_empty() { note } else { format!("\n{note}") });
            }
        }
    }
    exit(0)
}

/// `swiftvm ssh`: becomes `ssh` with the app's configuration, which knows the machine by its alias.
fn ssh(arguments: &[String]) -> ! {
    let response = send(ControlRequest::for_machine(Command::List, require_machine(arguments)));
    let Some((machine, alias)) = response.machines.first().and_then(|machine| Some((machine, machine.ssh_alias.clone()?))) else {
        fail("The machine has no SSH alias.")
    };
    let mut rest = arguments[1..].to_vec();
    let mut options = Vec::new();
    if rest.first().map(String::as_str) == Some("--vsock") {
        rest.remove(0);
        // ssh runs this in a shell, after replacing what starts with a percent sign, and talks to it
        // instead of connecting to the machine's address.
        let tool = tool_path().to_string_lossy().into_owned();
        let quoted = format!("'{}'", tool.replace('\'', "'\\''"));
        let command = format!("{quoted} vsock {} {}", machine.id, stream::SSH_PORT).replace('%', "%%");
        options = vec!["-o".to_string(), format!("ProxyCommand={command}")];
    }
    let mut words = vec!["ssh".to_string(), "-F".to_string(), paths().ssh_config().to_string_lossy().into_owned()];
    words.extend(options);
    words.push(alias);
    words.extend(rest);
    let program = if cfg!(target_os = "macos") { "/usr/bin/ssh" } else { "ssh" };
    let words: Vec<CString> =
        words.into_iter().map(|word| CString::new(word).unwrap_or_else(|_| fail("An argument has a zero byte in it."))).collect();
    let mut pointers: Vec<*const libc::c_char> = words.iter().map(|word| word.as_ptr()).collect();
    pointers.push(std::ptr::null());
    let program = CString::new(program).expect("no zero byte");
    // SAFETY: a NUL-terminated program name and a null-terminated list of NUL-terminated arguments.
    unsafe { libc::execvp(program.as_ptr(), pointers.as_ptr()) };
    fail(&format!("Couldn't run ssh: {}", swiftvm_protocol::io::strerror(swiftvm_protocol::io::errno())))
}
