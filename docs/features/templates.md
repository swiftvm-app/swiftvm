# Templates

A template keeps a machine as it was when you saved it, to make new machines
from. Set a machine up once, with the system, the tools, and the settings you
want, and every new machine starts out that way.

## Saving one

Shut the machine down and choose **Save as Template** in its menu. The
**Templates** window opens and lists the template, named after the machine.

```bash
swiftvm save-template web-server "Web Base"
swiftvm templates
```

- The template holds the machine's disk and its settings. The machine itself
  stays as it is, and you go on using it.
- Nothing that happens in the machine afterwards changes the template.
- The machine has to be shut down: not running, and not suspended.
- Start a new machine at least once before you save it. A Linux machine
  creates its account on its first start, and a template from before that has
  none.

### From a snapshot

A [snapshot](snapshots.md) that was taken while the machine was shut down can
become a template too, without going back to it. Right-click it under
**Snapshots…** and choose **Save as Template**, or run:

```bash
swiftvm save-template web-server "Clean Install" --snapshot "Before upgrade"
```

The machine can be running meanwhile, and stays as it is until the template
is saved: it can't be shut down, suspended, or snapshotted before that. On the
same disk that is over at once. A snapshot of a running machine holds its
memory, which only that machine can resume, so it can't become a template.

## Creating a machine from one

In the **New Virtual Machine** window, choose **Template** in the **Type**
dropdown, and then the template. Or choose **New Machine…** next to it in the
**Templates** window.

Both forms show the template and machine name first, followed by a hardware
summary. Select **Advanced** to expand processors, memory, disk size,
location, and whether to start when ready. Clearing the checkbox hides the
extra controls without changing their values. Until you edit them, the new
machine keeps the template's hardware exactly.

```bash
swiftvm create --template "Web Base" --name "Web 2"
swiftvm create --template "Web Base" --cpus 4 --memory 8 --disk 128
```

| `create --template` option | What it sets |
| --- | --- |
| `--name <name>` | The machine's name. Without it, the template's name, with a number if that is taken |
| `--cpus <n>`, `--memory <GB>` | Processors and memory. Without them, what the template has |
| `--disk <GB>` | A larger disk than the template's. A disk can grow, but it can't shrink, and what the guest does with the new space [depends on the guest](disks.md#growing-the-disk) |
| `--location <folder>` | Keep the machine in this folder instead of the one for new machines |
| `--no-start` | Don't start the machine when it is ready |

The new machine is a machine of its own, as a
[duplicate](virtual-machines.md#duplicating) is:

- It has everything that was on the template's disk: the system, the accounts,
  and what was installed. You sign in as you did before.
- It gets a new name, address, and SSH name. A Linux machine made with Quick
  Create takes the SSH name as its host name.
- Shared folders and read-only disc images come along. Forwarded ports,
  writable disk images, and USB devices the original took by itself don't.

## The Templates window

Choose **Templates…** in the **…** at the top of the panel, or in the **File**
menu.

| In the window | What it does |
| --- | --- |
| **New Machine…** | Creates a machine from the template |
| **Rename…**, on a right-click | Gives the template another name |
| **Show in Finder**, on a right-click | Shows the template's package |
| The trash, or **Delete…** | Moves the template to the Trash. Machines made from it stay as they are |
| **Save as Template** | Saves one of your machines that is shut down |

```bash
swiftvm rename-template "Web Base" "Web Base 2026"
swiftvm delete-template "Web Base 2026"
```

`<template>` is a template's name, or its ID from `swiftvm templates`.

## Good to know

- Saving a template and creating a machine from it take no time and no extra
  space at first, as long as both are on the same disk: APFS shares what
  hasn't changed. To another disk, or on another file system, the disk is
  copied. The panel and the **Templates** window show how far that is.
  **Cancel**, or quitting SwiftVM, calls it off, and nothing is left of the
  template. `swiftvm quit` refuses until the template is saved.
- Templates are kept in `~/Library/Application Support/SwiftVM/Templates`,
  each as one `.swiftvmtemplate` package, named after the template when it was
  saved. Renaming a template doesn't rename its package. **Settings → Storage
  → Templates → Change** picks another folder, on another disk if you like.
  See [Settings](../user-guide/settings.md#storage).
- A template made from a machine on another disk than the templates folder is
  a full copy, and so is each machine made from it on another disk.
- Everything on the machine's disk is in the template, and in every machine
  made from it: also the accounts, their passwords, and their keys.
- Snapshots aren't part of a template, and a template has none.
