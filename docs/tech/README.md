# Technical guide

How SwiftVM is organized, built, and released.

SwiftVM manages machines from a menu bar app. The `swiftvm` command uses the
same app and machine library. macOS and Linux guests run with Apple's
Virtualization framework; Windows guests, and Linux guests with graphics
acceleration, run with the bundled QEMU engine.

Each machine is a `.swiftvm` package containing its configuration, disks,
firmware, and snapshots. Guest tools connect directly to the app for power,
clock synchronization, and automation.

- [Architecture](architecture.md): components, storage, and communication.
- [Requirements and limitations](constraints.md): supported systems and feature
  restrictions.
- [Building](building.md): build and run a development copy.
- [Releasing](releasing.md): release channels, signing, and updates.
