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
- **Port forwarding**: reach a port in a guest as `localhost:<port>` on the Mac, and optionally from other
  devices on the network. Forwards can be added and removed while the guest runs
- **Shared folders** that can be added and removed while the guest runs
- **Disc and disk images** (ISO, raw, ASIF) plugged in as USB drives, also while the guest runs
- **Snapshots**: save a machine as it is, running or not, and go back to it later. A running guest pauses
  for a moment and comes back exactly where it was
- **Duplicate** a machine in an instant; the copy shares disk space with the original until they differ
- **Grow a disk** after the fact
- **Suspend and resume** to disk, graceful shutdown, pause
- **Serial console** for Linux guests, for when the network or the display isn't there. Quick Create
  machines also send their kernel's messages to it, and what it has printed since the machine last
  started up is in the machine's `logs/console.log`
- **`swiftvm`** command-line tool that drives the running app

Planned: Windows guests (QEMU engine), USB passthrough, guest tools.

Good to know:

- macOS guests ask on their own screen before they shut down, so *Shut Down* and `swiftvm stop` need someone
  to confirm in the machine's window. Suspend needs no confirmation.
- Snapshots and duplicates are instant because APFS shares the unchanged parts of the disk. On a volume
  with another file system they are full copies.
- A snapshot covers the machine's own disks. While a disk image that the guest can write to is attached,
  a running machine can't be snapshotted: eject the image or shut the machine down first.
- While the Mac is locked, a suspended machine can't be resumed: the system refuses to read its saved
  memory. SwiftVM says so when that happens, and won't suspend a running machine for a snapshot while the
  Mac is locked.
- Kernel messages reach the serial console from a Quick Create machine's second start on, and from the
  moment the console exists, a few hundredths of a second into the boot. Ubuntu turns ordinary kernel
  messages off on every console once it is up and only lets errors through; Debian keeps them all.
  Machines created before this was added, and those installed from an ISO, are as they were.
- A download that is cut short by quitting, by cancelling or by a failure carries on where it stopped the
  next time the same system is created. What has arrived waits in the system's temporary folder, where
  macOS removes files that haven't been used for three days; after that the download starts over.
- A grown disk is only bigger hardware. Linux guests set up by Quick Create grow into it at their next
  start; other Linux guests need `growpart` and `resize2fs` or the like. macOS can't grow its startup
  volume (its recovery system is in the way), but Disk Utility in the guest can add a volume in the new
  space, so pick a generous size when you create a Mac. Disks only take up what the guest has written.

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

The `swiftvm` tool is inside the app, at `SwiftVM.app/Contents/Helpers/swiftvm`. *Install Command Line Tool…*
in SwiftVM › Settings puts it on your `PATH`, as a link in `/usr/local/bin`. The app must be running.

```sh
swiftvm create ubuntu-26.04 --name "Web Server" --cpus 2 --memory 4 --disk 32
swiftvm create macos --name "Build Mac" --password 'a password for the account'
swiftvm list
swiftvm info web-server
swiftvm ssh web-server
swiftvm share web-server ~/Projects
swiftvm forward web-server 8080:80          # http://localhost:8080 is the guest's port 80
swiftvm attach web-server ~/Downloads/data.img
swiftvm snapshot web-server "Before upgrade"
swiftvm rename-snapshot web-server "Before upgrade" "Before 2.0"
swiftvm revert web-server "Before 2.0"
swiftvm suspend web-server
swiftvm start web-server                    # resumes; `swiftvm discard-state` starts it fresh instead
swiftvm console web-server                  # serial console; Control-] to leave
swiftvm stop web-server
swiftvm clone web-server --name "Web Server 2"
swiftvm resize web-server 64
swiftvm quit                                # only when nothing is running
```

`swiftvm help` lists every command. `scripts/build.sh` also builds the tool on its own at
`Packages/SwiftVMKit/.build/out/Products/Debug/swiftvm`.

`swiftvm create macos` downloads the latest macOS restore image (about 25 GB) unless it is already in
`~/Library/Caches/SwiftVM/Downloads` or you pass `--ipsw <file>`.

`swiftvm quit` never asks anything, so it refuses while a machine is running. While one is still being
created it refuses too, unless you add `--cancel-creations`.

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
| `App/` | The SwiftUI app, and its icon (`AppIcon.icon`, an Icon Composer document) |
| `Packages/SwiftVMKit/` | Engine code as a Swift package: `VMCore`, `VZEngine`, `VMNetworking`, `SSHIntegration`, `DiskTools`, `Installers`, `VMControl`, and the `swiftvm` tool |
| `Config/` | Build settings, entitlements, Info.plist |
| `docs/` | Notes |

## License

SwiftVM is licensed under the Apache License, Version 2.0. See `LICENSE`.
