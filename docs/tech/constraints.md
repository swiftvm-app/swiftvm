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
| Windows guests | Windows 11 for Arm (Arm64), on the QEMU inside the app. Tried with 26H2 |
| Windows guest tools | .NET Framework 4.8, which Windows 11 has, to build the agent; the drivers on `virtio-win` 0.1.302 |

Not supported: Intel Macs, and Windows for Intel and AMD processors.

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
- Saved memory only fits the machine it was saved in: the same hardware, down
  to the address of its network card. A duplicate or a template is made from a
  machine that is shut down, and leaves saved memory behind.
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

- The framework has one public way to a guest's display and its input
  devices: the view that shows a machine to its user. The view doesn't have to
  be shown. In a window that is never put on the screen it still gets the
  guest's picture, as a surface in the contents of one of its layers, and
  still passes on the mouse and key events it is handed.
- A view of the framework's asks nobody when it is given a second view of the
  same machine. Only one of them may resize the display to fit itself, so the
  one that is never shown doesn't.
- A guest that has turned its display off has no picture: the view's layer
  loses its surface until a key wakes the display.
- AppKit makes every mouse event it is asked for with the first button,
  whatever kind of event it is. An event for another button, or for the wheel,
  is made as Core Graphics makes them. Such an event belongs to no window and
  says where on the screen it happened, which the view takes for a place in
  its own window.
- The view only passes on a wheel that counts in points. One that counts in
  lines is dropped.
- A key event tells the view which of the two keys of a kind is held, left or
  right, in bits that AppKit has no names for. Without them a held Shift isn't
  held in the guest.
- A wheel reaches a guest as its hardware turned it, and macOS turns that
  around unless **Natural scrolling** is off. Which it is, only the guest
  knows.
- Inside a macOS guest there is no way around the question on its screen. A
  program that runs as root is told that it isn't entitled when it makes a
  keyboard or a mouse of its own, the events it posts are dropped, and the
  screen isn't recorded for it either.
- A program that macOS hasn't allowed to see the screen is still told where
  every window is and whose it is, only not what it is called or what is in
  it.
- Asking macOS to be allowed is what puts a program on the list in System
  Settings. The question that comes up with it only leads there, and lies over
  the list: the agent ends the program that shows it.
- The page of System Settings with that list opens by its address, whatever
  macOS calls the page: **Accessibility** before, **Device Control and Data
  Access** in macOS 27.
- Turning a switch on that list on asks for the password, in a window of
  System Settings' own. Turning it off asks for nothing.
- That question is on the screen before it listens. What is typed in its
  first second is lost, and the rest is no password.
- A pointer that already rested where something new came up never moved onto
  it, and macOS takes its click for one on what lies beneath: the line of a
  list instead of the switch on it. A click arrives from a point beside.
- A program that keeps its permission is not told when the permission is
  taken away: it goes on being allowed until it starts anew.
- The first time text is read from a picture, the system can take some twenty
  seconds over it. Later readings take a fraction of one.
- macOS asks whoever sits at the screen before a program may record it, use
  the mouse and keyboard, or read what others show there, and nothing in the
  guest can answer for them. A program that was running when it was allowed
  may still not be let record, so the agent's half in the session ends itself
  when it is refused, and launchd starts it anew.
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

## QEMU and Windows

- The Virtualization framework doesn't start Windows. QEMU does, on the
  Hypervisor framework, with no emulator built in.
- QEMU's VNC server won't start without a keyboard layout, though the app
  hands it keys by their place. The app ships `en-us`.
- QEMU's VNC refresh starts at 30 ms and backs off while idle. The bundled
  build patches it to 16 ms and wakes it when the guest draws or the client
  asks for another frame. The patch ships with QEMU and is part of its build
  cache key. The client asks for the next update before reading this one's
  pixels, and receives a rectangle before locking the displayed surface once
  to copy it. Neither change adds graphics acceleration inside Windows.
- A macOS local stream socket starts with 8 KB buffers, too small for display
  frames of several MB. The display pair asks for a 1 MB send buffer at QEMU's
  end and a 1 MB receive buffer at the app's end.
