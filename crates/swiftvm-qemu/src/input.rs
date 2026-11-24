//! The machine's own mouse and keyboard, and pictures of its display, as the host reads and drives them:
//! nothing in the guest is asked. The keyboard is a US one; keys are named the way a Mac names them
//! (`GuestChannel/MacKeys.swift`), and pressed where a PC has them (`QEMUEngine/PCKeys.swift`), by their
//! place: a key types whatever the guest's layout puts there.

use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::Duration;

use swiftvm_protocol::qemu::{Keys, Pointer, PointerAction, PointerButton};

/// How long the guest gets to take in what the mouse did before the next thing.
pub const MOUSE_PAUSE: Duration = Duration::from_millis(20);
/// How long the guest gets to take in a key, or a notch of the wheel, before the next: a USB keyboard
/// that gets keys faster than it reports them loses some.
pub const KEY_PAUSE: Duration = Duration::from_millis(12);

/// One thing done with the mouse or the keyboard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputStep {
    /// The pointer at a pixel with these buttons held, one bit each as `BUTTON_` has them.
    Pointer {
        x: i64,
        y: i64,
        buttons: u8,
    },
    /// A key, by its PC scancode, the second byte of those after 0xE0 with its high bit set.
    Key {
        code: u16,
        down: bool,
    },
    Pause(Duration),
}

pub const BUTTON_LEFT: u8 = 1;
pub const BUTTON_MIDDLE: u8 = 2;
pub const BUTTON_RIGHT: u8 = 4;
pub const WHEEL_UP: u8 = 8;
pub const WHEEL_DOWN: u8 = 16;
pub const WHEEL_LEFT: u8 = 32;
pub const WHEEL_RIGHT: u8 = 64;

/// QMP's name for each button bit.
pub const BUTTON_NAMES: [(u8, &str); 7] = [
    (BUTTON_LEFT, "left"),
    (BUTTON_MIDDLE, "middle"),
    (BUTTON_RIGHT, "right"),
    (WHEEL_UP, "wheel-up"),
    (WHEEL_DOWN, "wheel-down"),
    (WHEEL_LEFT, "wheel-left"),
    (WHEEL_RIGHT, "wheel-right"),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputError {
    /// It can't be done the way it was asked for.
    Invalid(String),
    /// No key of the keyboard types this character.
    NotOnTheKeyboard(char),
}

impl std::fmt::Display for InputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputError::Invalid(reason) => f.write_str(reason),
            InputError::NotOnTheKeyboard(character) => write!(
                f,
                "The machine's keyboard has the keys of a US keyboard, and none of them types “{character}”. Current guest tools type any text."
            ),
        }
    }
}

/// What the mouse does for `pointer`, on a display `width` by `height` pixels.
pub fn pointer_steps(pointer: &Pointer, width: i64, height: i64) -> Result<Vec<InputStep>, InputError> {
    let place = |x: i64, y: i64| {
        if (0..width).contains(&x) && (0..height).contains(&y) {
            Ok((x, y))
        } else {
            Err(InputError::Invalid(format!("({x}, {y}) isn't on the screen, which is {width} by {height}.")))
        }
    };
    let start = place(pointer.x, pointer.y)?;
    let button = match pointer.button.unwrap_or(PointerButton::Left) {
        PointerButton::Left => BUTTON_LEFT,
        PointerButton::Right => BUTTON_RIGHT,
        PointerButton::Middle => BUTTON_MIDDLE,
    };
    let mut steps = Vec::new();
    let mut go = |point: (i64, i64), buttons: u8| {
        steps.push(InputStep::Pointer { x: point.0, y: point.1, buttons });
        steps.push(InputStep::Pause(MOUSE_PAUSE));
    };
    // From a pixel aside, so that the guest sees the pointer arrive where it is put.
    let aside = (start.0 + if start.0 + 2 < width { 2 } else { -2 }, start.1);
    match pointer.action {
        PointerAction::Move => go(start, 0),
        PointerAction::Click => {
            let count = pointer.count.unwrap_or(1);
            if !(1..=3).contains(&count) {
                return Err(InputError::Invalid("A click is one, two or three clicks.".into()));
            }
            go(aside, 0);
            go(start, 0);
            for _ in 0..count {
                go(start, button);
                go(start, 0);
            }
        }
        PointerAction::Drag => {
            let (Some(to_x), Some(to_y)) = (pointer.to_x, pointer.to_y) else {
                return Err(InputError::Invalid("The request doesn't say where the drag ends.".into()));
            };
            let end = place(to_x, to_y)?;
            go(aside, 0);
            go(start, 0);
            go(start, button);
            let parts = 12;
            for part in 1..=parts {
                let part = part as f64 / parts as f64;
                go((start.0 + ((end.0 - start.0) as f64 * part) as i64, start.1 + ((end.1 - start.1) as f64 * part) as i64), button);
            }
            go(end, 0);
        }
        PointerAction::Scroll => {
            let (delta_x, delta_y) = (pointer.delta_x.unwrap_or(0), pointer.delta_y.unwrap_or(0));
            if delta_x.abs() > 100 || delta_y.abs() > 100 {
                return Err(InputError::Invalid("That is further than the wheel is turned in one go.".into()));
            }
            go(start, 0);
            // Positive is down and to the right. Windows turns its wheel as it is turned.
            for notch in 0..delta_x.abs().max(delta_y.abs()) {
                let mut wheel = 0;
                if notch < delta_y.abs() {
                    wheel |= if delta_y > 0 { WHEEL_DOWN } else { WHEEL_UP };
                }
                if notch < delta_x.abs() {
                    wheel |= if delta_x > 0 { WHEEL_RIGHT } else { WHEEL_LEFT };
                }
                steps.push(InputStep::Pointer { x: start.0, y: start.1, buttons: wheel });
                steps.push(InputStep::Pointer { x: start.0, y: start.1, buttons: 0 });
                steps.push(InputStep::Pause(KEY_PAUSE));
            }
        }
    }
    Ok(steps)
}

