# macOS Guests

SwiftVM installs macOS from Apple and, from macOS 27 on, sets it up for you:
no setup assistant to click through.

## Creating

Choose **New Virtual Machine**, then **macOS** in the **Type** dropdown.
Choose a version, name, and password. SwiftVM starts with recommended hardware
and an account based on your Mac's user name.

Use **Advanced** to adjust hardware, storage location, and account settings.

The virtual machine starts after installation to finish setup. Older
versions still use the guest's setup assistant.

| Setting | What it is |
| --- | --- |
| Version | The latest macOS downloaded from Apple, or **Choose Restore Image…** for an IPSW you already have |
| Hardware | Processors, memory, disk size, and [where the machine is kept](virtual-machines.md#where-machines-are-kept). Pick a generous disk: [the startup volume cannot expand later](disks.md#growing-the-disk) |
| Account | Full name, account name, and a password |
| **Log in automatically** | The guest logs in to the account when it starts |
| **Sign in over SSH with my key** | Installs your SSH key, so `ssh` works without a password |

The download is cached for later installations. Interrupted downloads can
[resume](../user-guide/troubleshooting.md#a-download-started-over) while
their partial files are available.

From the command line:

```bash
swiftvm create macos --name "Build Mac" --password 'a password for the account'
swiftvm create macos --ipsw ~/Downloads/restore.ipsw --password '…'
```

## First start

A macOS 27 or newer guest sets itself up on its first start:

- It creates the account.
- With **Sign in over SSH with my key** enabled, it turns on Remote Login and
  SwiftVM installs your SSH key and the [guest tools](guest-tools.md).
- With SSH setup enabled, SwiftVM sets the guest's time zone to your Mac's
  once. Later changes you make in the guest are preserved.

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
- `swiftvm` can [run commands in the guest](automation.md), see its screen,
  and use its mouse and keyboard. The last three work in any macOS guest,
  whatever its version, also at the login screen. To read the screen as a
  tree, macOS wants a say-so in the guest, once:
  [`swiftvm allow-accessibility`](automation.md#macos-guests) gives it.
- A copy of a Mac gets its own serial number.
