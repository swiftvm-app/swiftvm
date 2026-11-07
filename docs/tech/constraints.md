# Requirements and limitations

## Platforms

| Part | Requirement |
| --- | --- |
| SwiftVM and `swiftvm` | macOS 27 or newer on Apple silicon |
| macOS guest setup and tools | macOS 27 or newer in the guest |
| Linux guests | ARM64; Quick Create offers Ubuntu 26.04, Ubuntu 24.04, Debian 13, Fedora 45, and Arch Linux ARM |
| Nested virtualization | An M3 or later, for Linux guests on Apple's virtualization (not with graphics acceleration) |
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
  live snapshots. Windows acceleration is experimental and off by default
  for new guests; graphics load can cause rendering failures or Windows crashes.
  Windows has Direct3D 11 through DXMT. Direct3D 12, and OpenGL on top of it,
  require Apple's D3DMetal from the Game Porting Toolkit, which you install
  yourself, and Rosetta: D3DMetal is x86-64 code, which runs under Rosetta.
  OpenGL comes from Microsoft's compatibility pack, which needs the Microsoft
  Store, and is version 4.2 with D3DMetal from Game Porting Toolkit 4.0 beta 3;
  without Direct3D 12, apps get only Windows' OpenGL 1.1, in software. macOS
  27 warns that the part of SwiftVM that runs D3DMetal won't open in macOS 28.
  Shut accelerated guests down before taking a snapshot or quitting SwiftVM.
  See [Linux graphics](../features/linux-guests.md#graphics-acceleration)
  and [Windows graphics](../features/windows-guests.md#graphics-acceleration).
- macOS needs the guest tools for unattended shutdown. Without them, confirm
  shutdown in the guest's window.
- Linux clipboard sharing without graphics acceleration requires `spice-vdagent`.
  With acceleration it needs guest tools 1.4 or newer, `wl-clipboard`, and a Wayland
  desktop with data-control support, such as Omarchy. Clipboard sharing supports text only.
- The accessibility tree requires a logged-in desktop session. Linux needs
  `python3-gi` and `gir1.2-atspi-2.0`; macOS requires permission in the guest.
  Windows does not support this feature.
- Windows does not support physical USB passthrough, microphone input, or
  Secure Boot. Its TPM is swtpm, which runs next to QEMU, as the CRB device
  Windows on Arm drives (`Native/QEMU/qemu-tpm-crb.patch`). It has no
  endorsement key certificate, and BitLocker can't use it without Secure Boot.
  See [Windows limitations](../features/windows-guests.md#limitations).

See [Guest tools](../features/guest-tools.md) and
[Automation](../features/automation.md) for the features available in each guest.

## Building and signing

Local builds can run machines without an Apple Developer account. Physical
USB passthrough requires a provisioning profile with the **Claim USB
Accessory** capability; see [Building](building.md#usb-devices).

Build the app and command-line tool in separate build folders: `SwiftVM` and
`swiftvm` are the same filename on a case-insensitive file system. The build
scripts handle this automatically.
