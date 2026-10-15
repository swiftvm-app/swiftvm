# Disks and Images

## The disk

Each machine has one main disk. Choose its capacity when you create the
machine. On APFS, it uses space as the guest writes data.

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
| Windows | Extend the volume in Disk Management inside the guest |

So pick a generous size when you create a Mac.

## Keeping the disk compressed

Linux and Windows disks can be compressed to save space on your Mac. Savings
depend on their contents; video, archives, and other compressed files benefit
less.

Shut the machine down, then choose **Turn On…** next to **Compression** under
**Storage** in its settings, or run:

```bash
swiftvm compression web-server on     # off to go back
```

Everything on the disk is written out anew. That takes a while for a large
disk, and needs room for the new disk next to the old one until it is done.

A new machine can have a compressed disk from the start: turn on **Keep the
disk compressed** under **Advanced** when you create it, or add `--compressed`
to `swiftvm create`.

What changes for the machine:

- **Writes are slower.** Leave compression off for workloads with frequent
  writes, such as a busy database.
- **A crash of your Mac can cost the last second.** If the Mac loses power or
  crashes while the machine runs, the disk comes back whole, as it was at one
  moment in its last second. What the guest wrote after that moment is gone,
  also what it was told was safe. A crash of the guest or of SwiftVM loses
  nothing.
- **Snapshots stay as they are.** Going back to a snapshot from before brings
  back the disk as it was then, not compressed.
- **Space is only won once earlier copies are gone.** Snapshots, templates and
  duplicates made before share their space with the disk as it was. They keep
  all of it when the disk is written out anew, so delete the ones you no longer
  need.
- Space that the guest frees is given back to your Mac, as before. On a disk
  that isn't APFS it is kept for the machine to use again.
- Copies, templates and snapshots made afterwards share space with the disk,
  as before.

Disk compression is unavailable for macOS machines.

## Disc and disk images

Disc images (ISO) and disk images (raw or ASIF) plug into a machine as USB
drives, also while it runs. Windows guests support ISO and raw images;
ASIF images require a macOS or Linux guest.

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
[templates](templates.md), and [snapshots](snapshots.md) use APFS clones to
share unchanged disk blocks. Copies across volumes or on other file systems
are full copies.

A machine that [moves to another disk](virtual-machines.md#where-machines-are-kept)
takes its snapshots along. They are copied in full then, since two disks can't
share anything.
