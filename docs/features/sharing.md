# Shared Folders and Clipboard

## Shared folders

A shared folder is a folder of your Mac that the guest can open.

Add one under **Shared Folders** in the machine's toolbar, in its settings, or
with:

```bash
swiftvm share web-server ~/Projects
swiftvm share web-server ~/Reference --read-only
swiftvm unshare web-server ~/Projects
```

Folders can be added and removed while the machine runs.

| Guest | Where folders appear |
| --- | --- |
| macOS | **My Shared Files** in the Finder sidebar, at `/Volumes/My Shared Files` |
| Linux | `/mnt/shared`, one folder each |
| Windows | Drive **Z:**, one folder each, with the [guest tools](guest-tools.md) |

Windows shared folders require a connection to SwiftVM's virtual network.
See [Windows guests](windows-guests.md#shared-folders).

### Linux guests you installed yourself

Guests that SwiftVM didn't set up don't mount shared folders by themselves.
Install the [guest tools](guest-tools.md) and they are mounted whenever the
machine runs.

Without the guest tools, mount them in the guest:

```bash
sudo mkdir -p /mnt/shared && sudo mount -t virtiofs swiftvm /mnt/shared
```

To mount them at every start, also run this once:

```bash
echo 'swiftvm /mnt/shared virtiofs rw,nofail 0 0' | sudo tee -a /etc/fstab
```

## Clipboard

Text you copy on your Mac can be pasted in the guest, and the other way round.

| Guest | Needs |
| --- | --- |
| macOS | The [guest tools](guest-tools.md) |
| Linux | A desktop that runs `spice-vdagent` |
| Windows | The [guest tools](guest-tools.md) |

- SwiftVM's macOS and Windows guest tools share text, up to about 250 kB.
  Linux clipboard support depends on `spice-vdagent` and the desktop session.
- In macOS and Windows guests, the clipboard follows the account logged in
  at the guest's screen.
- Turn it off for a guest that shouldn't see what you copy: **Share
  Clipboard** in the machine's settings, or
  `swiftvm share-clipboard <machine> off`.
- Shut down a Linux machine before changing **Share Clipboard**. On macOS
  and Windows, it can be changed while the machine runs.
