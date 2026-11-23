//! `swiftvm control`: sees and works a machine's desktop, for scripts and agents.

use std::collections::BTreeMap;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use swiftvm_protocol::io;
use swiftvm_protocol::{
    Action, Button, Command, ControlCall, ControlOutcome, ControlRequest, ControlStep, ControlTarget, Direction, JobFrame, JobFrameKind,
    ServiceClient, control_exit,
};

use unicode_segmentation::UnicodeSegmentation;

use crate::format::{self, LocalTime};
use crate::util::{client, exit, fail_with, ignore_broken_pipe_signal, prints_json, say, send, set_prints_json, warn};

pub const USAGE: &str = r#"Usage: swiftvm control <machine> <action> [arguments] [--then <action> [arguments]]... [--json]

See and work a machine's desktop, the same on macOS, Windows and Linux, at a login screen too. The app
reads the machine's screen and uses its mouse and keyboard from outside the guest, so nothing there has
to allow it. Steps joined with --then run in one go: no process starts between them.

Look
  look [--changes] [--image[=<file>]] [--region <x> <y> <w> <h>] [--app <name>] [--all] [--ocr]
      What is on the screen, one numbered line each:  [12] button "Save" #settings-save 640,400 80x24
      Author-provided accessibility ids appear as #<id>, or as "id" in --json, omitted when empty.
      The numbers stay with an element from look to look. --changes says only what changed. --image
      also saves a JPEG, whose pixels are the places in the list (it prints where). --region shows that
      part as sharp as it is, for reading: only the list's places are for clicking. By default a look covers the application in front; --app and --all widen
      it. What accessibility doesn't tell is read off the pixels; --ocr does that always.
  wait [--text <text> | --gone <text> | --id <id> | --id-gone <id>] [--timeout <seconds>]
      Until the text or exact id is on the screen or has left it (30 seconds by default, then ending
      with 124), or without a condition until the screen has settled (10 seconds at most, then carrying on).
  screenshot [<file> | -]
      The display as a PNG, at its own full size. Prefer look --image, unless pixels matter.

Act: <target> is a number from the last look, a text on the screen, '#<id>', or <x> <y>
  click <target> [--right | --middle] [--double | --count <n>]
  move <target>
  drag <target> --to <target>
  scroll [<target>] up|down|left|right [<notches>]
  type <text>                 Any text. Characters a US keyboard lacks need guest tools
  key <key>...                One after the other: Return, Escape, Tab, cmd+s, ctrl+shift+t, F5, shift
  set <number | text | #id> <text>  Replace what a text field holds, as a person would. '' empties it
  focus <target>              Give it the keyboard

In the guest's session
  open <application | file | URL>
  clipboard [<text>]          Say what is on the clipboard, or put text there

Other
  allow --password <password>  Have macOS let the guest tools read its screen. Quick Create and
                               install-tools --password do this already. No other system asks

Text in a target goes by what the element says, ignoring case; when several say it, nothing is done
and the numbers are listed. A number is checked before it is used: one whose element has gone, or that
can't be told apart from others like it any more, is an error, never a click somewhere else.
'#<id>' matches an accessibility id exactly and case-sensitively, never text. No match fails; several
matches fail and list their numbers. Quote # targets so the shell doesn't take them for comments.
Ids need current guest tools and an application that publishes them; OCR cannot supply them.

Exit status: 0 done, 1 a step failed, 124 a wait ran out of time, 125 it couldn't be asked.

Examples
  swiftvm control desk look
  swiftvm control desk click 12 --then type 'hello' --then key Return --then look --changes
  swiftvm control desk click 'Sign In' --then wait --text 'Welcome' --timeout 60
  swiftvm control desk click '#settings-save' --then wait --id-gone settings-save
  swiftvm control desk look --image=/tmp/screen.jpg"#;

/// What arguments mean, or why they mean nothing.
#[derive(Debug, PartialEq)]
pub struct ParseError(pub String);

fn invalid<T>(reason: &str) -> Result<T, ParseError> {
    Err(ParseError(reason.to_string()))
}

#[derive(Debug, PartialEq, Default)]
pub struct Request {
    pub call: ControlCall,
    /// Where to save what each step shows, by the step's position.
    pub image_files: BTreeMap<usize, String>,
    pub prints_json: bool,
}

