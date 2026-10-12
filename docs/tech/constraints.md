# Constraints

Supported platforms, and lessons that shape the code.

## Platforms

| Part | Supported |
| --- | --- |
| The app and `swiftvm` | macOS 27 and later, on Apple silicon |
| macOS guests | Unattended setup and guest tools need macOS 27 or later in the guest |
| Linux guests | ARM64. Quick Create: Ubuntu 26.04, Ubuntu 24.04, Debian 13 |
| Linux guest tools | systemd and Python 3. [Automation](../features/automation.md) takes Python 3.9 or newer, and the screen as a tree also `python3-gi` and `gir1.2-atspi-2.0` |
| Linux desktops | GNOME, KDE Plasma, Xfce, and Cinnamon, on each Quick Create system |

Not yet supported: Windows guests, and Intel Macs.

## Signing

- The virtualization entitlement works with any signature, including one made
  to run locally. No Apple Developer team is needed to run machines.
- The USB entitlement only works together with a provisioning profile that
  grants it. With the entitlement and no matching profile, macOS ends the app
  the moment it starts. So both go into the app together or not at all.
- The hardened runtime only loads frameworks signed by the app's own team. A
  signature made to run locally names no team, so such builds turn library
  validation off to load Sparkle. Releases keep it on.

## Networking

- **Never kill the app while a machine is running.** macOS keeps that
  network's address range blocked for every process, for a long time. Stop the
  machines first, then quit.
- A network is only released once every attachment to it is gone, including
  those of machines that have stopped.
- Address reservations match by MAC address. Linux guests must identify
  themselves to DHCP by MAC, which first-boot setup arranges.
- A lease on record is not an address. A guest's real address comes from its
  agent, or from whichever candidate answers on the SSH port.
- A connection that has finished can report failure before its last bytes are
  read. The port relay reads to the end before it trusts the state.
- A side that closes a connection while the other is still sending can take
  down with it what it had sent itself and nobody had read yet. An agent ends
  a [job](./architecture.md#jobs-in-the-guest) by closing its own direction
  only, and waits for the Mac to hang up.

## The Virtualization framework

- A suspended guest can't be resumed while the Mac is locked. The app says so,
  and won't suspend a running machine for a snapshot on a locked Mac.
- A resumed guest thinks no time has passed. macOS corrects itself in seconds;
  Linux needs the guest agent.
- macOS guests answer the power button with a question on their screen. Only
  the guest agent shuts them down unattended.
- A shutdown request sent during startup is lost, so it is repeated for Linux
  guests until the guest goes down.
- A macOS guest can't grow its startup volume: its recovery partition sits
  right behind it.
- Disk images plugged in as USB drives can change while a guest runs, but not
  while it is suspended: saved memory expects the drives it was saved with.
- A USB device that a guest lets go of comes back to the Mac as a new device.
  What identifies it across that is its make and serial number.
- A guest keeps its USB devices through a suspend only in name: the restored
  guest finds them unplugged.

## Guests

- The framework has no public way to read a guest's display or to press its
  keys. Both are done by the agent, inside the guest.
- macOS asks whoever sits at the screen before a program may record it or use
  the mouse and keyboard, and nothing can answer for them. A program that was
  running when it was allowed may still not be let record, so the agent's half
  in the session ends itself when it is refused, and launchd starts it anew.
- A daemon's child that becomes a user can run as them, but not open a window:
  it is outside their session. `launchctl asuser` puts it inside.
- A Wayland desktop doesn't tell an application where on the screen its
  windows are. What an application's accessibility says about the places of
  its parts is zero, or counted from its own window. Only the process that
  draws the screen knows, so only its parts are passed on with places.
- What a display shows can be read as root from the kernel's mode setting,
  whichever desktop put it there. The mouse pointer isn't in it: it is drawn
  on a layer of its own.
- A display that a desktop has turned off shows nothing, and has no size to
  measure either. The pointer, which is what wakes it, goes by the size the
  screen last had.
- An input device made through `uinput` types key codes, not characters. Which
  character a key gives is the guest's keyboard layout's business.
- A command started by a systemd service is ended with the service. The agent
  for Linux only has itself ended (`KillMode=process`), so that what was
  started for someone stays when the agent is replaced by a newer one.
- Debian's `genericcloud` image has no drivers for the display or USB storage,
  and can't be resumed. The catalog uses the `generic` image.
- Ubuntu turns kernel messages off on every console once it is up; only errors
  reach the serial console.
- systemd puts an SSH server on the socket device from version 256 on. For
  older systems the guest tools add it.
- A copy of a cloud-init guest needs a new instance ID, host name, and MAC
  address in its seed image, or it comes up without a network.
- The last step of cloud-init waits for the system to be up. A unit that runs
  after that step can't be wanted by the same target, or the two wait for each
  other at every start but the first. The setup unit is wanted by cloud-init's
  own target.
- A desktop brings NetworkManager, and two services must not configure one
  network card. The card stays with systemd-networkd, which asks for its
  address by MAC, and NetworkManager only watches it. Handing the card over
  doesn't work everywhere: Ubuntu 26.04 configures it before the system
  starts, NetworkManager then leaves it alone, and nothing renews the address.
- Ubuntu 24.04's kernel for virtual machines has no sound driver. The desktop
  scripts install the full kernel there.
- Installing a desktop by its package alone can bring another desktop's login
  theme. The scripts name the theme where that happens.
- What a package prints while it is installed can start with `==> `, and then
  shows as a step. Ubuntu's Firefox package does.
- A guest that loses power while it installs packages comes back with a
  package manager that takes on nothing new: `apt` wants `dpkg --configure -a`
  first. The setup runner does that before it runs a script again.
- `chown user: file`, with nothing after the colon, sets the group on Debian
  and leaves it alone on Ubuntu 26.04, whose tools are a different
  implementation. Scripts for both name the group or leave the colon out.
- macOS doesn't let an app quit while one of its windows has a sheet open, and
  doesn't ask the app first. `swiftvm quit` refuses then, instead of waiting
  for a quit that never comes.

## The app

- An app without a Dock icon is not given the front for asking politely.
  Windows that someone just asked for are brought forward with force; windows
  that nobody asked for open behind.
- Leaving the Dock while in front moves the user to another desktop. The app
  leaves the Dock only once another app is in front.
- The menu bar item can be dragged out of the menu bar. The app puts it back,
  because it is the only way to the machines.
- A quit that is asked for inside a task on the main actor can never be
  answered. Quits go through a timer.

## Building

- The file system doesn't tell `swiftvm` from `SwiftVM`. The tool and the app
  are never built into the same folder.
- An app that `open` starts has neither the terminal nor the caller's
  environment. The development script passes both on.
