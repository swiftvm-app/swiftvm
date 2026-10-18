# Requirements and limitations

## Platforms

| Part | Requirement |
| --- | --- |
| SwiftVM and `swiftvm` | macOS 27 or newer on Apple silicon |
| macOS guest setup and tools | macOS 27 or newer in the guest |
| Linux guests | ARM64; Quick Create offers Ubuntu 26.04, Ubuntu 24.04, Debian 13, and Arch Linux ARM |
| Linux guest tools | systemd and Python 3; automation requires Python 3.9 or newer |
| Windows guests | Windows 11 for Arm |

Intel Macs and Intel/AMD guest operating systems are unsupported. Linux
[Rosetta](../features/linux-guests.md#rosetta) can run x86-64 applications
inside an ARM64 guest.

## Networking

SwiftVM provides one shared NAT network and one network card per machine.
Bridged, host-only, and isolated networks are unavailable.

Address reservations apply when the network starts. A machine created while
others are running may use a temporary address until all machines stop and
the network is recreated. Stop machines before quitting SwiftVM; force-quitting
can leave the address range temporarily unavailable.

See [Networking](../features/networking.md) for addresses and port forwarding.

## Storage and saved state

- Disks can grow but cannot shrink. A macOS guest's startup volume cannot
  expand into the new space. See [Growing the disk](../features/disks.md#growing-the-disk).
- Disk compression is available for Linux and Windows. It saves space but
  slows writes; a host crash can lose recent writes. See
  [disk compression](../features/disks.md#keeping-the-disk-compressed).
- APFS copies share unchanged blocks. Copies across volumes or on other file
  systems need the space and time for a full copy.
- Saved memory belongs to the original machine. Duplicates and templates
  require a shut-down state.
- A suspended guest cannot resume while the Mac is locked.
- Live snapshots require attached physical USB devices and writable disk
  images to be removed first. See [Snapshots](../features/snapshots.md).

## Guest features

- Linux and Windows guests with graphics acceleration cannot suspend or take
  live snapshots. Windows acceleration is experimental and enabled by default
  for new guests; graphics load can cause rendering failures or Windows crashes.
  Shut accelerated guests down before taking a snapshot or quitting SwiftVM.
  See [Linux graphics](../features/linux-guests.md#graphics-acceleration)
  and [Windows graphics](../features/windows-guests.md#graphics-acceleration).
- macOS needs the guest tools for unattended shutdown. Without them, confirm
  shutdown in the guest's window.
- Linux clipboard sharing requires `spice-vdagent` and may not work in every
  Wayland session. Clipboard sharing supports text only.
- The accessibility tree requires a logged-in desktop session. Linux needs
  `python3-gi` and `gir1.2-atspi-2.0`; macOS requires permission in the guest.
  Windows does not support this feature.
- Windows does not support physical USB passthrough, microphone input, TPM,
  or Secure Boot. See [Windows limitations](../features/windows-guests.md#limitations).

See [Guest tools](../features/guest-tools.md) and
[Automation](../features/automation.md) for the features available in each guest.

## Building and signing

Local builds can run machines without an Apple Developer account. Physical
USB passthrough requires a provisioning profile with the **Claim USB
Accessory** capability; see [Building](building.md#usb-devices).

Build the app and command-line tool in separate build folders: `SwiftVM` and
`swiftvm` are the same filename on a case-insensitive file system. The build
scripts handle this automatically.
