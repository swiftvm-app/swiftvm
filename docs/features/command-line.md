# Command Line

`swiftvm` does from a terminal what the app does from the menu bar. It drives
the running app, so SwiftVM must be open.

## Install

Homebrew puts `swiftvm` on your `PATH`. Otherwise choose **Settings… → Command
Line → Install Command Line Tool…**, which links `/usr/local/bin/swiftvm`. The
tool itself is inside the app, at `SwiftVM.app/Contents/Helpers/swiftvm`.

## Basics

```bash
swiftvm help                 # every command
swiftvm list                 # your machines
swiftvm info web-server      # one machine in detail
```

`<machine>` is a machine's name, its [SSH name](ssh.md), or its UUID.

## Machines

| Command | What it does |
| --- | --- |
| `list` | List virtual machines |
| `info <machine>` | Show one machine in detail |
| `create <system> [options]` | Create a machine and start it, unless `--no-start` is given |
| `create --template <template> [options]` | Create a machine from a [template](templates.md#creating-a-machine-from-one) |
| `clone <machine> [name]` | Copy a machine that is shut down |
| `move <machine> <folder>` | Move a machine that is shut down to [another folder or disk](virtual-machines.md#where-machines-are-kept), and wait until it is there |
| `resize <machine> <GB>` | Grow the disk of a machine that is shut down |
| `compression <machine> on\|off` | Enable or disable [disk compression](disks.md#keeping-the-disk-compressed) for a shut-down Linux or Windows machine |
| `open <machine>` | Show the machine's window |
| `delete <machine>` | Move a stopped machine to the Trash |

`<system>` is `macos`, `windows`, or a Linux image: `ubuntu-26.04`,
`ubuntu-24.04`, `debian-13`, or `arch`.

`create` waits for the machine to be created and started, not for setup inside
the guest to finish. Use `swiftvm wait <machine>` for the guest tools and
`swiftvm info <machine>` to check installation or setup-script progress.

`swiftvm scripts` lists the [setup scripts](setup-scripts.md) for `--script`:
SwiftVM's [built-in scripts](setup-scripts.md#built-in-scripts), and
[your own](setup-scripts.md#your-own-scripts). With a Linux image, as in
`swiftvm scripts debian-13`, it lists those for that image.

| `create` option | What it sets |
| --- | --- |
| `--name <name>` | The machine's name |
| `--cpus <n>` | Processors |
| `--memory <GB>` | Memory |
| `--disk <GB>` | Disk size |
| `--user <name>` | The account's name |
| `--password <password>` | The account's password. Required for automatic macOS setup, Windows, and Linux desktop scripts |
| `--location <folder>` | Keep the machine in this folder instead of the one for new machines |
| `--no-ssh-key` | Don't install your SSH key in the account. Linux then needs `--password`; macOS leaves Remote Login off |
| `--rosetta` | Linux: run x86-64 programs with [Rosetta](linux-guests.md#rosetta), using Apple's backend without GPU acceleration; can't be combined with `--gpu` |
| `--gpu` | Linux: require [graphics acceleration](linux-guests.md#graphics-acceleration), which is on by default when available unless `--rosetta` is requested |
| `--no-gpu` | Linux: use Apple's backend without GPU acceleration, with suspend support |
| `--compressed` | Linux and Windows: keep the disk [compressed](disks.md#keeping-the-disk-compressed) from the start |
| `--ipsw <file>` | macOS: install this restore image instead of downloading the latest |
| `--iso <file>` | Windows: install this Windows 11 Arm64 ISO instead of downloading |
| `--script <name>` | Linux: run a [setup script](setup-scripts.md) on the first start, by its name in `swiftvm scripts`. A desktop needs `--password` |
| `--script <file>` | The same with a file, by its path: `./mine.sh` |
| `--script … --script …` | Several, which run in that order |
| `--no-start` | Don't start the machine when it is ready |

With `--template`, the machine keeps the template's system and account, and
only `--name`, `--cpus`, `--memory`, `--disk`, `--location`, and `--no-start`
apply. `--disk` then grows the disk beyond the template's.

## Power

| Command | What it does |
| --- | --- |
| `start <machine>` | Start, or resume a suspended machine |
| `stop <machine>` | Shut down and wait |
| `restart <machine>` | Shut down and start again |
| `suspend <machine>` | Save the machine's state to disk |
| `pause <machine>`, `resume <machine>` | Freeze the machine in memory, and continue |
| `force-stop <machine>` | Stop immediately |
| `discard-state <machine>` | Throw away a suspended machine's saved state |

## Connecting

| Command | What it does |
| --- | --- |
| `ssh <machine> [--vsock] [ssh arguments]` | Open a shell or run a command in the guest. See [SSH](ssh.md) |
| `ip <machine>` | Print the machine's IP address |
| `console <machine> [--wait <seconds>]` | Connect to a Linux guest's [serial console](linux-guests.md#serial-console). `Ctrl+]` leaves |
| `vsock <machine> <port>` | Connect input and output to a port in the guest over its socket device |
| `plug <machine>`, `unplug <machine>` | Plug in the network cable, or pull it |
| `forward <machine> <port>[:<guest port>]` | [Forward a port](networking.md#port-forwarding). `--udp`, `--allow-others` |
| `unforward <machine> <port>` | Stop forwarding it. `--udp` |

## Sharing and devices

| Command | What it does |
| --- | --- |
| `share <machine> <folder>` | [Share a folder](sharing.md). `--read-only` |
| `unshare <machine> <folder>` | Stop sharing it |
| `share-clipboard <machine> on\|off` | Share the clipboard, or stop |
| `attach <machine> <image>` | Plug in a [disc or disk image](disks.md#disc-and-disk-images). `--read-only` |
| `eject <machine> <image>` | Unplug it |
| `usb` | List the [USB devices](usb-devices.md) SwiftVM has |
| `usb attach <machine> <device>` | Hand a USB device to a running machine |
| `usb detach <machine> <device>` | Give it back to your Mac |
| `usb auto <machine> <device> on\|off` | Attach it whenever it is plugged in, or stop |
| `install-tools <machine>` | Install the [guest tools](guest-tools.md). `--disc`, `--password <password>` |

## Automation

These work inside a running guest. Requirements vary by guest and command;
see [Automation](automation.md#what-works-where).

| Command | What it does |
| --- | --- |
| `wait <machine>` | Wait until the guest tools answer. `--timeout <seconds>` |
| `exec <machine> [--] <command>` | [Run a command](automation.md#commands) in the guest, and end with its exit status. `--root`, `--user <name>`, `--cwd <folder>`, `--env <name>=<value>`, `--timeout <seconds>` |
| `cp <from> <to>` | [Copy a file or a folder](automation.md#files) into the guest or out of it. The guest's side is `<machine>:<path>`. `--root`, `--user <name>` |
| `screenshot <machine> [file]` | Save [what is on the guest's screen](automation.md#the-screen) as a PNG |
| `ui <machine> click <x> <y>` | Click. Also `double-click`, `right-click`, `move`, `drag <x> <y> <to x> <to y>`, and `scroll <x> <y> up\|down\|left\|right` |
| `ui <machine> type <text>` | Type text |
| `ui <machine> key <key>…` | Press keys: `Return`, `ctrl+c` |
| `ui <machine> tree` | Print [what is on the screen](automation.md#what-is-on-the-screen) as a tree, in JSON. `--app <name>`, `--depth <levels>`, `--all` |
| `ui <machine> press <element>` | Press a part of the tree, by its `id`. Also `focus <element>` and `set <element> <text>` |
| `allow-accessibility <machine> --password <password>` | Have a macOS guest [let the guest tools read its screen as a tree](automation.md#macos-guests), once |
| `automation <machine> on\|off` | Enable or disable `exec`, `cp`, `screenshot`, and `ui`. See [Automation](automation.md#turning-it-off) |

## Snapshots

| Command | What it does |
| --- | --- |
| `snapshot <machine> [name]` | Take a [snapshot](snapshots.md) |
| `snapshots <machine>` | List snapshots |
| `revert <machine> <snapshot>` | Go back to a snapshot |
| `rename-snapshot <machine> <snapshot> <new name>` | Rename one |
| `delete-snapshot <machine> <snapshot>` | Delete one |

## Templates

| Command | What it does |
| --- | --- |
| `templates` | List [templates](templates.md) |
| `save-template <machine> [name]` | Save a machine that is shut down as a template. `--snapshot <snapshot>` saves it as it was at a snapshot taken while it was shut down |
| `create --template <template> [options]` | Create a machine from a template |
| `rename-template <template> <new name>` | Rename one |
| `delete-template <template>` | Move one to the Trash. Machines made from it stay as they are |

`<template>` is a template's name, or its ID from `swiftvm templates`.

## Quitting

`swiftvm quit` quits the app. It never asks anything, so it refuses while a
machine is running. While one is being created it refuses too, unless you add
`--cancel-creations`.

It also refuses while machine files are being moved, copied, resized, or
converted, or a dialog is open. Finish or cancel that work first.

## Example

```bash
swiftvm create ubuntu-26.04 --name "Web Server" --cpus 2 --memory 4 --disk 32
swiftvm wait web-server
swiftvm exec web-server --root -- sh -c 'apt-get update && apt-get install -y nginx'
swiftvm share web-server ~/Projects
swiftvm forward web-server 8080:80
swiftvm snapshot web-server "Before upgrade"
swiftvm stop web-server
swiftvm save-template web-server "Web Base"
swiftvm create --template "Web Base" --name "Web 2"
swiftvm start web-server
swiftvm suspend web-server
swiftvm start web-server
```