/// What the keyboard does for `keys`. Everything is looked up before anything is typed: half of it is
/// worse than none.
pub fn key_steps(keys: &Keys) -> Result<Vec<InputStep>, InputError> {
    let mut presses = Vec::new();
    let text = keys.text.as_deref().unwrap_or_default();
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        // A line break written the Windows way is one.
        if character == '\r' && characters.peek() == Some(&'\n') {
            characters.next();
            presses.push(Press { key: Some(RETURN_KEY), modifiers: Vec::new() });
            continue;
        }
        presses.push(press_typing(character).ok_or(InputError::NotOnTheKeyboard(character))?);
    }
    for name in keys.keys.iter().flatten() {
        presses.push(press_for(name)?);
    }
    if presses.is_empty() {
        return Err(InputError::Invalid("The request has neither text to type nor keys to press.".into()));
    }
    let no_such_key = || InputError::Invalid("The machine's keyboard has no such key.".into());
    let mut steps = Vec::new();
    for press in presses {
        let held: Vec<u16> =
            press.modifiers.iter().map(|modifier| pc_scancode(*modifier).ok_or_else(no_such_key)).collect::<Result<_, _>>()?;
        let key = press.key.map(|key| pc_scancode(key).ok_or_else(no_such_key)).transpose()?;
        for code in &held {
            steps.push(InputStep::Key { code: *code, down: true });
            steps.push(InputStep::Pause(KEY_PAUSE));
        }
        if let Some(code) = key {
            steps.push(InputStep::Key { code, down: true });
            steps.push(InputStep::Pause(KEY_PAUSE));
            steps.push(InputStep::Key { code, down: false });
            steps.push(InputStep::Pause(KEY_PAUSE));
        }
        for code in held.iter().rev() {
            steps.push(InputStep::Key { code: *code, down: false });
            steps.push(InputStep::Pause(KEY_PAUSE));
        }
    }
    Ok(steps)
}

// MARK: - A Mac's keys

/// One press: a key, by a Mac's key code, and the keys held down for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Press {
    pub key: Option<u16>,
    pub modifiers: Vec<u16>,
}

const COMMAND: u16 = 55;
const SHIFT: u16 = 56;
const OPTION: u16 = 58;
const CONTROL: u16 = 59;
const RETURN_KEY: u16 = 36;
const TAB_KEY: u16 = 48;
const SPACE_KEY: u16 = 49;

fn modifier(name: &str) -> Option<u16> {
    Some(match name {
        "cmd" | "command" | "super" | "meta" | "win" => COMMAND,
        "shift" => SHIFT,
        "alt" | "option" => OPTION,
        "ctrl" | "control" => CONTROL,
        _ => return None,
    })
}

fn named(name: &str) -> Option<u16> {
    Some(match name {
        "return" | "enter" => 36,
        "escape" | "esc" => 53,
        "tab" => 48,
        "space" => 49,
        "backspace" => 51,
        "delete" | "del" => 117,
        "home" => 115,
        "end" => 119,
        "pageup" => 116,
        "pagedown" => 121,
        "up" => 126,
        "down" => 125,
        "left" => 123,
        "right" => 124,
        "capslock" => 57,
        "f1" => 122,
        "f2" => 120,
        "f3" => 99,
        "f4" => 118,
        "f5" => 96,
        "f6" => 97,
        "f7" => 98,
        "f8" => 100,
        "f9" => 101,
        "f10" => 109,
        "f11" => 103,
        "f12" => 111,
        _ => return None,
    })
}