pub fn run(arguments: &[String]) -> ! {
    let is_help = |word: &str| ["--help", "-h", "help"].contains(&word);
    let Some(machine) = arguments.first().filter(|machine| !machine.starts_with('-')) else {
        if arguments.first().is_none_or(|first| is_help(first)) {
            say(USAGE);
            exit(if arguments.is_empty() { control_exit::COULD_NOT_RUN } else { 0 });
        }
        fail_with(USAGE, control_exit::COULD_NOT_RUN)
    };
    let rest = &arguments[1..];
    if rest.first().is_none_or(|first| is_help(first)) {
        say(USAGE);
        exit(if rest.is_empty() { control_exit::COULD_NOT_RUN } else { 0 });
    }
    if rest[0] == "allow" {
        allow(machine, &rest[1..]);
    }
    let mut request = match parse(rest) {
        Ok(request) => request,
        Err(ParseError(reason)) => fail_with(&format!("{reason}\nFor what there is: swiftvm control --help"), control_exit::COULD_NOT_RUN),
    };
    // `swiftvm --json control …` asks for the same as `--json` at the end.
    request.prints_json |= prints_json();
    set_prints_json(request.prints_json);
    ignore_broken_pipe_signal();
    let outcome = match call(&request.call, machine, deadline(&request.call), &client()) {
        Ok(outcome) => outcome,
        Err(error) => fail_with(&error, control_exit::COULD_NOT_RUN),
    };
    report(outcome, &request, machine)
}

/// How long a call may take, in the tool, past which the app is taken not to answer.
pub fn deadline(call: &ControlCall) -> Duration {
    // Long text takes as long as its keys, which is a tenth of a second each on the slowest keyboard.
    let seconds = call.steps.iter().fold(60.0, |total, step| {
        let waiting = if step.action == Action::Wait { step.timeout.unwrap_or(30.0) } else { 0.0 };
        total + waiting + step.text.as_deref().map_or(0, format::characters) as f64 * 0.1
    });
    Duration::from_secs_f64(seconds.clamp(0.0, 1e9))
}

/// Has the app do the steps, and returns how they went. The connection carries the outcome in frames.
pub fn call(call: &ControlCall, machine: &str, timeout: Duration, client: &ServiceClient) -> Result<ControlOutcome, String> {
    let request = ControlRequest { control: Some(call.clone()), ..ControlRequest::for_machine(Command::Control, machine) };
    let (response, connection) = client.open_stream(&request).map_err(|error| error.to_string())?;
    let Some(connection) = connection else {
        return Err(response.error.map(|error| error.message).unwrap_or_else(|| "The app didn't take that on.".into()));
    };
    let mut collected = Vec::new();
    let deadline = Instant::now() + timeout;
    loop {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()).filter(|remaining| !remaining.is_zero()) else {
            return Err(format!("The app didn't finish that in {} seconds.", timeout.as_secs()));
        };
        let Ok(Some(frame)) = JobFrame::read(connection.as_raw_fd(), Some(remaining)) else {
            return Err("The connection to the app was lost before it was done.".into());
        };
        match frame.kind {
            JobFrameKind::Output => collected.extend_from_slice(&frame.payload),
            JobFrameKind::End => {
                if let Some(error) = frame.end().and_then(|end| end.shown_error()) {
                    return Err(error);
                }
                return serde_json::from_slice(&collected).map_err(|_| "The app's answer couldn't be read.".into());
            }
            JobFrameKind::ErrorOutput | JobFrameKind::Input => {}
        }
    }
}

fn report(mut outcome: ControlOutcome, request: &Request, machine: &str) -> ! {
    for index in 0..outcome.results.len() {
        let Some(image) = outcome.results[index].image.take() else { continue };
        let file = request.image_files.get(&index);
        if file.map(String::as_str) == Some("-") {
            io::write_all(libc::STDOUT_FILENO, &image);
            exit(control_exit::status(&outcome));
        }
        let is_png = outcome.results[index].action == Action::Screenshot;
        let path = file.cloned().unwrap_or_else(|| default_image_path(machine, if is_png { "png" } else { "jpg" }));
        if let Err(error) = write_atomically(&PathBuf::from(&path), &image) {
            fail_with(&format!("The picture couldn't be saved: {error}"), control_exit::FAILED);
        }
        outcome.results[index].note = Some(format!("image: {path}"));
    }
    if request.prints_json {
        // Through a value, whose keys are in order.
        let mut value = serde_json::to_value(&outcome).unwrap_or_default();
        whole_numbers_as_integers(&mut value);
        say(&serde_json::to_string(&value).unwrap_or_default());
    } else {
        let text: Vec<String> = outcome
            .results
            .iter()
            .filter(|result| result.error.is_none())
            .map(|result| result.text())
            .filter(|text| !text.is_empty())
            .collect();
        if !text.is_empty() {
            say(&text.join("\n"));
        }
        if let Some(failure) = outcome.failure()
            && let Some(error) = &failure.error
        {
            warn(&format!("swiftvm: {}: {error}", failure.action.name()));
        }
    }
    exit(control_exit::status(&outcome))
}

