//! What a client of SwiftVM needs to drive it: the messages of the app's control socket, the frames a
//! guest job travels in, and a client that sends them.
//!
//! The Swift side of this protocol is `VMControl` and `GuestChannel` in `Packages/SwiftVMKit`. The two
//! are kept in step by the shared fixtures in `tests/fixtures`, which both test suites read.

pub mod client;
pub mod frames;
pub mod io;
pub mod paths;
pub mod text;
pub mod wire;

pub use client::{ClientError, ControlClient};
pub use frames::{FrameError, JobFrame, JobFrameKind};
pub use paths::{AppIdentity, ControlPaths};
pub use wire::*;
