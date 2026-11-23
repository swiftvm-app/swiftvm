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

### Install tools before desktop permissions

To install the guest tools for commands and file transfer while leaving desktop permission setup for later:

```bash
swiftvm create macos --name "Build Mac" --password 'a password for the account' --no-desktop-permissions
swiftvm wait build-mac
```

SwiftVM installs and starts the tools through the usual SSH bootstrap, then finishes setup without asking for desktop permission or clearing the desktop's installation notices. This option needs macOS 27 or newer and SSH key setup. It cannot be combined with `--no-ssh-key` or used with templates or other guest systems. An older app refuses the mode instead of ignoring it. Creation without the option keeps its automatic permission setup.

To use a dedicated bootstrap identity, combine the option with `--managed-ssh-key` or `--ssh-identity <private-key-path>`; see [Choose a key for a new machine](ssh.md#choose-a-key-for-a-new-machine). An app that supports only one of the two requested capabilities refuses the combined mode.

The tools can run commands and copy files before desktop consent. Advertised automation features describe what the tools support, not whether macOS has allowed accessibility access. `wait` accepts connected, working tools even when that access is unavailable. Guest accessibility requests then explain the required permission; `control` can still use the screen's pixels and the virtual mouse and keyboard.

When you choose to enable guest accessibility, use the existing permission setup:

```bash
swiftvm control build-mac allow --password 'the account password'
```

This follows the guest's normal consent in System Settings. The creation option does not change the later permission command or the normal behavior of `install-tools --password`.

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
