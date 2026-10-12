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
| D13 | A desktop is installed by a script in the guest | One file, the same kind for ours and for users' |

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

## D13. A desktop is installed by a script in the guest

Few distributions offer an ARM64 desktop image, and each installer disc wants
its own kind of unattended answers. A cloud image plus a script that installs
the desktop reuses everything Quick Create already does, works the same for
every distribution, and leaves the choice of desktop open.

The script is one file with a comment header: easy to write, to read, and to
pass on, and a list of scripts can be made from the headers alone. The app
calls all of them setup scripts, the desktops too: a desktop is a kind of
script, not a setting of its own, so that what users write stands next to
what the app brings. Users keep theirs in `~/.config/swiftvm/setup-scripts`,
where a script with the name of a built-in one takes its place. A machine
takes several scripts rather than one that does everything, so that a desktop
and Docker stay two files that each do one thing. They run in a
systemd unit of their own after first-boot setup, so that a setup cut short by
a power-off carries on at the next start, and its restart can't cut
first-boot setup off. Progress reaches the app through the guest agent, as everything
else does (D7).

Turned down: unattended installer discs, which need one format per
distribution. Running the script as a step of first-boot setup, which isn't
run again after an interruption. A manifest next to the script, which is two
files to keep in step. Ready-made desktop images, which someone would have to
build and host for every release.
