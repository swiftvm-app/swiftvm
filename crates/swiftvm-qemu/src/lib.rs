//! The QEMU engine of `swiftvm serve`: it starts a machine's QEMU (and its TPM), drives it over QMP, opens
//! connections to the guest's agent over its serial line, and finds a QEMU again after the service restarts.
//!
//! A port of the app's `Packages/SwiftVMKit/Sources/QEMUEngine`, without the display, which the app shows.

pub mod agent_channel;
pub mod battery;
pub mod command_line;
pub mod config;
pub mod fdpass;
pub mod input;
pub mod installation;
pub mod machine;
pub mod process;
pub mod qmp;
pub mod runtime;
pub mod saved_state;
pub mod tpm;

pub use machine::{Machine, StartOptions};

use agent_channel::ChannelError;
use input::InputError;
use swiftvm_protocol::wire::ErrorCode;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QemuError {
    /// This copy of SwiftVM was built without QEMU.
    NotInstalled,
    /// QEMU couldn't be started, or stopped before it was up.
    DidNotStart(String),
    /// QEMU said no to something it was asked, in its own words.
    Refused(String),
    /// The line to QEMU is gone: it has stopped.
    Disconnected,
    /// The machine, by its name, isn't running.
    NotRunning(String),
    /// What was asked doesn't make sense for the machine, in words for whoever asked.
    Invalid(String),
    /// The display shows nothing: the guest has turned it off, or hasn't drawn on it yet.
    NothingShown,
    /// The service can't do it for this machine.
    Unavailable(String),
    Channel(ChannelError),
    Input(InputError),
}

impl std::fmt::Display for QemuError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            QemuError::NotInstalled => f.write_str(
                "This copy of SwiftVM was built without QEMU, which runs Windows guests and Linux guests with graphics acceleration.",
            ),
            QemuError::DidNotStart(reason) => write!(f, "QEMU couldn't start the virtual machine. {reason}"),
            QemuError::Refused(reason) => write!(f, "QEMU refused: {reason}"),
            QemuError::Disconnected => f.write_str("QEMU has stopped."),
            QemuError::NotRunning(name) => write!(f, "“{name}” isn't running."),
            QemuError::Invalid(reason) | QemuError::Unavailable(reason) => f.write_str(reason),
            QemuError::NothingShown => f.write_str("The virtual machine's display is off, or shows nothing yet."),
            QemuError::Channel(error) => error.fmt(f),
            QemuError::Input(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for QemuError {}

impl QemuError {
    /// The code API v1 gives it.
    pub fn code(&self) -> ErrorCode {
        match self {
            QemuError::NotInstalled | QemuError::Unavailable(_) | QemuError::NothingShown => ErrorCode::Unavailable,
            QemuError::DidNotStart(_) | QemuError::Refused(_) => ErrorCode::Failed,
            QemuError::Disconnected | QemuError::NotRunning(_) => ErrorCode::WrongState,
            QemuError::Invalid(_) | QemuError::Input(_) => ErrorCode::BadRequest,
            QemuError::Channel(ChannelError::Closed) => ErrorCode::WrongState,
            QemuError::Channel(ChannelError::TimedOut) => ErrorCode::TimedOut,
            QemuError::Channel(_) => ErrorCode::GuestTools,
        }
    }
}

impl From<ChannelError> for QemuError {
    fn from(error: ChannelError) -> Self {
        QemuError::Channel(error)
    }
}

impl From<InputError> for QemuError {
    fn from(error: InputError) -> Self {
        QemuError::Input(error)
    }
}
