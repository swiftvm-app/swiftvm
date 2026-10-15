# Templates

A template saves a configured machine so you can create more like it, with
the same system, software, accounts, and settings.

## Saving one

Shut the machine down and choose **Save as Template** in its menu. The
**Templates** window opens and lists the template, named after the machine.

```bash
swiftvm save-template web-server "Web Base"
swiftvm templates
```

- The template is independent of the original machine. You can keep using or
  delete the original without changing the template.
- A suspended machine must be shut down before saving it as a template.
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

The machine can stay running, but power actions and snapshots are unavailable
until saving finishes. Snapshots that include saved memory cannot become
templates.

## Creating a machine from one

In the **New Virtual Machine** window, choose **Template** in the **Type**
dropdown, and then the template. Or choose **New Machine…** next to it in the
**Templates** window.

The new machine uses the template's hardware settings. Use **Advanced** to
change processors, memory, disk size, storage location, or whether to start
when ready.

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

- On the same APFS volume, templates and new machines share unchanged disk
  blocks. Across volumes or on other file systems, they are full copies.
  SwiftVM shows progress and lets you cancel. `swiftvm quit` refuses while
  saving is in progress.
- Templates are kept in `~/Library/Application Support/SwiftVM/Templates`,
  each as one `.swiftvmtemplate` package, named after the template when it was
  saved. Renaming a template doesn't rename its package. **Settings → Storage
  → Templates → Change** picks another folder, on another disk if you like.
  See [Settings](../user-guide/settings.md#storage).
- Everything on the machine's disk is in the template, and in every machine
  made from it: also the accounts, their passwords, and their keys.
- Snapshots aren't part of a template, and a template has none.
