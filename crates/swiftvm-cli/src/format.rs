//! How numbers, sizes, dates and tables are shown. Always in English: what this tool prints reads the
//! same on every computer and in every script.

use unicode_segmentation::UnicodeSegmentation;

use crate::util::say;

/// A size the way macOS shows one in binary units: `Zero KB`, `512 bytes`, `2 KB`, `1.5 MB`, `1.15 GB`.
/// Kilobytes are whole, megabytes have one decimal, and larger units two, without trailing zeros.
pub fn bytes(value: u64) -> String {
    match value {
        0 => return "Zero KB".into(),
        1 => return "1 byte".into(),
        2..=1023 => return format!("{} bytes", grouped(value)),
        _ => {}
    }
    const UNITS: [(&str, usize); 6] = [("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2), ("PB", 2), ("EB", 2)];
    let mut amount = value as f64 / 1024.0;
    let mut unit = 0;
    // A unit is used for what doesn't round up to a whole one of the next.
    while unit + 1 < UNITS.len() && round(amount, UNITS[unit].1) >= 1024.0 {
        amount /= 1024.0;
        unit += 1;
    }
    let (name, decimals) = UNITS[unit];
    format!("{} {name}", decimal(round(amount, decimals), decimals))
}

fn round(value: f64, decimals: usize) -> f64 {
    let scale = 10f64.powi(decimals as i32);
    (value * scale).round() / scale
}

/// `value` with at most `decimals` decimals, without trailing zeros, and its thousands grouped.
fn decimal(value: f64, decimals: usize) -> String {
    let text = format!("{value:.decimals$}");
    let (whole, fraction) = text.split_once('.').unwrap_or((&text, ""));
    let fraction = fraction.trim_end_matches('0');
    let whole = grouped(whole.parse().unwrap_or(0));
    if fraction.is_empty() { whole } else { format!("{whole}.{fraction}") }
}

/// `1,234,567`.
pub fn grouped(value: u64) -> String {
    let digits = value.to_string();
    let mut text = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            text.push(',');
        }
        text.push(digit);
    }
    text
}

/// A number of seconds as a person writes it: `90`, `1.5`, `1,000`.
pub fn number(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        let whole = grouped(value.abs() as u64);
        return if value < 0.0 { format!("-{whole}") } else { whole };
    }
    format!("{value}")
}

/// The parts of a moment on this computer's clock.
pub struct LocalTime {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub millisecond: u32,
}

impl LocalTime {
    pub fn at_unix_seconds(seconds: f64) -> Self {
        let whole = seconds.floor();
        let time = whole as libc::time_t;
        // SAFETY: an all-zero tm is a valid value for localtime_r to fill in.
        let mut parts: libc::tm = unsafe { std::mem::zeroed() };
        // SAFETY: both pointers are to valid values of their types.
        unsafe { libc::localtime_r(&time, &mut parts) };
        LocalTime {
            year: parts.tm_year + 1900,
            month: (parts.tm_mon + 1) as u32,
            day: parts.tm_mday as u32,
            hour: parts.tm_hour as u32,
            minute: parts.tm_min as u32,
            second: parts.tm_sec as u32,
            millisecond: ((seconds - whole) * 1000.0) as u32,
        }
    }

    pub fn now() -> Self {
        let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        Self::at_unix_seconds(since.as_secs_f64())
    }

    /// `2026-11-23 14:05:09`.
    pub fn readable(&self) -> String {
        format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}", self.year, self.month, self.day, self.hour, self.minute, self.second)
    }

    /// `20261123-140509-123`, for a file name.
    pub fn stamp(&self) -> String {
        format!(
            "{:04}{:02}{:02}-{:02}{:02}{:02}-{:03}",
            self.year, self.month, self.day, self.hour, self.minute, self.second, self.millisecond
        )
    }
}

/// Prints `rows` as columns two spaces apart, each as wide as its widest cell.
pub fn print_rows(rows: &[Vec<String>]) {
    let Some(first) = rows.first() else { return };
    let widths: Vec<usize> = (0..first.len()).map(|column| rows.iter().map(|row| characters(&row[column])).max().unwrap_or(0)).collect();
    for row in rows {
        let line: Vec<String> = row.iter().zip(&widths).map(|(cell, width)| pad(cell, *width)).collect();
        say(line.join("  ").trim());
    }
}

/// How many characters a reader counts in `text`: `é` is one, however it is written.
pub fn characters(text: &str) -> usize {
    text.graphemes(true).count()
}

/// The first `count` characters of `text`, as a reader counts them.
pub fn prefix(text: &str, count: usize) -> String {
    text.graphemes(true).take(count).collect()
}

/// `text` with spaces after it up to `width` characters.
pub fn pad(text: &str, width: usize) -> String {
    let count = characters(text);
    if count >= width { text.to_string() } else { format!("{text}{}", " ".repeat(width - count)) }
}
