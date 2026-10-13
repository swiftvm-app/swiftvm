# macOS Guests

SwiftVM installs macOS from Apple and, from macOS 27 on, sets it up for you:
no setup assistant to click through.

## Creating

Choose **New Virtual Machine**, and **macOS** as the operating system.

| Setting | What it is |
| --- | --- |
| Version | The latest macOS, downloaded from Apple (about 25 GB), or **Choose Restore Image…** for an IPSW you already have |
| Hardware | Processors, memory, disk size, and [where the machine is kept](virtual-machines.md#where-machines-are-kept). Pick a generous disk, 64 GB or more: [it can't grow later](disks.md#growing-the-disk) |
| Account | Full name, account name, and a password |
| **Log in automatically** | The guest logs in to the account when it starts |
| **Sign in over SSH with my key** | Installs your SSH key, so `ssh` works without a password |

Installing takes a few minutes. The download is kept, so the next Mac you
create starts installing right away. A download that is cut short carries on
where it stopped.

From the command line:

```bash
swiftvm create macos --name "Build Mac" --password 'a password for the account'
swiftvm create macos --ipsw ~/Downloads/restore.ipsw --password '…'
```

## First start

A macOS 27 or newer guest sets itself up on its first start:

- It creates the account and turns on Remote Login.
- SwiftVM installs your SSH key and the [guest tools](guest-tools.md).
- The guest is put on your Mac's time zone, once. If you pick another one in
  the guest later, it stays.

Versions before macOS 27 can't be set up automatically. Create the account in
the setup assistant when the machine first starts.

## Shutting down

- **With the guest tools**, **Shut Down** turns the Mac off at once, the way
  `sudo shutdown -h now` does. Apps aren't asked about unsaved documents.
- **Without them**, macOS asks on its own screen before it shuts down. SwiftVM
  brings the machine's window forward so you can confirm.
- **Suspend** never asks.

## Recovery

**Start in Recovery**, in the menu of a machine that is shut down, boots
macOS Recovery.

## Good to know

- Shared folders appear under **My Shared Files** in the Finder sidebar. See
  [Shared folders and clipboard](sharing.md).
- The shared clipboard needs the [guest tools](guest-tools.md), which need
  macOS 27 or newer in the guest.
- macOS guests have no [serial console](linux-guests.md#serial-console).
- `swiftvm` can [run commands in the guest](automation.md). To see its screen
  and use its mouse and keyboard, macOS wants
  [your say-so](automation.md#macos-guests) in the guest, once.
- A copy of a Mac gets its own serial number.
