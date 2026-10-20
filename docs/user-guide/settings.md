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
| Storage | Where new virtual machines, templates, and downloaded images are kept. **Change** picks another folder for each, on another disk if you like |

## Updates

SwiftVM checks for updates by itself and shows the available version in the
menu bar panel, without opening an update window on its own.

- Choose **Update…** next to the version to open the update dialog and decide
  whether to install. The button is unavailable while a download is in progress.
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
- **Templates** is where [templates](../features/templates.md) are kept.
- **Downloaded Images** stores cached guest images and installers for reuse.

Changing a folder leaves existing files in place. Use **Move…** in a
[machine's settings](../features/virtual-machines.md#where-machines-are-kept)
to move it. Move templates and cached images yourself to reuse them in the
new folders; templates left in the old folder stop appearing in the list.
Eject any image attached to a machine before moving it.

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

Shut down the machine to change processors, memory, display, audio, or startup
settings. Linux clipboard settings require a shutdown only without graphics
acceleration. Shared folders,
port forwards, removable images, and supported USB devices can change while
the machine runs. Microphone input and physical USB devices are unavailable
for Windows guests.

## Files

| Where | What it holds |
| --- | --- |
| `~/Library/Application Support/SwiftVM/Machines/` | One `<name>.swiftvm` package per machine, unless you [keep them elsewhere](#storage) |
| `~/Library/Application Support/SwiftVM/library.json` | The list of your machines and where each one is |
| `~/Library/Application Support/SwiftVM/Templates/` | One `<name>.swiftvmtemplate` package per [template](../features/templates.md), unless you [keep them elsewhere](#storage) |
| `~/Library/Application Support/SwiftVM/templates.json` | Where templates are kept, once you have chosen another folder for them |
| `~/Library/Application Support/SwiftVM/ssh_config` | The SSH configuration SwiftVM generates |
| `~/Library/Application Support/SwiftVM/known_hosts` | The guests' SSH host keys |
| `~/Library/Caches/SwiftVM/Downloads/` | Cached guest images, installers, and drivers, unless you [keep them elsewhere](#storage) |
| `~/.ssh/swiftvm_ed25519` | The SSH key SwiftVM makes if you have none |
| `/usr/local/bin/swiftvm` | The link **Install Command Line Tool…** makes |

A machine's package holds everything about it:

| File | What it holds |
| --- | --- |
| `config.json` | The machine's settings |
| `disk.img`, `disk.asif`, or `disk.swiftvmdisk` | Its disk |
| `snapshots/` | Its [snapshots](../features/snapshots.md) |
| `state.vzvmsave` | Saved memory, while the machine is suspended |
| `logs/console.log` | Recent serial console output; rotates at 4 MB |

To back up a machine, shut it down and copy its package. To move one, use
**Move…** in its settings. Open a package from the Finder, or drop it on the
**New Virtual Machine** window, to add it to SwiftVM.
