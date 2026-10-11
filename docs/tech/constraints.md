# Constraints

Supported platforms, and lessons that shape the code.

## Platforms

| Part | Supported |
| --- | --- |
| The app and `swiftvm` | macOS 27 and later, on Apple silicon |
| macOS guests | Unattended setup and guest tools need macOS 27 or later in the guest |
| Linux guests | ARM64. Quick Create: Ubuntu 26.04, Ubuntu 24.04, Debian 13 |
| Linux guest tools | systemd and Python 3 |

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

- Debian's `genericcloud` image has no drivers for the display or USB storage,
  and can't be resumed. The catalog uses the `generic` image.
- Ubuntu turns kernel messages off on every console once it is up; only errors
  reach the serial console.
- systemd puts an SSH server on the socket device from version 256 on. For
  older systems the guest tools add it.
- A copy of a cloud-init guest needs a new instance ID, host name, and MAC
  address in its seed image, or it comes up without a network.

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
