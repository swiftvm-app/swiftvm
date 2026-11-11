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
- After automatic setup grants desktop access, SwiftVM dismisses recognized
  background-activity and extension-added notices left on the desktop. This
  currently recognizes English notices. Notification settings stay as they
  were; future notifications still appear.

Versions before macOS 27 can't be set up automatically. Create the account in
the setup assistant when the machine first starts.

## Fixed display

For a macOS guest on Apple Virtualization, save an exact panel while the machine is shut down:

```bash
swiftvm display build-mac 2560 1664 220 --fixed
swiftvm info build-mac
```

Width and height are physical pixels; the last number is the panel's pixel density in pixels per inch (ppi). These describe the virtual hardware, not the guest's logical workspace. macOS chooses its UI scaling in its own Displays settings, so a 2560-pixel panel need not have 2560 logical points of workspace. `info` reports the saved physical dimensions, density and whether the display follows its window.

The saved panel request and the guest's active display mode are separate. A request accepted by Apple's validator can still produce a different framebuffer size in macOS. When screenshot dimensions matter, check the resulting screenshot as well as `info`; this command does not change the guest's display preferences.

The command requires an idle, stopped machine with no saved memory. Shut it down and discard any saved state before changing its panel. SwiftVM holds ownership of the package while Apple's framework validates the candidate and saves it; unsupported dimensions or a package in use refuse without changing the saved configuration. All three values must be positive integers, and Apple's framework determines the supported panel limits. Linux and QEMU displays do not support this density-setting command.

Fixed mode persists across cold boots. Resizing the viewer changes how the saved panel fits in the window, without requesting a different guest display size. Existing interactive display behavior stays the same until fixed mode is selected; the machine's display settings can enable following the window again.

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
  whatever its version, also at the login screen. To know what is on the
  screen by its parts, macOS wants a say-so in the guest, once:
  [`swiftvm control <machine> allow`](automation.md#macos-guests) gives it.
- A copy of a Mac gets its own serial number.
