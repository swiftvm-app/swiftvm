# Decisions

The key technical choices, why they were made, and what was turned down.

Most of them come from experiments on real guests: Ubuntu 26.04, Ubuntu 24.04,
Debian 13, and macOS 27, on an Apple M5 Pro. The full notes, with timings, are
in git history as
[`docs/spikes.md`](https://github.com/swiftvm-app/swiftvm/blob/c528fb938ed8bcdcabd2289b4d65fa4927926c9b/docs/spikes.md).

| | Decision | In short |
| --- | --- | --- |
| D1 | The Virtualization framework runs macOS and Linux guests | In the app's process, without root |
| D2 | Windows guests will use QEMU | The Virtualization framework can't boot Windows |
| D3 | One NAT network, created with the first machine | Fixed addresses without root |
| D4 | The app relays forwarded ports | Forwards change while machines run |
| D5 | Snapshots are copies, not layers | Any snapshot can be deleted |
| D6 | A running machine is suspended for a snapshot | Disk and memory always agree |
| D7 | The guest agent talks over the socket device | Works without a network |
| D8 | The Linux agent is a Python script | Nothing extra to build the app |
| D9 | The macOS agent is one program in two halves | Root for power, the session for the clipboard |
| D10 | The command line drives the running app | One owner of the machines |
| D11 | The app lives in the menu bar | No main window |
| D12 | Swift packages and scripts, no Xcode project | `swift build` is the build |

## D1. The Virtualization framework runs macOS and Linux guests

Apple's framework runs guests inside the app's process with one entitlement
and no root. It installs macOS, and from macOS 27 on a guest creates its own
account on first start, so a Mac is ready over SSH about half a minute after it
is installed.

## D2. Windows guests will use QEMU

The Virtualization framework can't boot Windows without private API. Windows
on ARM will run on QEMU with the Hypervisor framework, in a helper process
bundled with the app. The model already names the engine per machine.

## D3. One NAT network, created with the first machine

vmnet creates a shared network without root once the app has the
virtualization entitlement. Address reservations can only be set while a
network is being created, and stop being honored once every machine has left
it. So the network is created when the first machine starts and released when
the last one stops.

## D4. The app relays forwarded ports

vmnet can forward ports, but like reservations they are fixed when the network
is created: adding one would mean shutting down every machine. The app listens
on the Mac and relays to the guest instead. Through the relay, 512 MB arrived
intact at 3.9 GB/s.

Turned down: vmnet's own port forwarding.

## D5. Snapshots are copies, not layers

A snapshot copies the disk, the firmware state, and the saved memory. On APFS
the copy is a clone: a 31 GB macOS machine is duplicated in 24 ms. Disks of
either format work, and deleting one snapshot never touches another.

Turned down: overlay layers on the disk image. They can only be stacked and
dropped from the top, so an old snapshot could never be deleted cleanly.

## D6. A running machine is suspended for a snapshot

A live snapshot suspends the guest, copies its files, and resumes it: under a
second for a 2 GB Linux guest, about five for an 8 GB Mac. The disk image is
only known to be complete once the machine has let go of it.

Turned down: copying the disk of a paused guest, which is faster but can leave
memory and disk disagreeing.

## D7. The guest agent talks over the socket device

Every machine has a virtio socket device, and a connection over it needs no
network in the guest. The agent listens on a port only root can use, and
accepts only the host. The same device carries SSH when the guest's network is
down.

## D8. The Linux agent is a Python script

Every supported cloud image has Python 3, because cloud-init needs it. A script
needs nothing extra on the Mac that builds the app.

Turned down: a static Swift binary. It would share the protocol's code with the
app, but everyone who builds the app would need a second Swift toolchain and
the static Linux SDK.

## D9. The macOS agent is one program in two halves

Shutting down and setting the clock take root. The clipboard belongs to the
session of whoever is logged in. So the agent runs as a root daemon and as a
second half in the login session, and only the daemon talks to the Mac.

Turned down: letting the session half listen on the socket device itself. Its
port would be above 1024, where any program in the guest could sit and be
handed the Mac's clipboard.

## D10. The command line drives the running app

`swiftvm` sends requests to the app over a Unix socket and holds no state of
its own. Everything the interface can do goes through the same model, which is
also how the app is tested against real guests.

## D11. The app lives in the menu bar

A panel under the menu bar item lists the machines and leads to everything
else. Each machine's display, settings, and snapshots are windows of their own.
The app is in the Dock only while a window is open.

Turned down: a main library window, and alerts of the app's own for messages
without a window. An alert is modal for the whole app and takes the keyboard
from a guest someone is typing in.

## D12. Swift packages and scripts, no Xcode project

The app is a Swift package, `swift build` compiles it, and a script makes an
app of the result and signs it. The command-line tool and the guest agent are
built from their own package, because `swiftvm` and `SwiftVM` would be one
file in a shared build folder.
