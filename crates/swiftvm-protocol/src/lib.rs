//! What a client of SwiftVM needs to drive it: the messages of API v1, which `swiftvm serve` speaks, the
//! frames a guest job travels in, and a client that sends them.
//!
//! The app's control socket carries the same messages in Swift's coding; `api` turns them into API v1.
//! The Swift side is `VMControl` and `GuestChannel` in `Packages/SwiftVMKit`. The two are kept in step
//! by the shared fixtures in `tests/fixtures`, which both test suites read.

pub mod api;
pub mod client;
pub mod frames;
pub mod io;
pub mod paths;
pub mod qemu;
pub mod text;
pub mod wire;

pub use client::{ClientError, ServiceClient};
pub use frames::{FrameError, JobFrame, JobFrameKind};
pub use paths::{AppIdentity, ControlPaths};
pub use wire::*;
