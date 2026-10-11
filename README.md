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
- **SSH without a network**: `swiftvm ssh <machine> --vsock` reaches a Linux guest over the machine's own
  socket device, so it still works when the guest's network is down or its cable is pulled
- **Guest tools**: a small agent in the guest tells the app which system it runs and which addresses it
  holds, sets its clock the moment it is resumed and shuts it down without delay. In Linux guests it
  also mounts the shared folders; in macOS guests it shares the clipboard and shuts the Mac down without
  the question macOS otherwise puts on its screen. Machines that SwiftVM sets up come with it; any other
  guest gets it with *Install Guest Tools…* or `swiftvm install-tools`
- **Shared clipboard**: text copied on your Mac can be pasted in a macOS guest with the guest tools and
  the other way round, and in Linux guests that run `spice-vdagent`. It can be turned off per machine
- **Port forwarding**: reach a port in a guest as `localhost:<port>` on the Mac, and optionally from other
  devices on the network. Forwards can be added and removed while the guest runs
- **Shared folders** that can be added and removed while the guest runs
- **Disc and disk images** (ISO, raw, ASIF) plugged in as USB drives, also while the guest runs
- **USB devices** of your Mac handed to a running guest: a drive, a security key, a serial adapter. A
  machine can be set to take a device by itself whenever it is plugged in. This needs a build with a
  provisioning profile (see *Build*)
- **Snapshots**: save a machine as it is, running or not, and go back to it later. A running guest pauses
  for a moment and comes back exactly where it was
- **Duplicate** a machine in an instant; the copy shares disk space with the original until they differ
- **Grow a disk** after the fact
- **Suspend and resume** to disk, graceful shutdown, pause
- **Serial console** for Linux guests, for when the network or the display isn't there. Quick Create
  machines also send their kernel's messages to it, and what it has printed since the machine last
  started up is in the machine's `logs/console.log`
- **`swiftvm`** command-line tool that drives the running app

Planned: Windows guests (QEMU engine).

Good to know:

- Which app a USB device is used with is decided in macOS, not in SwiftVM: while SwiftVM runs, the menu
  bar has a *Virtual Machine Accessories* menu that lists the Mac's USB devices, each used with *This Mac*
  or with an app. A device you set to SwiftVM there shows up under the USB button in a machine's toolbar
  and in `swiftvm usb`, and macOS remembers the choice.
- A device that is attached to a guest is gone from the Mac until it is detached or pulled out, or the
  machine stops. Detaching is like pulling it out of the guest: eject a drive in the guest first. A
  device belongs to one guest at a time.
- Suspending a machine gives its USB devices back to the Mac: the guest finds them unplugged when it
  comes back, and a machine that takes a device by itself takes it again then. Eject a drive in the
  guest before you suspend, as you would before pulling it out. A running machine with a USB device
  can't be snapshotted: detach the device or shut the machine down first.
- A device a machine takes by itself is known by its make (vendor and product), so two sticks of the
  same model are one to it. One that you detach by hand is left alone until it is plugged in again or
  the machine starts again. When two running machines would take the same device, it goes to the one
  that had it last. A copy of a machine takes none by itself until you say so.

- A macOS guest without the guest tools asks on its own screen before it shuts down, so *Shut Down* and
  `swiftvm stop` need someone to confirm in the machine's window. With the guest tools it shuts down at
  once, the way `sudo shutdown -h now` does: the apps in it aren't asked about documents that haven't
  been saved. So does every running machine that has them when you choose *Shut Down and Quit*; the
  others are stopped outright there. Suspend never needs a confirmation.
- The guest tools for Linux are one Python script and its systemd units, so they need a guest with
  systemd and Python 3. Ubuntu and Debian bring both along; other distributions haven't been tried. They
  are installed over SSH where the Mac can sign in and use `sudo` without a password, as in Quick Create
  machines. For other guests *Install Guest Tools…* plugs in a disc and shows the one command to run in
  the guest. In the guest, `sudo sh /usr/local/lib/swiftvm/install.sh --remove` takes them out again.
  Machines created before the guest tools existed don't have them until you install them.
- The guest tools for macOS are one program, `swiftvm-agent`, built from this project, and two launchd
  jobs: one runs it as root, to answer the app over the machine's socket device, and one runs it in the
  session of whoever is logged in, for the clipboard. A Mac that SwiftVM sets up with your SSH key gets
  them at the end of its first start. Installing takes the account's password, so for any other Mac
  it is `swiftvm install-tools <machine> --password <password>`, or *Install Guest Tools…*, which plugs
  in a disc for you to run `sudo sh /Volumes/SWIFTVM/install.sh` from in the guest's Terminal. macOS
  then says that a background item was added: that is the agent. Removing them is the same command as
  in Linux guests. They need macOS 27 or later in the guest.
