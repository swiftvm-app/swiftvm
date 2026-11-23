//! Text as SwiftVM shows it and reads it.

use unicode_segmentation::UnicodeSegmentation;

/// `text` as one line, no longer than `limit` characters as a reader counts them (`é` is one, however
/// it is written): without line breaks and control characters, and without the marks that turn the
/// direction of the text around them, which could make a message read as something it doesn't say.
pub fn shown_line(text: &str, limit: usize) -> String {
    let kept: String = text
        .chars()
        .filter(|&character| !character.is_control() && !matches!(character, '\u{2028}' | '\u{2029}') && !is_direction_mark(character))
        .collect();
    kept.trim().graphemes(true).take(limit).collect()
}

fn is_direction_mark(character: char) -> bool {
    matches!(character as u32, 0x061C | 0x200E | 0x200F | 0x202A..=0x202E | 0x2066..=0x2069)
}

/// `word` as a shell takes it for one argument, for a command to be copied from a message: as it is
/// when it is plain, in single quotes otherwise.
pub fn shell_word(word: &str) -> String {
    let plain = word.chars().next().is_some_and(|first| first != '=' && first != '~')
        && word.chars().all(|character| character.is_ascii_alphanumeric() || "-_.,:/@%+=".contains(character));
    if plain { word.to_string() } else { format!("'{}'", word.replace('\'', "'\\''")) }
}

/// One side of `swiftvm cp`: a path on this computer, or one in a guest, written `<machine>:<path>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CopyEndpoint {
    Local(String),
    Guest { machine: String, path: String },
}

impl CopyEndpoint {
    /// Reads what was typed. A colon makes it a place in a guest, as it does for `scp`, unless a slash
    /// comes before it: `./notes:old.txt` is a file here whose name has a colon in it.
    pub fn parse(text: &str) -> Self {
        match text.find(':') {
            Some(colon) if colon > 0 && !text[..colon].contains('/') => {
                CopyEndpoint::Guest { machine: text[..colon].to_string(), path: text[colon + 1..].to_string() }
            }
            _ => CopyEndpoint::Local(text.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_colon_names_a_place_in_a_guest() {
        let guest = |machine: &str, path: &str| CopyEndpoint::Guest { machine: machine.into(), path: path.into() };
        assert_eq!(CopyEndpoint::parse("web:/etc/hosts"), guest("web", "/etc/hosts"));
        assert_eq!(CopyEndpoint::parse("Web Server:notes.txt"), guest("Web Server", "notes.txt"));
        assert_eq!(CopyEndpoint::parse("web:"), guest("web", ""));
        // Only the first colon counts: what follows is the path, colons and all.
        assert_eq!(CopyEndpoint::parse("web:/tmp/a:b"), guest("web", "/tmp/a:b"));
        assert_eq!(CopyEndpoint::parse("notes.txt"), CopyEndpoint::Local("notes.txt".into()));
        assert_eq!(CopyEndpoint::parse("/Users/me/notes.txt"), CopyEndpoint::Local("/Users/me/notes.txt".into()));
        // A slash before the colon makes it a file here whose name has a colon in it.
        assert_eq!(CopyEndpoint::parse("./notes:old.txt"), CopyEndpoint::Local("./notes:old.txt".into()));
        assert_eq!(CopyEndpoint::parse(":odd"), CopyEndpoint::Local(":odd".into()));
    }

    #[test]
    fn what_a_guest_says_is_shown_on_one_line() {
        assert_eq!(shown_line("  one\ntwo\u{202E}three  ", 500), "onetwothree");
        assert_eq!(shown_line("abcdef", 3), "abc");
    }
}
