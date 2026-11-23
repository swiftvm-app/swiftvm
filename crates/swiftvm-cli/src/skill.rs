//! `swiftvm skill`: what an agent needs to know to use this tool, of the same version as the tool.

use std::path::PathBuf;

use swiftvm_protocol::paths::{home_directory, standardized_path};

use crate::control::write_atomically;
use crate::util::{exit, fail, say, say_raw};

pub const USAGE: &str = "Usage: swiftvm skill                Print the skill, for an agent to read
       swiftvm skill install [--to <folder>]
                                    Install it for agents: into ~/.claude/skills/swiftvm and
                                    ~/.agents/skills/swiftvm, or into the given folder";

pub const TEXT: &str = include_str!("../SKILL.md");

pub fn run(arguments: &[String]) -> ! {
    match arguments.first().map(String::as_str) {
        None => say_raw(TEXT),
        Some("install") => {
            let folders: Vec<PathBuf> = if arguments.len() == 3 && arguments[1] == "--to" {
                vec![PathBuf::from(standardized_path(&arguments[2]))]
            } else {
                if arguments.len() != 1 {
                    fail(USAGE);
                }
                let home = home_directory();
                [".claude/skills/swiftvm", ".agents/skills/swiftvm"].iter().map(|folder| home.join(folder)).collect()
            };
            for folder in folders {
                let file = folder.join("SKILL.md");
                if let Err(error) = std::fs::create_dir_all(&folder).and_then(|_| write_atomically(&file, TEXT.as_bytes())) {
                    fail(&format!("The skill couldn't be installed in {}: {error}", folder.display()));
                }
                say(&file.to_string_lossy());
            }
        }
        Some("--help" | "-h" | "help") => say(USAGE),
        Some(_) => fail(USAGE),
    }
    exit(0)
}
