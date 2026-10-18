# Architecture

SwiftVM has a menu bar app, a command-line client, and tools that run inside
guests. The app owns the machine library and coordinates both virtualization
engines.

## Programs

| Program | Where it runs | Role |
| --- | --- | --- |
| SwiftVM | Your Mac | Manages machines, windows, storage, and networking |
| `swiftvm` | Your Mac | Sends commands to the running app |
| `qemu-system-aarch64` | Your Mac | Runs Windows guests, and Linux guests with graphics acceleration |
| `swiftvm-agent` | macOS guests | Power, clock, clipboard, and automation |
| `swiftvm-agent.py` | Linux guests | Power, clock, shared-folder mounting, setup progress, and automation |
| `swiftvm-agent.exe` | Windows guests | Power, clock, clipboard, display resizing, window lists for Seamless Mode, setup progress, and commands |

The app and its virtualization engines run as the current Mac user. The guest
tools use system services inside each guest.

## Modules

The root Swift package contains the app in `App/`. Shared functionality lives
in `Packages/SwiftVMKit`.

| Module | Role |
| --- | --- |
| `VMCore` | Machine configuration, state, library, snapshots, templates, and backend interfaces |
| `VZEngine` | macOS and Linux guests using Apple's Virtualization framework |
| `QEMUEngine` | Windows guests, and Linux guests with graphics acceleration, using QEMU, including display and input |
| `VMNetworking` | Shared NAT network, address reservations, and port forwarding |
| `DiskTools` | Disk creation, resizing, conversion, compression, and ISO images |
| `FileSharing` | WebDAV shared folders for Windows guests |
| `Installers` | Downloads, distribution catalog, setup scripts, and guest installation |
| `SSHIntegration` | SSH names, keys, and generated configuration |
| `VMControl` | Communication between the app and `swiftvm` |
| `GuestChannel` | Messages and streaming jobs between the app and guest tools |
| `GuestAgentMac` | macOS guest tools |

`VMCore` defines the backend interface. `BackendRouter` selects `VZEngine` or
`QEMUEngine` from each machine's configuration.

## A machine on disk

A `.swiftvm` package contains the machine's files:

| File | Contents |
| --- | --- |
| `config.json` | Machine configuration |
| `disk.img`, `disk.asif`, or `disk.swiftvmdisk` | Raw, ASIF, or compressed disk |
| `efi-vars.fd` | Linux and Windows firmware variables |
| `aux.img`, `hardware-model.bin`, `machine-identifier.bin` | macOS firmware and identity |
| `seed.iso` | Linux first-boot data or temporary Windows setup data |
| `state.vzvmsave` | Saved state while suspended |
| `snapshots/` | Snapshot files |
| `logs/console.log` | Serial console output |

`library.json` records each package's location. File bookmarks let SwiftVM
follow packages moved on the same disk and recognize disconnected disks.
Creation and moves use staging folders before updating the library.