/// Writes a number without a fraction as an integer, `2` rather than `2.0`, as Swift's JSON does.
fn whole_numbers_as_integers(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Number(number) => {
            if let Some(float) = number.as_f64().filter(|_| number.is_f64())
                && float.fract() == 0.0
                && float.abs() < 9_007_199_254_740_992.0
            {
                *value = serde_json::Value::from(float as i64);
            }
        }
        serde_json::Value::Array(items) => items.iter_mut().for_each(whole_numbers_as_integers),
        serde_json::Value::Object(fields) => fields.values_mut().for_each(whole_numbers_as_integers),
        _ => {}
    }
}

/// Writes `data` to a file next to `path` and then puts it in its place, so that nobody sees half of it.
pub fn write_atomically(path: &PathBuf, data: &[u8]) -> std::io::Result<()> {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let staged = path.with_file_name(format!(".{name}.{}", std::process::id()));
    std::fs::write(&staged, data)?;
    std::fs::rename(&staged, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&staged);
    })
}

fn default_image_path(machine: &str, extension: &str) -> String {
    let stem: String = machine
        .graphemes(true)
        .map(|character| if character == "-" || character.starts_with(char::is_alphanumeric) { character } else { "-" })
        .collect();
    let folder = std::env::temp_dir().join("swiftvm");
    let _ = std::fs::create_dir_all(&folder);
    folder.join(format!("{stem}-{}.{extension}", LocalTime::now().stamp())).to_string_lossy().into_owned()
}

fn allow(machine: &str, arguments: &[String]) -> ! {
    if arguments.len() != 2 || arguments[0] != "--password" {
        fail_with("Usage: swiftvm control <machine> allow --password <password>", control_exit::COULD_NOT_RUN);
    }
    let request =
        ControlRequest { password: Some(arguments[1].clone()), ..ControlRequest::for_machine(Command::AllowAccessibility, machine) };
    if let Some(note) = send(request).note {
        say(&note);
    }
    exit(0)
}

// MARK: Reading the arguments

pub fn parse(arguments: &[String]) -> Result<Request, ParseError> {
    let mut arguments = arguments.to_vec();
    let mut request = Request::default();
    // At the very end, or it could be what is to be typed.
    if arguments.last().map(String::as_str) == Some("--json") {
        request.prints_json = true;
        arguments.pop();
    }
    let mut pieces: Vec<Vec<String>> = vec![Vec::new()];
    for argument in arguments {
        if argument == "--then" {
            pieces.push(Vec::new());
        } else {
            pieces.last_mut().expect("there is always a piece").push(argument);
        }
    }
    for piece in pieces {
        let Some(name) = piece.first() else { return invalid("A step is missing around --then.") };
        let (step, file) = parse_step(name, &piece[1..])?;
        if let Some(file) = file {
            request.image_files.insert(request.call.steps.len(), file);
        }
        request.call.steps.push(step);
    }
    Ok(request)
}

