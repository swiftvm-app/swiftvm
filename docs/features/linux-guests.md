# Linux Guests

There are two ways to create a Linux machine: **Quick Create**, from a
ready-made image, and **Installer Disc**, from an ISO.

Guests must be built for ARM64 (also called aarch64). [Rosetta](#rosetta) runs
x86-64 programs inside them.

## Creating

Choose **Linux** in the **Type** dropdown. Pick **Quick Create** or
**Installer Disc** under **Setup**, then choose the image and name. Quick
Create also offers setup scripts and a password.

Use **Advanced** to adjust hardware, storage location, account, and startup
settings.

## Quick Create

Quick Create downloads a server image and sets it up on first start, without
an interactive installer. Account creation, guest tools, and any setup scripts
finish inside the running guest.

| Distribution | Name for `swiftvm create` |
| --- | --- |
| Ubuntu 26.04 LTS | `ubuntu-26.04` |
| Ubuntu 24.04 LTS | `ubuntu-24.04` |
| Debian 13 | `debian-13` |
| Arch Linux ARM | `arch` |

| Setting | What it is |
| --- | --- |
| Setup Scripts | **None** for a server. **Add…** picks [what to set the machine up with](#desktops-and-setup-scripts) on first start: a desktop, Docker, scripts of your own |
| User Name | The account to create. Defaults to your Mac user name |
| Password | For signing in on the console, and at a desktop's login screen. Optional for a server when your SSH key is installed |
| **Sign in over SSH with my key** | Installs your SSH key, so `ssh` works without a password |
| **Run x86-64 programs with Rosetta** | Shown when Rosetta is installed on your Mac |

A Quick Create machine comes with:

- Your account, which can use `sudo` without a password.
- The [guest tools](guest-tools.md).
- [Shared folders](sharing.md) mounted under `/mnt/shared`.
- A disk that [grows by itself](disks.md#growing-the-disk) after you resize it.
- A host name that matches its [SSH name](ssh.md).

Images are checked against the checksums their distribution publishes, or
against the checksum SwiftVM knows for them.

Arch Linux publishes no image for ARM64. The Arch Linux ARM image is built by
SwiftVM from [Arch Linux ARM](https://archlinuxarm.org)'s own root file
system, and brings itself up to date on first start when a setup script installs
anything. Its installer disc is [Archboot](https://archboot.com).

```bash
swiftvm create ubuntu-26.04 --name "Web Server" --cpus 2 --memory 4 --disk 32
```

## Desktops and setup scripts

A Quick Create machine can install a desktop by itself the first time it
starts: GNOME, Xfce, or Cinnamon; KDE Plasma on Ubuntu and Debian; and
Hyprland or [Omarchy](setup-scripts.md#omarchy) on Arch Linux. Choose **Add…**
next to **Setup Scripts**, click one, and set a password.

```bash
swiftvm create ubuntu-26.04 --script xfce --password 'a password'
```

The machine starts as a server, installs the desktop, and restarts into its
login screen. SwiftVM shows the step it is at; downloads can take a while.

A desktop is one kind of [setup script](setup-scripts.md), and a machine can
have several: a desktop and then Docker, say. Write your own for anything
else, and keep them in `~/.config/swiftvm/setup-scripts` to have them in the
list.

## Installer Disc

Use an installer disc for other distributions, or for a distribution's own
desktop edition. Choose **Installer Disc** under **Setup**. Pick an offered download,
choose **Choose ISO File…**, or drop an ISO on the **New Virtual Machine**
window. The machine starts from the disc, and you install as you would on a
real computer.

SwiftVM doesn't set these guests up, so afterwards you may want to:

- Install the [guest tools](guest-tools.md#installing).
- Install an SSH server and add your key. See [SSH](ssh.md).

## Graphics acceleration

**Graphics acceleration** is off by default for new Linux machines, in both
the creation window and `swiftvm create`. When enabled, the guest draws with
your Mac's GPU instead of drawing everything on its processors, making desktops
such as GNOME, Hyprland, or Omarchy smoother.
Existing machines and machines made from templates keep their graphics settings.

Turn it on before creating the machine, or pass `--gpu`, to use acceleration.
`--gpu` reports an error if this copy of SwiftVM was built without it and can't
be combined with `--rosetta`. Leave acceleration off, or pass `--no-gpu`, to
keep suspend and Rosetta support.

Apple's virtualization gives Linux no such GPU, so a machine with graphics
acceleration runs on QEMU, as Windows guests do. The guest's OpenGL goes
through virglrenderer to your Mac's GPU. That changes a few things:

- The machine can't be suspended, and has no memory snapshots: QEMU can't
  save and restore VirGL's GPU state. Pause works while SwiftVM stays open,
  but keeps the machine in memory. Snapshots while it is shut down work as usual.
- It has no Rosetta, and no Secure Boot. Apple's supported Rosetta integration
  requires its Virtualization backend, whose Linux graphics device has no 3D
  acceleration; sharing a directory through QEMU doesn't provide that integration.
- Each shared folder is a device of its own, mounted under
  `/mnt/shared/<name>` by the [guest tools](guest-tools.md). Folders shared
  while the machine runs appear after it restarts. On a Quick Create machine
  the account has your Mac user's ID, so that what it writes there is yours on
  the Mac.
- The clipboard isn't shared.
- The display follows the window at your Mac's full resolution: on a Retina
  display, twice its size in points at a scale of 2. GNOME and KDE Plasma
  follow it through `spice-vdagent`, and Hyprland through the guest tools.
- Programs get OpenGL ES 3.0 and OpenGL 2.1, translated to Metal. A program
  that needs a later desktop OpenGL doesn't start with it; started with
  `LIBGL_ALWAYS_SOFTWARE=1` it draws on the machine's processors instead.
- The guest tools talk to the app over a serial line instead of a socket
  device. `swiftvm ssh --vsock` goes through them, to the SSH server on port 22.
- USB devices can't be handed to it.

The option needs a copy of SwiftVM built with QEMU, which releases are. It is
chosen when the machine is created and stays with it.

## Rosetta

With Rosetta, x86-64 Linux programs run in an ARM64 guest. Enable it when
creating a Quick Create machine so first-boot setup mounts Rosetta and
registers it as a binary handler. Rosetta must be installed on your Mac.

You can expose Rosetta to an existing machine by shutting it down and enabling
**Rosetta for x86-64 Programs** in its settings. If it was not configured on
first boot, you also need to mount the `rosetta` share and register the binary
handler inside Linux; changing the setting alone does not perform those steps.

## Secure Boot

**Secure Boot**, in the machine's settings, only starts systems signed with
Microsoft's UEFI keys, which most major distributions are. It is off by
default.

## Serial console

The serial console reaches a Linux guest when its network or display isn't
there.

- Choose **Open Serial Console** in the machine's menu, or run
  `swiftvm console <machine>`. Press `Ctrl+]` to leave.
- Recent output is in `logs/console.log` in the machine's
  [package](../user-guide/settings.md#files). The log rotates at 4 MB and
  starts over on a fresh boot; resuming continues the existing log.
- Quick Create machines also send their kernel's messages there, from their
  second start on. Ubuntu only lets errors through once it is up; Debian shows
  everything. Arch Linux only lets serious errors through, from its first
  start on.

## Good to know

- Without [graphics acceleration](#graphics-acceleration), Linux guests draw
  on the machine's processors. Xfce is a lighter option than GNOME or KDE
  Plasma. Hyprland and Omarchy draw with OpenGL there too: give them four or
  more processors, or graphics acceleration.
- The shared clipboard works in desktop guests that run `spice-vdagent`, without
  [graphics acceleration](#graphics-acceleration), which
  the [desktops](#desktops-and-setup-scripts) SwiftVM installs bring.
- SSH [without a network](ssh.md#without-a-network) works out of the box on
  Ubuntu 26.04, Debian 13, and Arch Linux ARM. Ubuntu 24.04 needs the guest
  tools for it.
- `swiftvm` can [run commands in the guest, see its screen, and use its mouse
  and keyboard](automation.md), from the login screen on.
