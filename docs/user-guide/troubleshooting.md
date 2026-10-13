# Troubleshooting

Common problems and fixes. If yours isn't here, please
[open an issue](https://github.com/swiftvm-app/swiftvm/issues).

## Where to look

| What | Where |
| --- | --- |
| A machine's details | `swiftvm info <machine>` |
| A Linux guest's console output | `logs/console.log` in the machine's [package](settings.md#files) |
| Guest tools in a Linux guest | `systemctl status swiftvm-agent` in the guest |
| What a setup script printed | `/var/log/swiftvm-setup.log` in the guest |
| Guest tools in a macOS guest | `sudo launchctl print system/com.swiftvm.agent` in the guest |

Messages about a machine show in its window. When the window is closed, they
are at the top of the panel, and the menu bar item turns into a warning sign
until you have read them.

## `swiftvm` says SwiftVM isn't running

The command drives the running app. Open SwiftVM first.

## A machine is listed as Not Available

The machine is on a disk that isn't connected, or its package can't be read.
Point at it in the panel to see which, and where SwiftVM expects it.

- Connect the disk. The machine is back in the list by itself.
- If it says that this Mac doesn't let SwiftVM look at it, allow SwiftVM under
  **System Settings → Privacy & Security → Files and Folders**, then open the
  panel again.
- If you moved the package to another disk by hand, open it from the Finder.
- **Remove from List**, in the machine's **…**, takes it out of SwiftVM without
  touching its files.

## A macOS guest won't shut down

Without the [guest tools](../features/guest-tools.md), macOS asks on its own
screen before it shuts down. Confirm in the machine's window, or install the
guest tools to shut down without the question. **Force Stop** always works, but
the guest loses what it hasn't saved.

## A desktop didn't install

A desktop is installed by a [setup script](../features/setup-scripts.md), and
this goes for every setup script. SwiftVM says when one fails, and at which
step. The usual cause is a download that didn't come through.

- Read what the script printed: `/var/log/swiftvm-setup.log` in the guest.
- Run it again: `sudo systemctl start swiftvm-setup` in the guest. Scripts
  that were through before it are not run again.
- A machine that is still at a text login after a long while may have no
  internet. Check with `swiftvm info <machine>`, which shows the step the
  script is at.

## A suspended machine won't resume

- **Your Mac is locked.** macOS won't read saved memory while the screen is
  locked. Unlock and start the machine again.
- **A disk image is gone.** The machine expects the images it was suspended
  with. Put the image back, or choose **Discard Saved State** and start fresh.
- **An older Debian 13 machine.** Machines made from Debian's `genericcloud`
  image can't resume. In the guest, run `sudo apt install linux-image-arm64`,
  remove `linux-image-cloud-arm64`, and restart. New machines are fine.

## `ssh <machine>` doesn't work

- Plain `ssh` needs **Add machines to ~/.ssh/config** turned on in Settings.
  `swiftvm ssh <machine>` works without it.
- The machine must be running and have an address. Check with
  `swiftvm ip <machine>`.
- A guest installed from a disc may have no SSH server or no key of yours.
  Install one in the guest, and set **SSH User** in the machine's settings.
- If only the guest's network is down, try `swiftvm ssh <machine> --vsock`.

## A machine has an unexpected address

A machine created while others were running gets a temporary address. It takes
its own fixed address once every machine has been stopped and one is started
again.

## The virtual network couldn't be created

Another app may be using the same address range, or SwiftVM was force-quit
while a machine was running, which leaves the range blocked for a while.
SwiftVM moves to the next free range by itself; the machines get new addresses.

## Shared folders don't show up in a Linux guest

Guests that SwiftVM didn't set up don't mount shared folders by themselves.
Install the [guest tools](../features/guest-tools.md), or
[mount them by hand](../features/sharing.md#linux-guests-you-installed-yourself).

## The clipboard isn't shared

- Check **Share Clipboard** in the machine's settings.
- A macOS guest needs the [guest tools](../features/guest-tools.md).
- A Linux guest needs a desktop with `spice-vdagent` running.
- Only text is shared, up to about 250 kB.

## `swiftvm exec` or `swiftvm screenshot` doesn't work

- **The guest tools don't answer.** The guest is still starting up, or has no
  [guest tools](../features/guest-tools.md). `swiftvm wait <machine>` waits
  for them, and `swiftvm install-tools <machine>` installs them.
- **The guest tools are too old.** `swiftvm install-tools <machine>` updates
  them.
- **Automation is turned off.** Turn on **Allow Automation** in the machine's
  settings.
- **A macOS guest says it isn't allowed.** Allow it
  [in the guest](../features/automation.md#macos-guests), once.
- **Nobody is logged in.** The tree of what is on the screen, and everything
  about a macOS guest's screen, belongs to whoever is logged in there.

## The USB button is missing

USB devices need a build with a provisioning profile. Releases have one;
builds you make yourself may not. See
[Building](../tech/building.md#usb-devices).

## A USB device isn't listed

macOS decides which app uses a device. Open **Virtual Machine Accessories** in
the menu bar and set the device to SwiftVM. See
[USB devices](../features/usb-devices.md).

## A snapshot can't be taken

A running machine can't be snapshotted while it has a USB device or a writable
disk image attached, or while your Mac is locked. Detach or eject it, or shut
the machine down first.

## The guest doesn't see its bigger disk

Growing a disk only makes the hardware bigger. See
[what the guest has to do](../features/disks.md#growing-the-disk).

## The guest's clock is wrong after resuming

With the guest tools, the clock is set the moment the guest resumes. Without
them, macOS catches up in a few seconds and Linux can take much longer.

## A download started over

A download that was cut short carries on where it stopped. The part that has
arrived waits in the system's temporary folder, which macOS clears after three
days without use.

## Reporting a bug

Include your macOS version, the SwiftVM version, the guest system, steps to
reproduce, and the output of `swiftvm info <machine>`. For Linux guests, add
the relevant lines of `logs/console.log`.