See [Storage](../user-guide/settings.md#storage) for choosing folders and
[Files](../user-guide/settings.md#files) for default locations and backups.

## Starting a machine

1. The app loads the configuration and selects the backend.
2. The machine joins SwiftVM's shared network, creating it if needed.
3. The backend boots the guest or restores its saved state.
4. SwiftVM connects to the guest tools, which report the guest's system,
   capabilities, and addresses.
5. The app synchronizes the clock and applies guest integrations.

## The control socket

The app listens on `control.sock` in its data folder. Only the current user
can connect. `swiftvm` sends JSON requests and waits for their results.
Console sessions and guest jobs switch to streaming data after the app
accepts the request.

The bundled command-line tool locates its app from its executable path.
`SWIFTVM_HOME` can select a different data folder; see
[Building](building.md#the-development-copy).

## The guest channel

macOS and Linux guest tools connect through virtio sockets. Windows uses a
virtio serial channel. Neither transport needs the guest's network or SSH.

The control channel carries JSON messages for guest status, power, clock,
clipboard, setup progress, and the window list for Seamless Mode. Guest tools advertise their capabilities so
the app can support different installed versions.

The macOS agent has a root daemon for system operations and a login-session
process for clipboard and accessibility. The Windows agent similarly uses a
system service and a session process.

## Seamless Mode

In [Seamless Mode](../features/windows-guests.md#seamless-mode), the Windows
agent's session process lists the visible top-level windows, including the
shell's own such as Start, and sends their frames, front to back. Windows' event
hooks tell it when a window opens, closes, moves, or comes forward. It sends the
list at once, ahead of the picture with the change, and again once the desktop
has been composed with it. It checks every half second for anything the hooks
miss. The app sizes the guest's display to the
Mac's visible screen area. It shows each guest window in a borderless Mac window
that displays only that window's part of the display. Input in that window goes
to the guest's matching pixels. The app moves its windows when the display next
updates after a new list arrives, so that a window's frame and its picture
change together.

While the list is wanted, the agent hides the taskbar and the desktop and puts a
window of its own behind all others. It is a near black, red 1, green 0, and
blue 1, which pictures almost never have. The app draws that colour as fully
transparent, in the VNC client's picture and in CocoaSpice's shader. Whatever
the display shows before the app has heard of a change, such as the place a
window has just left, is see-through rather than black. Windows' panels, such as
Start, Search, and menus, are larger than what they draw, which leaves room for
a shadow. Wherever the backdrop is behind such a panel, the agent finds the
panel's edges where black ends, along the middle of each side. It sends only
that part, so the Mac window holds just the panel. Where another window is
behind instead, it uses the edges it found before. If it has none, it puts the
backdrop right behind the panel for one composed frame to find them. The agent also turns
off Windows' animation effects, as **Settings > Accessibility > Visual effects**
does, so that panels and windows don't slide or fade where the Mac has no window
for them. When the list is no longer wanted, the agent restores the taskbar, the
desktop, and the animation settings. A session process that ends in Seamless
Mode does this when it starts again, and the service restarts one that ends
while its user is still logged in.

A press in a guest window waits for the agent to say whether it is on the
window's title bar, which the agent asks Windows with `WM_NCHITTEST`. On a title
bar, the app moves the Mac window with the pointer itself and has the agent move
the guest's window once it is dropped. Otherwise the press, and whatever the
mouse did while it waited, go to the guest.

The agent marks windows that have sizing borders as resizable. The app makes
the Mac window for each of these a few points larger on every side than the
guest's window. That band is see-through but takes clicks, and it shows the Mac's
resize pointers. A press in it, or just inside the edge, resizes the window on
the Mac. As the edge moves, the app shows that much more or less of the guest's
display and has the agent resize the guest's window to match, until it is let
go.

Accelerated guests draw each part with its own CocoaSpice renderer on the shared
SPICE display. Other guests share the VNC client's surface across all windows.

## Jobs in the guest

The app checks **Allow Automation** before accepting a job. Commands and file
copies use the guest tools, with a separate stream for each job's input,
output, and result. File copies use `tar` at both ends.

Screenshots and input use different paths by guest:

| Feature | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Screenshot and input | Guest tools read the display and create input devices | App uses the virtual machine's display and input view | App uses QEMU's display connection |
| Accessibility tree | Guest tools use AT-SPI in the desktop session | Guest tools use the accessibility API after permission is granted | Unavailable |

`swiftvm allow-accessibility` grants the macOS guest tools permission through
System Settings in the guest, using the supplied administrator password.
See [Automation](../features/automation.md) for commands and requirements.

## Networking

All machines share one NAT network managed by vmnet. It is created when the
first machine starts and released when the last one stops. Address
reservations are set when the network is created.

The app relays forwarded ports, allowing forwards to change while machines
run. It selects a private address range that is available on the Mac. See
[Networking](../features/networking.md).

## Creating machines

| Guest | Installation |
| --- | --- |
| Linux, Quick Create | Download and verify a cloud image, prepare its disk, and provide the account, SSH key, guest tools, and setup scripts through cloud-init |
| Linux, installer disc | Create an empty disk and attach the chosen ISO |
| macOS | Install an IPSW restore image; supported guests create an account on first start, with the SSH key and guest tools added when SSH setup is enabled |
| Windows | Install Windows 11 for Arm with an answer file, then add the account, drivers, and guest tools; optional SSH setup needs Windows Update access |

Linux [setup scripts](../features/setup-scripts.md) run in a systemd service
after cloud-init. The runner records completed scripts and reports progress
through the guest tools. Interrupted setup resumes with the unfinished script.

## Snapshots and templates

A snapshot copies a machine's disk, firmware, and any saved memory into its
package. A running machine is suspended for the copy and resumed afterwards.
APFS clones share unchanged disk blocks; other file systems use full copies.

A template is an independent `.swiftvmtemplate` package containing a disk,
firmware, and configuration. It excludes saved memory, snapshots, and logs.
Creating a machine from it copies those files and assigns a new identity.

See [Snapshots](../features/snapshots.md) and [Templates](../features/templates.md)
for usage and restrictions.
