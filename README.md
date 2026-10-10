# SwiftVM

A native macOS app for running virtual machines, written in Swift. Requires macOS 27 on Apple silicon.

## Status

Early development. Working today:

- **Linux guests** on Apple's Virtualization framework
  - Quick Create from a cloud image (Ubuntu 26.04, Ubuntu 24.04, Debian 13): no installer, ready in seconds
  - Install from an ISO
- **Networking**: an app-managed NAT network with a stable address per machine
- **SSH from the host**: every machine gets a host alias; `swiftvm ssh <machine>` or, after turning on
  *Add machines to ~/.ssh/config* in Settings, plain `ssh <alias>`
- **Shared folders** that can be added and removed while the guest runs
- **Suspend and resume** to disk, graceful shutdown, pause
- **`swiftvm`** command-line tool that drives the running app

Planned: macOS guests, Windows guests (QEMU engine), USB passthrough, snapshots, guest tools.
See `docs/spikes.md` for platform findings that shaped the design.

## Build

```sh
scripts/build.sh          # app + CLI, Debug
scripts/test.sh           # unit tests
open build/Build/Products/Debug/SwiftVM.app
```

No Apple Developer team is needed to build and run: the app is signed to run locally. To sign with your own
team, see the comment at the top of `Config/Base.xcconfig`.

## Command line

The app must be running.

```sh
swiftvm create ubuntu-26.04 --name "Web Server" --cpus 2 --memory 4 --disk 32
swiftvm list
swiftvm ssh web-server
swiftvm share web-server ~/Projects
swiftvm suspend web-server
swiftvm start web-server
swiftvm stop web-server
```

The tool is built at `Packages/SwiftVMKit/.build/out/Products/Debug/swiftvm`.

## Layout

| Path | What |
|---|---|
| `App/` | The SwiftUI app |
| `Packages/SwiftVMKit/` | Engine code as a Swift package: `VMCore`, `VZEngine`, `VMNetworking`, `SSHIntegration`, `DiskTools`, `Installers`, `VMControl`, and the `swiftvm` tool |
| `Config/` | Build settings, entitlements, Info.plist |
| `docs/` | Notes |