fn parse_step(name: &str, arguments: &[String]) -> Result<(ControlStep, Option<String>), ParseError> {
    let Some(action) = Action::from_name(name) else {
        return invalid(&format!("“{name}” isn't an action. The old `ui`, `desktop` and `screenshot` commands are all this one now."));
    };
    let mut words = Words(arguments.to_vec());
    let mut step = ControlStep::new(action);
    let mut file = None;
    match action {
        Action::Look => {
            step.changes = words.flag("--changes").then_some(true);
            step.all = words.flag("--all").then_some(true);
            step.ocr = words.flag("--ocr").then_some(true);
            step.application = words.option("--app")?;
            if words.flag("--image") {
                step.image = Some(true);
            } else if let Some(path) = words.prefixed("--image=") {
                step.image = Some(true);
                file = Some(path);
            }
            if let Some(index) = words.0.iter().position(|word| word == "--region") {
                if index + 4 >= words.0.len() {
                    return invalid("--region takes its left, top, width and height.");
                }
                let numbers: Vec<i64> = words.0[index + 1..=index + 4].iter().filter_map(|word| word.parse().ok()).collect();
                if numbers.len() != 4 {
                    return invalid("--region takes its left, top, width and height, as numbers.");
                }
                step.region = Some(numbers);
                step.image = Some(true);
                words.0.drain(index..=index + 4);
            }
        }
        Action::Wait => {
            step.text = words.option("--text")?;
            step.gone = words.option("--gone")?;
            step.id = words.option("--id")?;
            step.id_gone = words.option("--id-gone")?;
            step.timeout = words.seconds("--timeout")?;
            if [&step.text, &step.gone, &step.id, &step.id_gone].iter().filter(|condition| condition.is_some()).count() > 1 {
                return invalid("Wait for --text, --gone, --id or --id-gone, one at a time.");
            }
            if step.id.as_deref() == Some("") || step.id_gone.as_deref() == Some("") {
                return invalid("An id must not be empty.");
            }
        }
        Action::Screenshot => {
            if !words.0.is_empty() {
                file = Some(words.0.remove(0));
            }
        }
        Action::Click => {
            if words.flag("--right") {
                step.button = Some(Button::Right);
            }
            if words.flag("--middle") {
                step.button = Some(Button::Middle);
            }
            if words.flag("--double") {
                step.count = Some(2);
            }
            if let Some(count) = words.option("--count")? {
                match count.parse::<i64>() {
                    Ok(number) if (1..=3).contains(&number) => step.count = Some(number),
                    _ => return invalid("--count is 1, 2 or 3."),
                }
            }
            step.target = Some(words.target()?);
        }
        Action::Move | Action::Focus => step.target = Some(words.target()?),
        Action::Drag => {
            let Some(index) = words.0.iter().position(|word| word == "--to") else {
                return invalid("A drag goes somewhere: drag <target> --to <target>.");
            };
            let mut to = Words(words.0[index + 1..].to_vec());
            step.to = Some(to.target()?);
            if let Some(extra) = to.0.first() {
                return invalid(&format!("“{extra}” is one word too many."));
            }
            words.0.truncate(index);
            step.target = Some(words.target()?);
        }
        Action::Scroll => {
            if let Some(index) = words.0.iter().position(|word| Direction::from_name(word).is_some()) {
                step.direction = Direction::from_name(&words.0[index]);
                if index + 1 < words.0.len() {
                    let Ok(notches) = words.0[index + 1].parse::<i64>() else {
                        return invalid("How far to scroll is a number of notches.");
                    };
                    step.amount = Some(notches);
                    words.0.remove(index + 1);
                }
                words.0.remove(index);
            }
            if !words.0.is_empty() {
                step.target = Some(words.target()?);
            }
            if step.direction.is_none() {
                return invalid("Scrolling goes up, down, left or right.");
            }
        }
        Action::Type => {
            if words.0.is_empty() {
                return invalid("Say what to type.");
            }
            step.text = Some(words.take_all());
        }
        Action::Key => {
            if words.0.is_empty() {
                return invalid("Say which keys to press, such as Return or ctrl+c.");
            }
            step.keys = Some(std::mem::take(&mut words.0));
        }
        Action::Set => {
            // One word for what, and all the rest is the text: a number in it is no place.
            if words.0.len() < 2 {
                return invalid("Say what to set and to what: set <number | text | #id> <text>. '' empties it.");
            }
            let mut target = Words(vec![words.0.remove(0)]);
            step.target = Some(target.target()?);
            step.text = Some(words.take_all());
        }
        Action::Open => {
            if words.0.is_empty() {
                return invalid("Say what to open: an application, a file or a URL.");
            }
            step.text = Some(words.take_all());
        }
        Action::Clipboard => {
            if !words.0.is_empty() {
                step.text = Some(words.take_all());
            }
        }
    }
    if let Some(extra) = words.0.first() {
        return invalid(&format!("“{extra}” is one word too many for {name}."));
    }
    Ok((step, file))
}

/// The words of one step, which options are taken out of as they are read.
struct Words(Vec<String>);

impl Words {
    fn flag(&mut self, name: &str) -> bool {
        let Some(index) = self.0.iter().position(|word| word == name) else { return false };
        self.0.remove(index);
        true
    }

    fn prefixed(&mut self, prefix: &str) -> Option<String> {
        let index = self.0.iter().position(|word| word.starts_with(prefix))?;
        Some(self.0.remove(index)[prefix.len()..].to_string())
    }

