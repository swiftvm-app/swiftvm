# Virtual Machines

A virtual machine is a computer that runs in a window on your Mac. SwiftVM runs
[macOS](macos-guests.md) and [Linux](linux-guests.md) guests with Apple's
Virtualization framework.

## The panel

Click SwiftVM's item in the menu bar to open the panel. It lists every machine,
running ones first, with what each is doing and where to reach it.

| In the panel | What it does |
| --- | --- |
| The button on a machine | Start, resume, or suspend it |
| **Open Window** | Show the machine's display |
| **…** on a machine, or right-click | Everything else: power, settings, snapshots, SSH, delete |
| **+** | New virtual machine (`Cmd+N`) |
| **…** at the top | Sort by date or name, show one kind of system, check for updates |
| **Settings…** | [App settings](../user-guide/settings.md) (`Cmd+,`) |

SwiftVM is in the Dock only while one of its windows is open.

## Creating

Choose **New Virtual Machine** and pick a system. You can also drop an
installer disc (ISO), a macOS restore image (IPSW), or an existing virtual
machine on the window.

- [Linux guests](linux-guests.md): from a ready-made image, or from an
  installer disc.
- [macOS guests](macos-guests.md): the latest macOS, or your own restore image.

New machines get half of your Mac's cores (between 2 and 4), 8 GB of memory
(4 GB on Macs with less than 16 GB), and a 64 GB disk for Linux or 128 GB for
macOS. Disks only take up what the guest has written.

## Power

| Action | What it does |
| --- | --- |
| **Start** | Boots the machine |
| **Shut Down** | Asks the guest to shut down cleanly |
| **Restart** | Shuts down, then starts again |
| **Suspend** | Saves the machine's memory to disk and frees your Mac's. **Resume** continues where it was |
| **Pause** | Freezes the machine in memory. It still uses your Mac's memory |
| **Force Stop** | Cuts the power. The guest loses what it hasn't saved |
| **Discard Saved State** | Throws away a suspended machine's memory, to start it fresh |

A macOS guest without the [guest tools](guest-tools.md) asks on its screen
before it shuts down. See [macOS guests](macos-guests.md#shutting-down).

## The machine's window

The window shows the guest's display, which resizes with the window. Its
toolbar has:

- **Power**: the actions above, and everything else in the machine's menu.
- **Network**: the cable, the machine's addresses, and
  [port forwarding](networking.md#port-forwarding).
- **Shared Folders**: [folders](sharing.md) the guest can use.
- **Disc and Disk Images**: [images](disks.md#disc-and-disk-images) plugged in
  as USB drives.
- **USB Devices**: your Mac's [USB devices](usb-devices.md).
- **Sound** and **Microphone**.
- **Settings**: the machine's [settings](../user-guide/settings.md#virtual-machine-settings).

Shortcuts such as `Cmd+Tab` and `Cmd+Space` go to the guest while its window
has focus. Turn off **Send System Shortcuts to the Guest** in the machine's
settings to keep them for your Mac.

## Keyboard shortcuts

These work while one of SwiftVM's windows is in front.

| Action | Shortcut |
| --- | --- |
| New virtual machine | `Cmd+N` |
| Settings | `Cmd+,` |
| Start or resume | `Cmd+R` |
| Suspend | `Cmd+Opt+S` |
| Take snapshot | `Cmd+Shift+S` |
| Duplicate | `Cmd+D` |
| Copy SSH command | `Cmd+Shift+C` |
| Open in Terminal | `Cmd+Shift+T` |

## Duplicating

**Duplicate** copies a machine that is shut down. The copy is a machine of its
own, with a new name, address, and SSH name.

- It takes no time and no extra space at first: the copy shares disk space with
  the original until they differ.
- Forwarded ports, writable disk images, and USB devices the original takes by
  itself stay with the original. Snapshots aren't copied.

## Deleting

**Delete…** moves a machine that is shut down, with its disks and snapshots, to
the Trash.

## Quitting

Quitting SwiftVM while machines are running asks what to do with them:

- **Suspend and Quit** saves their state. They continue where they were the
  next time you start them.
- **Shut Down and Quit** turns them off. Machines without the guest tools are
  stopped at once.

Quitting while a machine is being created cancels it. A download carries on
where it stopped the next time you create that system.