- A virtio network card makes QEMU look for an option ROM, which the app doesn't
  ship: the firmware has a driver of its own. It is started without one
  (`romfile=`).
- A block node's name is 31 characters at most.
- A device with a place in the boot order (`bootindex`) makes the firmware look
  at those devices only. An installer disc then isn't seen, and the machine
  starts the firmware's shell. No device gets one; the firmware's own order,
  which Windows Setup puts Windows at the top of, decides.
- A disc image plugged in as a USB disk is a hard disk to Windows, which then
  doesn't read its file system: Windows Setup finds no installation files and
  asks for drivers. Discs are USB drives for discs (`usb-bot` with a `scsi-cd`).
- QEMU's USB controller has four ports. More devices than that go behind a hub
  that QEMU adds, which runs at USB 1.1 speed. The controller is given fifteen,
  as many as it takes.
- QEMU tells the USB devices of a saved machine apart by their port. A restore
  only works with each device in the port it was in, which plugging drives in
  and out while the machine runs shuffles. Every device has a port of its own,
  and the saved state's file starts with the drives' ports: a snapshot copies
  that one file.
- QEMU can't save its USB sound card. It is unplugged for the moment saving
  takes, and a restored machine has it plugged in again.
- The firmware asks for a key before it starts an installer disc, and starts
  the next device without one. The app presses the space bar for the first ten
  seconds of a machine whose disk is still empty.
- Windows Setup draws only on a framebuffer that the firmware set up (`ramfb`),
  at the size the firmware picked: 800 by 600. With only a virtio GPU it shows
  nothing. After setup the driver for the virtio GPU is there, and the machine
  starts with that one, the size of its window.
- The virtio GPU's driver offers the size the window asks for as a mode but
  doesn't switch to it. A program at the screen has to. Red Hat's helper for
  that looks at the first display device only, which is Windows' basic one, so
  the agent's half in the session asks the driver for the size itself (its
  private escape) and switches.
- Changing a running machine's hardware isn't possible, so a guest restart ends
  QEMU (`-no-reboot`), and the machine starts it again with the hardware it is
  configured with by then.
- Saved memory expects the hardware it was saved with. A machine is resumed
  with the display adapter it last started with, whatever it would start with
  now.
- QEMU on macOS has no socket device. The agent's serial port in Windows is
  open to SYSTEM and administrators only: a program of an account that isn't
  elevated is refused.
- A Windows disc's files are in UDF, with an ISO 9660 part that only holds a
  note saying so. `tar` reads no further than that, so the disc is mounted to
  look inside.
- Microsoft hands out a link to Windows only to a session that its page's
  fingerprint script has registered, and turns many VPNs away.
- Windows' WebDAV client takes files of 50 MB at most until told otherwise in
  its registry, which the guest tools do.
- Windows has a write on a pipe handle that isn't overlapped wait for a read
  that is pending on the same handle. The agent's service and its half in the
  session talk over a pipe both ends open overlapped: otherwise what the Mac
  sends waits until the session next says something.
- Windows 11 calls itself Windows 10 in its registry. The build number says
  which it is.

## Storage

- `FileManager` copies a file to another disk by writing all of it, also the
  empty space of a sparse disk image: 300 MB for an image that held 16 MB.
  Machines move with `copyfile` and `COPYFILE_DATA_SPARSE`, which leaves the
  space empty.
- `copyfile` copying a folder carries on past a file it couldn't copy and
  reports success, unless its callback tells it to stop.
- A path says nothing about why a package isn't there. A bookmark names the
  disk it was on, and whether that disk is connected is the difference between
  a machine that is away and one that was deleted.
- A bookmark follows a package into the Trash. One it finds there counts as
  deleted.
- A copy that `copyfile` has finished may still be on its way to the disk. It
  is flushed before the original is removed: an external disk can be pulled
  out a moment later.
- macOS keeps an app from external and network disks until the user allows
  it, and a package it can't look at seems not to be there. Only a package
  that is known to be missing from a connected disk is forgotten.

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
