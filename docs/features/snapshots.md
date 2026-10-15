# Snapshots

A snapshot keeps a machine exactly as it is, so you can come back to it later:
before an upgrade, or before trying something risky.

## Taking one

Choose **Take Snapshot** in the **Virtual Machine** menu (`Cmd+Shift+S`), or
open **Snapshots…** in the machine's menu to name it first.

```bash
swiftvm snapshot web-server "Before upgrade"
swiftvm snapshots web-server
```

- A machine that is shut down is saved as it is on disk.
- A running machine pauses for a moment and comes back exactly where it was.
  Its memory is part of the snapshot.

## Going back

**Revert…** puts the machine back as it was when the snapshot was taken.

```bash
swiftvm revert web-server "Before upgrade"
swiftvm start web-server
```

- Everything that happened in the machine since is lost. Take another snapshot
  first if you want to keep it.
- `swiftvm revert` leaves the machine stopped, or suspended if the snapshot
  includes memory. `swiftvm start` then boots or resumes it. Reverting in the
  app restarts it automatically if it was running or paused before the revert.
- Resuming a snapshot that includes memory restores the programs that were
  running when it was taken.

## Renaming and deleting

```bash
swiftvm rename-snapshot web-server "Before upgrade" "Before 2.0"
swiftvm delete-snapshot web-server "Before 2.0"
```

Deleting a snapshot doesn't change the machine or its other snapshots.

## Good to know

- On APFS, snapshots share unchanged disk blocks with the machine. On another
  file system they are full copies.
- A snapshot of a running machine also keeps its memory, which can take
  several gigabytes.
- A snapshot covers the machine's own disk, not the
  [disk images](disks.md#disc-and-disk-images) attached to it.
- A running machine can't be snapshotted while it has a writable disk image or
  a [USB device](usb-devices.md) attached, or while your Mac is locked. Eject
  or detach it, or shut the machine down first.
- A suspended machine with a writable disk image also cannot be snapshotted.
  Resume it to eject the image, or shut it down first.
- A snapshot takes its own machine back. To make new machines from a state,
  save a [template](templates.md). A snapshot that was taken while the machine
  was shut down can [become one](templates.md#from-a-snapshot).
- After going back, the guest's clock is behind. The
  [guest tools](guest-tools.md) synchronize it after reconnecting.
