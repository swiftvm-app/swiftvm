# Linux Guests

There are two ways to create a Linux machine: **Quick Create**, from a
ready-made image, and **Installer Disc**, from an ISO.

Guests must be built for ARM64 (also called aarch64). [Rosetta](#rosetta) runs
x86-64 programs inside them.

## Simple and Advanced

The **New Virtual Machine** window asks as much as you want it to.

| | What it asks |
| --- | --- |
| **Simple** | A distribution, [setup scripts](#desktops-and-setup-scripts), and a password. SwiftVM decides the rest and shows what it decided |
| **Advanced** | Everything: Quick Create or an installer disc, the name, hardware, [where the machine is kept](virtual-machines.md#where-machines-are-kept), and the account |

The window opens on the one you used last. What you pick on one side is still
picked when you switch to the other.

## Quick Create

Quick Create downloads a server image and sets it up on first start. There is
no installer to click through, and the machine is ready in seconds once the
image is on your Mac.

| Distribution | Name for `swiftvm create` |
| --- | --- |
| Ubuntu 26.04 LTS | `ubuntu-26.04` |
| Ubuntu 24.04 LTS | `ubuntu-24.04` |
| Debian 13 | `debian-13` |

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

Images are checked against the checksums their distribution publishes.

```bash
swiftvm create ubuntu-26.04 --name "Web Server" --cpus 2 --memory 4 --disk 32
```

## Desktops and setup scripts

A Quick Create machine can install a desktop by itself the first time it
starts: GNOME, KDE Plasma, Xfce, or Cinnamon. Choose **Add…** next to **Setup
Scripts**, click one, and set a password.

```bash
swiftvm create ubuntu-26.04 --script xfce --password 'a password'
```

The machine starts as a server, installs the desktop in about ten minutes, and
restarts into its login screen. SwiftVM shows the step it is at.

A desktop is one kind of [setup script](setup-scripts.md), and a machine can
have several: a desktop and then Docker, say. Write your own for anything
else, and keep them in `~/.config/swiftvm/setup-scripts` to have them in the
list.

## Installer Disc

Use an installer disc for other distributions, or for a distribution's own
desktop edition. It is under **Advanced**. Pick one of the offered downloads,
choose **Choose ISO File…**, or drop an ISO on the **New Virtual Machine**
window. The machine starts from the disc, and you install as you would on a
real computer.

SwiftVM doesn't set these guests up, so afterwards you may want to:

- Install the [guest tools](guest-tools.md#installing).
- Install an SSH server and add your key. See [SSH](ssh.md).

## Rosetta

With Rosetta, x86-64 Linux programs run in an ARM64 guest. Turn it on when you
create a Quick Create machine, or later with **Rosetta for x86-64 Programs**
in the machine's settings. It needs Rosetta installed on your Mac.

## Secure Boot

**Secure Boot**, in the machine's settings, only starts systems signed with
Microsoft's UEFI keys, which most major distributions are. It is off by
default.

## Serial console

The serial console reaches a Linux guest when its network or display isn't
there.

- Choose **Open Serial Console** in the machine's menu, or run
  `swiftvm console <machine>`. Press `Ctrl+]` to leave.
- What the guest printed since it last started is in `logs/console.log` in the
  machine's [package](../user-guide/settings.md#files).
- Quick Create machines also send their kernel's messages there, from their
  second start on. Ubuntu only lets errors through once it is up; Debian shows
  everything.

## Good to know

- Linux guests draw without graphics acceleration. Of the desktops, Xfce is the
  quickest.
- The shared clipboard works in desktop guests that run `spice-vdagent`, which
  the [desktops](#desktops-and-setup-scripts) SwiftVM installs bring.
- SSH [without a network](ssh.md#without-a-network) works out of the box on
  Ubuntu 26.04 and Debian 13. Ubuntu 24.04 needs the guest tools for it.
- `swiftvm` can [run commands in the guest, see its screen, and use its mouse
  and keyboard](automation.md), from the login screen on.