/// Which key of a US keyboard has each character on it, and whether Shift is held for it.
fn characters() -> &'static HashMap<char, (u16, bool)> {
    static TABLE: OnceLock<HashMap<char, (u16, bool)>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let rows: [(&str, std::ops::Range<u16>); 4] =
            [("asdfhgzxcv", 0..10), ("bqweryt", 11..18), ("123465=97-80]ou[ip", 18..36), ("lj'k;\\,/nm.", 37..48)];
        let shifted: HashMap<char, char> = [
            ('1', '!'),
            ('2', '@'),
            ('3', '#'),
            ('4', '$'),
            ('5', '%'),
            ('6', '^'),
            ('7', '&'),
            ('8', '*'),
            ('9', '('),
            ('0', ')'),
            ('-', '_'),
            ('=', '+'),
            ('[', '{'),
            (']', '}'),
            ('\\', '|'),
            (';', ':'),
            ('\'', '"'),
            (',', '<'),
            ('.', '>'),
            ('/', '?'),
            ('`', '~'),
        ]
        .into_iter()
        .collect();
        let mut table = HashMap::new();
        for (row, codes) in rows.into_iter().chain([("`", 50..51)]) {
            for (character, code) in row.chars().zip(codes) {
                table.insert(character, (code, false));
                if let Some(other) = shifted.get(&character) {
                    table.insert(*other, (code, true));
                }
            }
        }
        table
    })
}

/// Reads a press as it is written: `Return`, `cmd+space`, `ctrl+shift+t`.
pub fn press_for(text: &str) -> Result<Press, InputError> {
    let mut names: Vec<String> = text.split('+').map(str::to_string).collect();
    // The plus sign is a key too: alone, or as the last of several.
    if text == "+" {
        names = vec!["+".into()];
    } else if names.len() > 2 && names[names.len() - 2..] == ["", ""] {
        names.truncate(names.len() - 2);
        names.push("+".into());
    }
    let mut press = Press { key: None, modifiers: Vec::new() };
    let count = names.len();
    for (position, name) in names.iter().enumerate() {
        let lowered = name.to_lowercase();
        let shown: String = name.chars().take(32).collect();
        if let Some(modifier) = modifier(&lowered) {
            if !press.modifiers.contains(&modifier) {
                press.modifiers.push(modifier);
            }
        } else if position < count - 1 {
            return Err(InputError::Invalid(format!("“{shown}” isn't a key to hold down. Those are cmd, shift, option and ctrl.")));
        } else if let Some(key) = named(&lowered) {
            press.key = Some(key);
        } else if let (Some(character), 1) = (lowered.chars().next(), lowered.chars().count())
            && let Some((key, _)) = characters().get(&character).or_else(|| name.chars().next().and_then(|first| characters().get(&first)))
        {
            // A letter in a shortcut is the key, whichever way it is written.
            press.key = Some(*key);
            let written = name.chars().next().and_then(|first| characters().get(&first));
            if written.is_some_and(|(_, shifted)| *shifted) && !press.modifiers.contains(&SHIFT) {
                press.modifiers.push(SHIFT);
            }
        } else {
            return Err(InputError::Invalid(format!("There is no key called “{shown}”.")));
        }
    }
    Ok(press)
}

/// The press that types `character` on a US keyboard. `None` for a character no key has.
pub fn press_typing(character: char) -> Option<Press> {
    match character {
        '\n' => return Some(Press { key: Some(RETURN_KEY), modifiers: Vec::new() }),
        '\t' => return Some(Press { key: Some(TAB_KEY), modifiers: Vec::new() }),
        ' ' => return Some(Press { key: Some(SPACE_KEY), modifiers: Vec::new() }),
        _ => {}
    }
    if let Some((key, shifted)) = characters().get(&character) {
        return Some(Press { key: Some(*key), modifiers: if *shifted { vec![SHIFT] } else { Vec::new() } });
    }
    // A capital letter is its key with Shift.
    let mut lowered = character.to_lowercase();
    let lower = lowered.next()?;
    if !character.is_alphabetic() || lowered.next().is_some() || lower == character {
        return None;
    }
    characters().get(&lower).map(|(key, _)| Press { key: Some(*key), modifiers: vec![SHIFT] })
}

// MARK: - Where a PC has them

