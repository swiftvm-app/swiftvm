# Decisions

The key technical choices, why they were made, and what was turned down.

Most of them come from experiments on real guests: Ubuntu 26.04, Ubuntu 24.04,
Debian 13, and macOS 27, on an Apple M5 Pro. The full notes, with timings, are
in git history as
[`docs/spikes.md`](https://github.com/swiftvm-app/swiftvm/blob/c528fb938ed8bcdcabd2289b4d65fa4927926c9b/docs/spikes.md).

| | Decision | In short |
| --- | --- | --- |
| D1 | The Virtualization framework runs macOS and Linux guests | In the app's process, without root |
| D2 | Windows guests use QEMU | The Virtualization framework can't boot Windows |
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
| D14 | `swiftvm` works in a guest through its agent | Commands, screen, and input without a network or private API |
| D15 | A template is a copy of its own, apart from the machines | It never changes, and outlives its machine |
| D16 | The app sees and uses a macOS guest's screen itself | No question on the guest's screen, and no guest tools |
| D17 | `swiftvm` answers a macOS guest's question when it is told to | One command and the password, instead of a person at the screen |

## D1. The Virtualization framework runs macOS and Linux guests

Apple's framework runs guests inside the app's process with one entitlement
and no root. It installs macOS, and from macOS 27 on a guest creates its own
account on first start, so a Mac is ready over SSH about half a minute after it
is installed.

## D2. Windows guests use QEMU

SwiftVM includes QEMU to run Windows 11 for Arm with Apple's Hypervisor
framework. Windows machines use the same app interface and virtual network
as macOS and Linux machines. See [Windows guests](../features/windows-guests.md)
for setup and limitations.

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
session of whoever is logged in, and so do the screen, the mouse, and the
keyboard. So the agent runs as a root daemon and as a second half in the login
session, and only the daemon talks to the Mac.

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

## D14. `swiftvm` works in a guest through its agent

Scripts and AI agents need to run commands in a guest, see its screen, and use
its mouse and keyboard. The agent is already there, runs as root, and has a
line to the Mac that needs no network (D7). So it does these as jobs, each on
a connection of its own to a second port, with the app as the gate and then
the relay.

- **The screen and the input are the guest's own, in Linux guests.** A Linux
  agent reads the display from the kernel's mode setting and makes input
  devices through `uinput`: no desktop is asked, nothing is installed, and it
  works at the login screen. Measured on Ubuntu 26.04 with GNOME on Wayland:
  5 ms to read a 1920 by 1200 screen. A macOS agent can do the same with the
  system's own interfaces, but only once the person at the screen has allowed
  it, which is why the app does it for macOS guests (D16).
- **A job has its own connection.** The agent's line carries one short
  message at a time. A screenshot is megabytes and a command runs for hours.
- **Copying is `tar` through a command.** Both ends have `tar`, and it knows
  folders, links, and permissions. The agent needs no code for it.
- **One switch per machine**, on by default. Whoever can run `swiftvm` can
  already reach a machine's disk and, in guests SwiftVM set up, sign in as an
  administrator. The switch is for a machine that nothing but a person is to
  touch, not a wall.

Turned down: the framework's private interfaces for the display and the
keyboard, for the reason Windows guests get another engine (D2). SSH, which
needs a network, a key, and for root a password in macOS guests. Asking each
desktop for a screenshot, which on Wayland is a different request for every
desktop, most of them behind a question on the screen. A separate program for
the screen and the keyboard, which would be a second thing to install and to
keep in step.

## D15. A template is a copy of its own, apart from the machines

Making machines from one that is set up needs a state that stays put. A
template is a copy of a shut-down machine's disk, firmware, and settings in a
package of its own, in a folder for templates. It never runs, so it never
changes, and it is still there when the machine it came from is deleted. On
APFS the copy is a clone, as a snapshot and a duplicate are (D5).

A machine is made from a template the way a duplicate is made from a machine,
by the same code: copy the files, give the copy its own identity, add it to
the library.

Only a machine that is shut down makes a template. Saved memory expects the
machine it was saved in, and two guests resumed from one memory would wake up
as the same machine on the same network.

Turned down: making machines straight from a snapshot, which lives in its
machine's package, goes with it when the machine is deleted, and may hold
memory. Marking a machine as a template, which leaves a machine in the list
that mustn't start, and changes the template the moment it does. Templates
that share a disk layer with the machines made from them, for the reason
snapshots aren't layers (D5).

## D16. The app sees and uses a macOS guest's screen itself

A macOS guest's agent may only record the screen and use the mouse and the
keyboard once someone at that screen has said so, in System Settings and with
a password. For a machine that a script or an AI agent has just created,
nobody is at the screen.

The app has the machine's display and its input devices, through the view the
framework shows a machine with. So for macOS guests it takes the screenshot
and presses the keys itself: a second view of the machine, in a window that is
never shown, whose picture is read from the surface it is drawn with and which
is handed the events a mouse and a keyboard over it would make. On a macOS
27.0.1 guest with nothing allowed in it, that showed the desktop, the locked
screen, and the login screen of a guest nobody was logged in to, and typed the
password that let it in.

- **Only public interfaces.** The view, AppKit's events, and the surface in a
  layer's contents are all public. How the view shows a display is not
  promised, though: if a later macOS shows it another way, screenshots stop
  and say so, and the agent's own way is still there to go back to.
- **The switch stays the gate.** Whoever can run `swiftvm` could already reach
  the guest's disk (D14). They now see its screen without the guest's say-so
  as well, so a machine that nothing but a person is to touch has automation
  turned off.
- **Linux guests stay with their agent**, which asks nobody either, and types
  on the guest's own terms.
- **The tree stays in the guest.** What programs tell the system's
  accessibility is only told inside it, and macOS still asks before the agent
  may read it.

Turned down: a virtual keyboard and mouse made by the agent as root, which
macOS refuses without an entitlement that Apple hands out. Turning System
Integrity Protection off in the guest, so that the answer to its question can
be written down for it: that takes the recovery system, and leaves every such
guest less protected.

## D17. `swiftvm` answers a macOS guest's question when it is told to

Reading a macOS guest's screen as a tree stays in the guest (D16), where macOS
asks someone at the screen first: a switch in System Settings, and the
account's password. A script or an AI agent that has just made a machine has
nobody to send there.

`swiftvm allow-accessibility <machine> --password <password>` is that someone.
The app has the machine's mouse and keyboard (D16), and does what a person
would: the agent has System Settings opened on the right page, the app finds
the line that says `swiftvm-agent` in a picture of the screen, clicks the
switch at its end, and types the password into the question that follows.

- **Only when it is asked, and with the password.** macOS means the question
  for whoever owns the machine. They answer it by running the command, with a
  password that only they have. Nothing is allowed behind their back: not when
  a machine is created, and not when the guest tools are installed.
- **The agent says where, the app looks and clicks.** A program that isn't
  allowed yet can't see the screen, but is told where windows are. So the
  agent reports the window of System Settings and the question in front of
  it, and the app reads the list with the system's text recognition: the name
  of the program is the same in every language.
- **It is checked, not assumed.** After each step the agent says whether it is
  allowed now. A switch that goes off instead of on is clicked again, and a
  password that macOS doesn't take ends it with that for an answer.

Turned down: doing this by itself for every new macOS guest, since the app
holds the password while it sets one up. Writing the answer into the guest's
privacy database, which macOS protects from everything in the guest, root
included. Clicking where the switch was the last time, without looking: a list
with other programs on it has it elsewhere.
