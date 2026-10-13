# Disks and Images

## The disk

Each machine has one disk. You pick its size when you create the machine, any
size you type, but it only takes up what the guest has written to it.

The disk is in the machine's package, wherever you
[keep the machine](virtual-machines.md#where-machines-are-kept).

## Growing the disk

Shut the machine down, then choose **Resize…** under **Storage** in its
settings, or run:

```bash
swiftvm resize web-server 64    # the new size in GB
```

A disk can grow, but it can't shrink. Growing only makes the hardware bigger;
what the guest does with the new space depends on the guest:

| Guest | After growing |
| --- | --- |
| Linux, made with Quick Create | Grows into the new space at its next start |
| Other Linux | Grow the partition and the file system in the guest, for example with `growpart` and `resize2fs` |
| macOS | The startup volume can't grow. Add a volume in the new space with Disk Utility in the guest |

So pick a generous size when you create a Mac.

## Disc and disk images

Disc images (ISO) and disk images (raw or ASIF) plug into a machine as USB
drives, also while it runs.

Attach one under **Disc and Disk Images** in the machine's toolbar, in its
settings, or with:

```bash
swiftvm attach web-server ~/Downloads/data.img
swiftvm attach web-server ~/Downloads/installer.iso --read-only
swiftvm eject web-server data.img
```

- Disc images are always read-only.
- Eject a drive in the guest before ejecting it here, or the guest may lose
  what it was still writing.
- Drives can't change while a machine is suspended. Resume it first.
- A machine won't start while one of its images is missing. Put the image
  back, or eject it in the machine's settings.

## Copies and snapshots

[Duplicates](virtual-machines.md#duplicating),
[templates](templates.md), and [snapshots](snapshots.md) are instant because
APFS shares the unchanged parts of the disk. On a volume with another file
system they are full copies, and so is a template that is kept on another disk
than its machine.

A machine that [moves to another disk](virtual-machines.md#where-machines-are-kept)
takes its snapshots along. They are copied in full then, since two disks can't
share anything.
