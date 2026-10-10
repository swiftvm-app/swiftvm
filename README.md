# SwiftVM

A native macOS app for running virtual machines, written in Swift. Requires macOS 27 on Apple silicon.

## Status

Early development. Working today:

- **macOS guests** on Apple's Virtualization framework
  - Installs the latest macOS from Apple, or a restore image (IPSW) you already have
  - macOS 27 and later set themselves up: the account is created on first start, your SSH key is installed
    and the time zone follows the host, with no setup assistant to click through
- **Linux guests** on Apple's Virtualization framework
  - Quick Create from a cloud image (Ubuntu 26.04, Ubuntu 24.04, Debian 13): no installer, ready in seconds
  - Install from an ISO
- **Networking**: an app-managed NAT network with a stable address per machine
- **SSH from the host**: every machine gets a host alias; `swiftvm ssh <machine>` or, after turning on
  *Add machines to ~/.ssh/config* in Settings, plain `ssh <alias>`
- **Shared folders** that can be added and removed while the guest runs
- **Suspend and resume** to disk, graceful shutdown, pause
- **`swiftvm`** command-line tool that drives the running app

Planned: Windows guests (QEMU engine), USB passthrough, snapshots, guest tools.

Good to know: macOS guests ask on their own screen before they shut down, so *Shut Down* and `swiftvm stop`
need someone to confirm in the machine's window. Suspend needs no confirmation.
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
swiftvm create macos --name "Build Mac" --password 'a password for the account'
swiftvm list
swiftvm ssh web-server
swiftvm share web-server ~/Projects
swiftvm suspend web-server
swiftvm start web-server
swiftvm stop web-server
```

The tool is built at `Packages/SwiftVMKit/.build/out/Products/Debug/swiftvm`.

`swiftvm create macos` downloads the latest macOS restore image (about 25 GB) unless it is already in
`~/Library/Caches/SwiftVM/Downloads` or you pass `--ipsw <file>`.

## Development

Set `SWIFTVM_HOME` to run a second copy of the app with its own machines, network settings and control socket,
next to the one you use. The path has to be short enough for a Unix socket (about 90 characters).

```sh
export SWIFTVM_HOME="$HOME/Library/Application Support/SwiftVM-Dev"
open -n --env "SWIFTVM_HOME=$SWIFTVM_HOME" build/Build/Products/Debug/SwiftVM.app
swiftvm list          # talks to that copy while SWIFTVM_HOME is set
swiftvm quit
```

## Layout

| Path | What |
|---|---|
| `App/` | The SwiftUI app |
| `Packages/SwiftVMKit/` | Engine code as a Swift package: `VMCore`, `VZEngine`, `VMNetworking`, `SSHIntegration`, `DiskTools`, `Installers`, `VMControl`, and the `swiftvm` tool |
| `Config/` | Build settings, entitlements, Info.plist |
| `docs/` | Notes |