- The clipboard is shared as text, up to about 250 kB of it; pictures and files stay where they were
  copied. In a macOS guest it follows whoever is logged in at its screen, and whoever logs in there
  finds what is on your Mac's clipboard at that moment. *Share Clipboard* in a machine's settings, or
  `swiftvm share-clipboard <machine> off`, turns it off, for a guest that shouldn't see what you copy on
  your Mac. A macOS guest that is given the guest tools is put on your Mac's time zone, once: if you
  pick another one in the guest afterwards, it stays.
- SSH over the socket device needs an SSH server that listens there. systemd arranges that by itself from
  version 256 on (Ubuntu 26.04, Debian 13); for older systems such as Ubuntu 24.04 the guest tools add it.
- A Debian 13 machine that an earlier version of SwiftVM made with Quick Create can't be resumed once it
  has been suspended, and doesn't see drives that are plugged in: it came from Debian's `genericcloud`
  image, whose kernel has no drivers for the display and for USB storage. Installing Debian's standard
  kernel in the guest (`sudo apt install linux-image-arm64`, then remove `linux-image-cloud-arm64` and
  restart) cures both. New machines come from the `generic` image, which has that kernel.
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
scripts/build.sh          # the app, optimized, at build/SwiftVM.app
scripts/test.sh           # unit tests
open build/SwiftVM.app
```

There is no Xcode project: the app is a Swift package, `swift build` compiles it, and `scripts/bundle-app.sh`
makes an app of the result, with its icon, the `swiftvm` tool and the guest agent for macOS guests inside,
and signs it. Xcode opens `Package.swift`.

No Apple Developer team is needed to build and run. With a signing certificate in your keychain the app is
signed with it, Developer ID Application before Apple Development; without one it is signed to run on your
Mac, which is enough to run virtual machines. `SWIFTVM_SIGN_IDENTITY` picks a certificate by name or SHA-1,
and `SWIFTVM_SIGN_IDENTITY=-` signs to run on your Mac whatever the keychain holds.

Handing USB devices to guests is the one thing that takes more. macOS only lets an app at USB devices that
carries the entitlement `com.apple.developer.accessory-access.usb`, and only honours that together with a
provisioning profile: one made in a paid Apple Developer account for the app's identifier, with the
capability *Claim USB Accessory*, and for the certificate the app is signed with (a Developer ID profile
for the app, a development profile that lists your Mac for the development copy). `scripts/bundle-app.sh`
looks for such a profile where Xcode keeps profiles (`~/Library/Developer/Xcode/UserData/Provisioning
Profiles`) and puts it into the app with the entitlement. When there is none it says so and builds the
app without both: everything works but USB devices, and the USB button isn't shown.
`SWIFTVM_PROVISIONING_PROFILE` names a profile to use instead of looking for one, and
`SWIFTVM_PROVISIONING_PROFILE=-` builds without. How the project's own profiles were made is in
`docs/spikes.md`.

## Command line

The `swiftvm` tool is inside the app, at `SwiftVM.app/Contents/Helpers/swiftvm`. *Install Command Line Tool…*
in SwiftVM › Settings puts it on your `PATH`, as a link in `/usr/local/bin`. The app must be running.

```sh
swiftvm create ubuntu-26.04 --name "Web Server" --cpus 2 --memory 4 --disk 32
swiftvm create macos --name "Build Mac" --password 'a password for the account'
swiftvm list
swiftvm info web-server
swiftvm ssh web-server
swiftvm ssh web-server --vsock              # the same without the guest's network
swiftvm install-tools web-server            # guest tools, over SSH; --disc plugs in a disc instead
swiftvm install-tools build-mac --password 'the account password'   # macOS asks for it before installing
swiftvm share web-server ~/Projects
swiftvm forward web-server 8080:80          # http://localhost:8080 is the guest's port 80
swiftvm attach web-server ~/Downloads/data.img
swiftvm usb                                 # the USB devices macOS has given SwiftVM
swiftvm usb attach web-server "SanDisk Ultra"   # by name, vendor:product, serial number or its number in the list
swiftvm usb auto web-server 0781:5581 on    # take it whenever it is plugged in
swiftvm usb detach web-server 0781:5581
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
`Packages/SwiftVMKit/.build/out/Products/Release/swiftvm`. To build only the tool, use
`swift build --package-path Packages/SwiftVMKit --product swiftvm`. At the repository's root the same
product would land next to the app's program, `SwiftVM`, and a Mac's disk takes the two names for one.

