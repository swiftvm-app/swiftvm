//! What a restore needs besides what QEMU saved of a machine: the USB port each drive was in, which QEMU
//! tells USB devices apart by, and whether it had a TPM.
//!
//! A snapshot copies the saved state's one file, so this is at its start, and QEMU's part comes after it,
//! from `SIZE` on: a line that says what the file is, this as JSON, and zeros. The app wrote the same
//! (`SavedStateHeader.swift`), so states it saved resume here.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};
use swiftvm_protocol::wire::Id;

use crate::QemuError;

/// Where QEMU's part of the file starts.
pub const SIZE: u64 = 4096;
const SIGNATURE: &[u8] = b"SwiftVM QEMU machine state 1\n";

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SavedStateHeader {
    /// The USB port of each drive and disk on USB, by its identifier.
    pub usb_ports: HashMap<Id, u32>,
    /// The machine had a TPM. It resumes with one, whatever its settings say by then.
    pub has_tpm: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contents {
    usb_ports: HashMap<String, u32>,
    /// Missing from what was saved before machines had a TPM.
    #[serde(rename = "hasTPM", default, skip_serializing_if = "Option::is_none")]
    has_tpm: Option<bool>,
}

impl SavedStateHeader {
    /// Writes this over the start of a saved state that QEMU has written the rest of.
    pub fn write_into(&self, path: &Path) -> Result<(), QemuError> {
        let contents =
            Contents { usb_ports: self.usb_ports.iter().map(|(id, port)| (id.to_string(), *port)).collect(), has_tpm: Some(self.has_tpm) };
        let mut data = SIGNATURE.to_vec();
        data.extend(serde_json::to_vec(&contents).unwrap_or_default());
        if data.len() as u64 >= SIZE {
            return Err(QemuError::Refused("The machine has too many drives to save its state.".into()));
        }
        let failed = |error: std::io::Error| QemuError::Refused(format!("The saved state couldn't be written: {error}"));
        let mut file = std::fs::OpenOptions::new().write(true).open(path).map_err(failed)?;
        file.seek(SeekFrom::Start(0)).map_err(failed)?;
        file.write_all(&data).map_err(failed)
    }

    pub fn read(path: &Path) -> Result<SavedStateHeader, QemuError> {
        let unusable = || QemuError::DidNotStart("Its saved state isn't one that SwiftVM can resume.".into());
        let mut data = Vec::new();
        std::fs::File::open(path).map_err(|_| unusable())?.take(SIZE).read_to_end(&mut data).map_err(|_| unusable())?;
        let rest = data.strip_prefix(SIGNATURE).ok_or_else(unusable)?;
        let json = &rest[..rest.iter().position(|byte| *byte == 0).unwrap_or(rest.len())];
        let contents: Contents = serde_json::from_slice(json).map_err(|_| unusable())?;
        let usb_ports =
            contents.usb_ports.into_iter().filter_map(|(key, port)| uuid::Uuid::parse_str(&key).ok().map(|id| (Id(id), port))).collect();
        Ok(SavedStateHeader { usb_ports, has_tpm: contents.has_tpm.unwrap_or(false) })
    }
}