    fn option(&mut self, name: &str) -> Result<Option<String>, ParseError> {
        let Some(index) = self.0.iter().position(|word| word == name) else { return Ok(None) };
        if index + 1 >= self.0.len() {
            return invalid(&format!("{name} needs a value."));
        }
        let value = self.0[index + 1].clone();
        self.0.drain(index..=index + 1);
        Ok(Some(value))
    }

    fn seconds(&mut self, name: &str) -> Result<Option<f64>, ParseError> {
        let Some(text) = self.option(name)? else { return Ok(None) };
        match text.parse::<f64>() {
            Ok(seconds) if seconds >= 0.0 && seconds.is_finite() => Ok(Some(seconds)),
            _ => invalid(&format!("{name} needs a number of seconds.")),
        }
    }

    fn take_all(&mut self) -> String {
        std::mem::take(&mut self.0).join(" ")
    }

    /// Two numbers are a place, one is a number from a look, # names an id, and the rest is text.
    fn target(&mut self) -> Result<ControlTarget, ParseError> {
        let Some(first) = self.0.first().cloned() else {
            return invalid("Say what: a number from the last look, a text on the screen, '#<id>', or a place.");
        };
        if self.0.len() >= 2
            && let (Ok(x), Ok(y)) = (first.parse::<i64>(), self.0[1].parse::<i64>())
        {
            self.0.drain(..2);
            return Ok(ControlTarget::Point { x, y });
        }
        self.0.remove(0);
        if let Some(id) = first.strip_prefix('#') {
            if id.is_empty() {
                return invalid("An id must not be empty.");
            }
            return Ok(ControlTarget::Id(id.to_string()));
        }
        let unbracketed = first.strip_prefix('[').and_then(|inner| inner.strip_suffix(']')).unwrap_or(&first);
        if let Ok(number) = unbracketed.parse::<i64>() {
            return Ok(ControlTarget::Number(number));
        }
        Ok(ControlTarget::Text(first))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &[&str]) -> Vec<String> {
        text.iter().map(|word| word.to_string()).collect()
    }

    fn steps(text: &[&str]) -> Vec<ControlStep> {
        parse(&words(text)).unwrap().call.steps
    }

    fn step(action: Action, change: impl FnOnce(&mut ControlStep)) -> ControlStep {
        let mut step = ControlStep::new(action);
        change(&mut step);
        step
    }

    fn fails(text: &[&str]) -> bool {
        parse(&words(text)).is_err()
    }

    #[test]
    fn steps_joined_with_then_become_one_call() {
        assert_eq!(
            steps(&[
                "click",
                "12",
                "--right",
                "--then",
                "type",
                "hello",
                "world",
                "--then",
                "key",
                "cmd+s",
                "Return",
                "--then",
                "look",
                "--changes"
            ]),
            vec![
                step(Action::Click, |s| {
                    s.target = Some(ControlTarget::Number(12));
                    s.button = Some(Button::Right);
                }),
                step(Action::Type, |s| s.text = Some("hello world".into())),
                step(Action::Key, |s| s.keys = Some(words(&["cmd+s", "Return"]))),
                step(Action::Look, |s| s.changes = Some(true)),
            ]
        );
    }

    #[test]
    fn a_target_is_a_number_a_place_or_a_text() {
        assert_eq!(steps(&["click", "[7]"])[0].target, Some(ControlTarget::Number(7)));
        assert_eq!(steps(&["click", "640", "400"])[0].target, Some(ControlTarget::Point { x: 640, y: 400 }));
        assert_eq!(steps(&["click", "Sign In"])[0].target, Some(ControlTarget::Text("Sign In".into())));
        let drag = &steps(&["drag", "10", "20", "--to", "Trash"])[0];
        assert_eq!(drag.target, Some(ControlTarget::Point { x: 10, y: 20 }));
        assert_eq!(drag.to, Some(ControlTarget::Text("Trash".into())));
    }