/// The PC scancode of the Mac key with this key code. Command is the Windows key, Option is Alt.
#[rustfmt::skip]
pub fn pc_scancode(mac_key: u16) -> Option<u16> {
    Some(match mac_key {
        // Letters
        0x00 => 0x1E, 0x0B => 0x30, 0x08 => 0x2E, 0x02 => 0x20, 0x0E => 0x12, 0x03 => 0x21, 0x05 => 0x22, 0x04 => 0x23,
        0x22 => 0x17, 0x26 => 0x24, 0x28 => 0x25, 0x25 => 0x26, 0x2E => 0x32, 0x2D => 0x31, 0x1F => 0x18, 0x23 => 0x19,
        0x0C => 0x10, 0x0F => 0x13, 0x01 => 0x1F, 0x11 => 0x14, 0x20 => 0x16, 0x09 => 0x2F, 0x0D => 0x11, 0x07 => 0x2D,
        0x10 => 0x15, 0x06 => 0x2C,
        // Digits
        0x12 => 0x02, 0x13 => 0x03, 0x14 => 0x04, 0x15 => 0x05, 0x17 => 0x06, 0x16 => 0x07, 0x1A => 0x08, 0x1C => 0x09,
        0x19 => 0x0A, 0x1D => 0x0B,
        // Punctuation
        0x1B => 0x0C, 0x18 => 0x0D, 0x21 => 0x1A, 0x1E => 0x1B, 0x2A => 0x2B, 0x29 => 0x27, 0x27 => 0x28, 0x32 => 0x29,
        0x2B => 0x33, 0x2F => 0x34, 0x2C => 0x35,
        // The key next to Shift on an ISO keyboard, and the two a Japanese one adds.
        0x0A => 0x56, 0x5D => 0x7D, 0x5E => 0x73,
        // Whitespace and editing
        0x24 => 0x1C, 0x30 => 0x0F, 0x31 => 0x39, 0x33 => 0x0E, 0x35 => 0x01, 0x75 => 0xD3, 0x72 => 0xD2,
        0x73 => 0xC7, 0x77 => 0xCF, 0x74 => 0xC9, 0x79 => 0xD1,
        // Arrows
        0x7B => 0xCB, 0x7C => 0xCD, 0x7D => 0xD0, 0x7E => 0xC8,
        // Modifiers
        0x38 => 0x2A, 0x3C => 0x36, 0x3B => 0x1D, 0x3E => 0x9D, 0x3A => 0x38, 0x3D => 0xB8, 0x37 => 0xDB, 0x36 => 0xDC,
        0x39 => 0x3A,
        // Function keys
        0x7A => 0x3B, 0x78 => 0x3C, 0x63 => 0x3D, 0x76 => 0x3E, 0x60 => 0x3F, 0x61 => 0x40, 0x62 => 0x41, 0x64 => 0x42,
        0x65 => 0x43, 0x6D => 0x44, 0x67 => 0x57, 0x6F => 0x58,
        // F13 to F15 are where a PC has Print Screen, Scroll Lock and Pause.
        0x69 => 0xB7, 0x6B => 0x46, 0x71 => 0xC6,
        // Keypad
        0x52 => 0x52, 0x53 => 0x4F, 0x54 => 0x50, 0x55 => 0x51, 0x56 => 0x4B, 0x57 => 0x4C, 0x58 => 0x4D, 0x59 => 0x47,
        0x5B => 0x48, 0x5C => 0x49, 0x41 => 0x53, 0x43 => 0x37, 0x45 => 0x4E, 0x4E => 0x4A, 0x4B => 0xB5, 0x4C => 0x9C,
        0x51 => 0x59, 0x47 => 0x45,
        _ => return None,
    })
}

// MARK: - Pictures

/// The picture in a PPM file (`P6`, eight bits a channel), as `width`, `height` and four bytes a pixel:
/// blue, green, red, and one that says nothing.
pub fn ppm_to_bgrx(data: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut fields = Vec::new();
    let mut index = 0;
    while fields.len() < 4 {
        while index < data.len() && data[index].is_ascii_whitespace() {
            index += 1;
        }
        if data.get(index) == Some(&b'#') {
            while index < data.len() && data[index] != b'\n' {
                index += 1;
            }
            continue;
        }
        let start = index;
        while index < data.len() && !data[index].is_ascii_whitespace() {
            index += 1;
        }
        if start == index {
            return None;
        }
        fields.push(std::str::from_utf8(&data[start..index]).ok()?.to_string());
    }
    // One byte of white space ends the header.
    index += 1;
    if fields[0] != "P6" || fields[3] != "255" {
        return None;
    }
    let width: u32 = fields[1].parse().ok()?;
    let height: u32 = fields[2].parse().ok()?;
    let pixels = data.get(index..index + width as usize * height as usize * 3)?;
    let mut bgrx = Vec::with_capacity(width as usize * height as usize * 4);
    for rgb in pixels.as_chunks::<3>().0 {
        bgrx.extend_from_slice(&[rgb[2], rgb[1], rgb[0], 255]);
    }
    Some((width, height, bgrx))
}