`swiftvm create macos` downloads the latest macOS restore image (about 25 GB) unless it is already in
`~/Library/Caches/SwiftVM/Downloads` or you pass `--ipsw <file>`.

`swiftvm quit` never asks anything, so it refuses while a machine is running. While one is still being
created it refuses too, unless you add `--cancel-creations`.

`swiftvm vsock <machine> <port>` connects its input and output to a port in the guest over the socket
device. It is what `swiftvm ssh --vsock` hands to `ssh`, and it works in your own SSH configuration as
`ProxyCommand swiftvm vsock <machine> 22`, for `scp`, `rsync` or an editor that works over SSH.

## Development

```sh
swift run SwiftVM         # builds a development copy of the app and opens it
```

The development copy is an app of its own to macOS: *SwiftVM Dev* (`com.swiftvm.app.dev`), at
`.build/SwiftVM Dev.app`. It keeps its machines, its network settings and its control socket in
`~/Library/Application Support/SwiftVM-Dev`, so it runs next to the app you use and never sees that app's
machines. The `swiftvm` tool inside a copy talks to that copy:

```sh
".build/SwiftVM Dev.app/Contents/Helpers/swiftvm" list
```

`swift run SwiftVM` stays in the terminal until the copy quits, and shows what it prints. Control-C asks the
copy to quit the way `swiftvm quit` does, which it refuses while a machine is running; a second Control-C
leaves it running and gives the terminal back. Running the command again replaces a copy that is still open
with the new build, unless that copy has a machine running. `swift run SwiftVM --background` opens the copy
behind your other windows and returns as soon as it answers its `swiftvm` tool. `scripts/run-dev.sh` is what
`swift run SwiftVM` hands over to, and can be run directly with the same options.

What the two copies do share: the downloaded images in `~/Library/Caches/SwiftVM` (don't have both download
the same system at the same time), the SSH key SwiftVM makes when you have none, the one place for the
`swiftvm` link in `/usr/local/bin`, and `~/.ssh/config` if *Add machines to ~/.ssh/config* is on in both, where
a name used for a machine in both copies leads to only one of them. Machines opened from the Finder go to
the app; the development copy takes one that is dropped on its window.

The development copy is signed with an Apple Development certificate if your keychain has one, and keeps to
the certificate it was first signed with, so that macOS doesn't ask for the microphone again after every
build. Without a certificate it is signed to run on your Mac. It is an app of its own to Apple as well: for
USB devices it needs a provisioning profile of its own, for `com.swiftvm.app.dev`, and does without them
when there is none.

`SWIFTVM_HOME` gives the development copy another data directory, for a second set of machines. The path has
to be short enough for a Unix socket (about 90 characters), and the `swiftvm` tool needs the same setting to
find that copy:

```sh
export SWIFTVM_HOME="$HOME/Library/Application Support/SwiftVM-Scratch"
swift run SwiftVM --background
".build/SwiftVM Dev.app/Contents/Helpers/swiftvm" list
```

## Layout

| Path | What |
|---|---|
| `Package.swift`, `App/` | The SwiftUI app, as the package product `SwiftVM`, and its icon (`AppIcon.icon`, an Icon Composer document) |
| `Packages/SwiftVMKit/` | Engine code as a Swift package: `VMCore`, `VZEngine`, `VMNetworking`, `SSHIntegration`, `DiskTools`, `Installers`, `VMControl`, `GuestChannel` (the protocol between the app and the agent in a guest), and the `swiftvm` tool |
| `Packages/SwiftVMKit/Sources/Installers/Resources/GuestAgent/` | The guest agent for Linux, its systemd units and its installer |
| `Packages/SwiftVMKit/Sources/GuestAgentMac/`, `Sources/swiftvm-agent/` | The guest agent for macOS. It is built with the app, travels inside it at `Contents/Helpers/swiftvm-agent`, and only ever runs in a guest |
| `Packages/SwiftVMKit/Sources/Installers/Resources/GuestAgentMac/` | Its installer, which carries the program and its launchd jobs into a guest |
| `Config/` | The app's `Info.plist` and its entitlements |
| `scripts/` | `build.sh` builds the app, `run-dev.sh` a development copy, `bundle-app.sh` puts either together and signs it, `test.sh` runs the unit tests |
| `docs/` | Notes |

## License

SwiftVM is licensed under the Apache License, Version 2.0. See `LICENSE`.