    #[test]
    fn identifiers_work_wherever_a_target_does() {
        for action in ["click", "move", "focus"] {
            assert_eq!(steps(&[action, "#Save"])[0].target, Some(ControlTarget::Id("Save".into())));
        }
        let drag = &steps(&["drag", "#source", "--to", "#destination"])[0];
        assert_eq!(
            (drag.target.clone(), drag.to.clone()),
            (Some(ControlTarget::Id("source".into())), Some(ControlTarget::Id("destination".into())))
        );
        assert_eq!(
            steps(&["click", "#row", "--right"])[0],
            step(Action::Click, |s| {
                s.target = Some(ControlTarget::Id("row".into()));
                s.button = Some(Button::Right);
            })
        );
        assert_eq!(steps(&["scroll", "#list", "down"])[0].target, Some(ControlTarget::Id("list".into())));
        assert_eq!(
            steps(&["set", "#search", "100"])[0],
            step(Action::Set, |s| {
                s.target = Some(ControlTarget::Id("search".into()));
                s.text = Some("100".into());
            })
        );
        assert_eq!(steps(&["click", "#12"])[0].target, Some(ControlTarget::Id("12".into())));
        assert!(fails(&["click", "#"]));
    }

    #[test]
    fn identifier_waits_take_one_condition_and_preserve_the_id() {
        assert_eq!(
            steps(&["wait", "--id", "Save", "--timeout", "2"])[0],
            step(Action::Wait, |s| {
                s.timeout = Some(2.0);
                s.id = Some("Save".into());
            })
        );
        assert_eq!(steps(&["wait", "--id-gone", "Save"])[0], step(Action::Wait, |s| s.id_gone = Some("Save".into())));
        let conditions = ["--text", "--gone", "--id", "--id-gone"];
        for first in conditions {
            for second in conditions.into_iter().filter(|second| *second != first) {
                assert!(fails(&["wait", first, "a", second, "b"]));
            }
        }
        for option in ["--id", "--id-gone"] {
            assert!(fails(&["wait", option]));
            assert!(fails(&["wait", option, ""]));
        }
    }

    #[test]
    fn set_takes_one_word_for_what_and_all_the_rest_is_the_text() {
        let set = |target: ControlTarget, text: &str| {
            step(Action::Set, |s| {
                s.target = Some(target);
                s.text = Some(text.into());
            })
        };
        assert_eq!(steps(&["set", "5", "100"])[0], set(ControlTarget::Number(5), "100"));
        assert_eq!(steps(&["set", "Search", "two", "words"])[0], set(ControlTarget::Text("Search".into()), "two words"));
        // Emptying a field is said out loud, and forgetting the text isn't taken for that.
        assert_eq!(steps(&["set", "5", ""])[0], set(ControlTarget::Number(5), ""));
        assert!(fails(&["set", "5"]));
    }

    #[test]
    fn json_is_asked_for_at_the_very_end_and_anywhere_else_is_text() {
        assert!(parse(&words(&["look", "--json"])).unwrap().prints_json);
        let typed = parse(&words(&["type", "--json", "x"])).unwrap();
        assert!(!typed.prints_json);
        assert_eq!(typed.call.steps[0].text.as_deref(), Some("--json x"));
    }

    #[test]
    fn scroll_takes_a_target_or_not() {
        assert_eq!(
            steps(&["scroll", "down", "5"])[0],
            step(Action::Scroll, |s| {
                s.direction = Some(Direction::Down);
                s.amount = Some(5);
            })
        );
        assert_eq!(
            steps(&["scroll", "9", "up"])[0],
            step(Action::Scroll, |s| {
                s.target = Some(ControlTarget::Number(9));
                s.direction = Some(Direction::Up);
            })
        );
    }

    #[test]
    fn a_looks_image_goes_where_it_is_told_or_somewhere_of_its_own() {
        let saved = parse(&words(&["look", "--image=/tmp/s.jpg", "--then", "screenshot", "-"])).unwrap();
        assert_eq!(saved.call.steps[0].image, Some(true));
        assert_eq!(saved.image_files, BTreeMap::from([(0, "/tmp/s.jpg".to_string()), (1, "-".to_string())]));
        let region = &steps(&["look", "--region", "1", "2", "3", "4"])[0];
        assert_eq!((region.region.clone(), region.image), (Some(vec![1, 2, 3, 4]), Some(true)));
    }

    #[test]
    fn what_makes_no_sense_is_said_and_nothing_is_done() {
        let cases: [&[&str]; 7] = [
            &["clack", "1"],
            &["click"],
            &["look", "extra"],
            &["click", "1", "--then"],
            &["scroll", "12"],
            &["wait", "--text", "a", "--gone", "b"],
            &["drag", "1"],
        ];
        for arguments in cases {
            assert!(fails(arguments), "{arguments:?}");
        }
    }
}
