# Settings

SwiftVM has two kinds of settings: the app's own, and each virtual machine's.

## App settings

Choose **Settings…** in the panel, or press `Cmd+,`.

| Section | What's in it |
| --- | --- |
| SSH | **Add machines to ~/.ssh/config**, to reach every machine with plain `ssh <machine>`. See [SSH](../features/ssh.md) |
| Network | The address range of the shared network, and this Mac's address on it. See [Networking](../features/networking.md) |
| Command Line | Install or uninstall the [`swiftvm`](../features/command-line.md) command |
| Updates | Check for updates, and whether to install them automatically |
| Storage | Where new virtual machines and downloaded images are kept. **Change** picks another folder for either, on another disk if you like |

## Updates

SwiftVM checks for updates by itself and tells you in the panel when one is
ready.

- **Check for Updates…** is in **Settings → Updates** and in the panel's
  **…** menu.
- **Automatically download and install updates** installs an update the next
  time SwiftVM quits.
- Installing an update restarts SwiftVM. If machines are running, SwiftVM asks
  first, as it does [when you quit](../features/virtual-machines.md#quitting).

Builds you make yourself don't update.

## Storage

- **New Virtual Machines** is the folder machines are created in, unless you
  pick another one for a machine in the **New Virtual Machine** form.
- **Downloaded Images** is where Linux images and macOS restore images are
  kept, to be used again for the next machine.

Changing a folder moves nothing. Machines stay where they are, and you move
one with **Move…** in [its settings](../features/virtual-machines.md#where-machines-are-kept).
Images that were downloaded before stay in the old folder: move them to the
new one yourself to keep using them, unless a machine still has one of them
plugged in as an installer disc.

An image that is downloading takes up room on your Mac's own disk until it is
complete, also when the folder is on another disk.

The first time SwiftVM uses a folder on an external or network disk, macOS may
ask whether to allow it. Without that, the machines there are listed as **Not
Available**.

## Virtual machine settings

Choose **Settings…** in a machine's menu, or the gear in its window's toolbar.

| Section | What's in it |
| --- | --- |
| General | Name, system, and where the machine is on disk. **Move…** takes it to [another folder or disk](../features/virtual-machines.md#where-machines-are-kept) |
| Processor and Memory | Processors and memory |
| Storage | The disk and its size, and attached disc and disk images. See [Disks and images](../features/disks.md) |
| Shared Folders | Folders of your Mac the guest can use. See [Shared folders and clipboard](../features/sharing.md) |
| Clipboard | **Share Clipboard** |
| Automation | **Allow Automation**: whether `swiftvm` may run commands in the guest, see its screen, and use its mouse and keyboard. See [Automation](../features/automation.md) |
| Network and SSH | Cable, addresses, and the [SSH](../features/ssh.md) name, user, and port. See [Networking](../features/networking.md) |
| Port Forwarding | Ports of the guest reachable as `localhost` on your Mac |
| USB Devices | Devices the machine takes whenever they are plugged in. See [USB devices](../features/usb-devices.md) |
| Devices | Sound output, microphone, and whether the display resizes with the window. With that off, **Resolution** sets the display's size |
| Keyboard | **Send System Shortcuts to the Guest** |
| Startup | **Secure Boot** and **Rosetta for x86-64 Programs**, for Linux guests |

Changes to processors, memory, and the display apply after the machine is shut
down and started again. Shared folders, port forwards, disk images, and USB
devices change while it runs.

## Files

| Where | What it holds |
| --- | --- |
| `~/Library/Application Support/SwiftVM/Machines/` | One `<name>.swiftvm` package per machine, unless you [keep them elsewhere](#storage) |
| `~/Library/Application Support/SwiftVM/library.json` | The list of your machines and where each one is |
| `~/Library/Application Support/SwiftVM/ssh_config` | The SSH configuration SwiftVM generates |
| `~/Library/Application Support/SwiftVM/known_hosts` | The guests' SSH host keys |
| `~/Library/Caches/SwiftVM/Downloads/` | Downloaded Linux images and macOS restore images, unless you [keep them elsewhere](#storage) |
| `~/.ssh/swiftvm_ed25519` | The SSH key SwiftVM makes if you have none |
| `/usr/local/bin/swiftvm` | The link **Install Command Line Tool…** makes |

A machine's package holds everything about it:

| File | What it holds |
| --- | --- |
| `config.json` | The machine's settings |
| `disk.img` or `disk.asif` | Its disk |
| `snapshots/` | Its [snapshots](../features/snapshots.md) |
| `state.vzvmsave` | Saved memory, while the machine is suspended |
| `logs/console.log` | What a Linux guest printed to its serial console since it last started |

To back up a machine, shut it down and copy its package. To move one, use
**Move…** in its settings. Open a package from the Finder, or drop it on the
**New Virtual Machine** window, to add it to SwiftVM.
