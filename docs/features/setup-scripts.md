# Setup Scripts

Setup scripts configure a Linux machine on its first start: install a desktop,
Docker, a web server, or your own tools. They run as root, in order, on
machines made with [Quick Create](linux-guests.md#quick-create).

## Adding them to a machine

Choose **Add…** next to **Setup Scripts** in **New Virtual Machine**. Select
scripts in the order you want them to run; select one again to remove it.
The list shows scripts compatible with your distribution and their minimum
memory and disk requirements. Use **Filter** to search by name, summary, or
category.

| Option | Use |
| --- | --- |
| Built-in scripts | Desktops, development tools, and system setup |
| **From your folder** | Scripts saved in [your scripts folder](#the-folder) |
| **New Script…** | Write and save a reusable script |
| **Choose File…** | Use a local file for this machine |
| **Open Scripts Folder** | Open your scripts in Finder |

From the command line:

```bash
swiftvm scripts                    # list built-in and local scripts
swiftvm scripts debian-13          # filter by distribution
swiftvm create debian-13 --script xfce --script docker --password 'a password'
swiftvm create debian-13 --script ./mine.sh
```

Repeat `--script` for each script, up to eight. Use a name from
`swiftvm scripts`, or a path containing `/`, such as `./mine.sh`.

### What happens

The machine starts as a server and runs the scripts after its initial setup.
SwiftVM shows the current script and step in the panel, the machine's window,
and `swiftvm info <machine>`. You can use the machine while setup runs.

- Scripts that download packages need internet access.
- If any script requests a restart, the machine restarts once after all succeed.
- If a script fails, later scripts wait. See [When a script fails](#when-a-script-fails).
- If the machine shuts down during setup, completed scripts stay done and
  the unfinished script runs again at the next start.
- Unless you choose hardware yourself, SwiftVM uses the largest memory and
  disk requirements among the selected scripts.
- Duplicates keep the installed software without running setup again.

## Built-in scripts

| Script | Name for `--script` | Systems | Minimum memory / disk |
| --- | --- | --- | --- |
| GNOME | `gnome` | All | 4 GB / 24 GB |
| KDE Plasma | `kde-plasma` | Ubuntu, Debian | 4 GB / 24 GB |
| Xfce | `xfce` | All | 2 GB / 16 GB |
| Cinnamon | `cinnamon` | All | 4 GB / 24 GB |
| Hyprland | `hyprland` | Arch Linux | 4 GB / 16 GB |
| Omarchy (ARM edge) | `omarchy` | Arch Linux | 8 GB / 64 GB |
| Docker | `docker` | All | 2 GB / 16 GB |
| Web Server | `web-server` | All | Default machine settings |
| Updates | `updates` | All | Default machine settings |

All is Ubuntu 26.04, Ubuntu 24.04, Debian 13, and Arch Linux ARM. On Arch
Linux, a script that installs packages brings the whole system up to date
with them, as Arch Linux expects. When that replaces the running kernel, the
machine restarts once setup is done, whether a script asks for it or not.

KDE Plasma isn't offered on Arch Linux ARM while its upstream Plasma packages
are only partly built. It remains available on Ubuntu and Debian.

## Desktops

A desktop needs an account password. Most desktops install packages on the first
start, taking about ten minutes. Omarchy downloads a ready-made desktop instead.
The machine restarts into its login screen when setup finishes.
Scripts selected after the desktop finish before that restart.

Desktop scripts install the desktop, a browser, and `spice-vdagent` for
[clipboard sharing](sharing.md#clipboard). They keep the machine's network and
SSH configuration, and turn off guest sleep. Use SwiftVM's power controls
instead; machines with graphics acceleration can pause, but not suspend to disk.

**Graphics acceleration** draws with the Mac's GPU. It is enabled by default
for new Omarchy machines when available, and recommended for Hyprland. Turn it
on before creating the machine, or pass `--gpu`. Use `--no-gpu` or `--rosetta`
to keep Apple's backend, with suspend support.
Without it, the processors draw every pixel, so a large Retina window can be
slow; Xfce is the lightest choice.

| | With graphics acceleration | Without |
| --- | --- | --- |
| Drawing | Mac's GPU | Machine's processors |
| Suspend | Pause only | Yes |
| Rosetta | No | Optional |
| OpenGL | ES 3.0 and 2.1; apps needing newer OpenGL, such as kitty, don't start | Full, in software |

In Hyprland and Omarchy:

- Super is the Command key. Command-Q opens a terminal (foot) in Hyprland;
  Command-Space opens the menu in Omarchy.
- The Hyprland setup turns animations, blur, and shadows off. Remove the
  `hl.config` block SwiftVM added to `~/.config/hypr/hyprland.lua` to turn them on.
  Omarchy keeps upstream's normal animations on a GPU-backed machine and its
  conservative VM settings without acceleration. Its Appearance menu controls
  animations and window opacity.
- The standalone Hyprland setup starts through `/usr/local/bin/Hyprland`.
  Without graphics acceleration, this makes it finish drawing each frame before
  showing it; otherwise closed windows and half-drawn areas stay on screen.
- Accelerated Omarchy supports opt-in [text clipboard sharing](sharing.md#clipboard)
  through the guest tools. Other Wayland desktops need `wl-clipboard` and
  data-control support. Without acceleration, sharing depends on `spice-vdagent`
  and the desktop. If the display goes dark, click in the window or press a key.

### Omarchy

The built-in `omarchy` setup uses a ready-made [Omarchy](https://omarchy.org)
ARM edge image, following [Try Omarchy's](https://github.com/omacom/try-omarchy)
prebuilt-image approach. The desktop and applications are installed once when
the image is built, rather than compiled inside every new machine. First boot
creates your account, configures the virtual hardware, and installs SwiftVM's
guest tools.

- **Needs** 8 GB of memory and a 64 GB disk. The image download needs internet;
  its verified pieces are cached and interrupted downloads can resume.
- **Upstream ARM edge** supplies Omarchy, its kernel, settings, and applications.
  ARM support is on the edge channel, so expect changes and occasional upstream
  regressions. Not every x86 application is available for ARM.
- **New machines** resolve the newest published compatible image, not a version
  pinned to the app. Images refresh monthly; each download still uses immutable
  URLs and verifies every piece and the assembled image. If GitHub is unreachable,
  a previously resolved image can be used only if it is already downloaded.
- **Updates** inside existing machines use Omarchy's upstream repositories and
  commands. Refreshing the installation image does not change existing machines.
- **Storage and boot** use Btrfs and Limine, as upstream does. NetworkManager
  manages the network; SSH is allowed through Omarchy's firewall.
- **Existing machines stay unchanged.** This image is used only when creating
  an Arch machine with the built-in Omarchy setup. A local script called
  `omarchy` still starts from plain Arch, and a second desktop can't be combined
  with the ready-made image.

```bash
swiftvm create arch --name Omarchy --script omarchy --password 'a password'
```

## Your own scripts

### The folder

Save scripts in `~/.config/swiftvm/setup-scripts`, or choose **Open Scripts
Folder** to create and open it. SwiftVM reads the folder each time you open
the script list.

```bash
mkdir -p ~/.config/swiftvm/setup-scripts
cp my-tools.sh ~/.config/swiftvm/setup-scripts/
swiftvm create debian-13 --script my-tools
```

A script's name for `--script` is its filename without the extension. A local
script with the same name as a built-in script replaces it. Hidden files,
editor backup files, and subfolders are skipped; the folder accepts up to
200 files. Invalid scripts are listed with an explanation.

### Writing one in the app

Choose **New Script…**, edit the starter script, and select **Save and Add**.
SwiftVM saves it in your scripts folder and adds it to the new machine. Use
a unique filename; hidden and backup-style names are rejected. To edit it
later, open the file in any text editor.

### A file, once

Choose **Choose File…** or pass a path to `--script` to use a script without
saving it in your scripts folder.

### Writing one

A script is a program with an optional comment header. For example:

```sh
#!/bin/sh
# name: Docker
# summary: Docker Engine for the machine's account
# category: development
# systems: ubuntu debian
# memory: 2
# disk: 16

set -eu

echo "==> Installing Docker"
apt-get update
apt-get install -y docker.io
usermod -aG docker "$SWIFTVM_USER"
```

### The header

Put `# key: value` lines immediately after the `#!` line, followed by a blank
line. All keys are optional; unknown keys are ignored.

| Key | Meaning |
| --- | --- |
| `name` | Display name; defaults to the filename |
| `summary` | One-line description |
| `category` | Group in the list, such as `development`; `desktop` requires an account password |
| `systems` | Supported families or releases, such as `ubuntu debian` or `ubuntu-26.04`; omitted means any |
| `memory`, `disk` | Minimum sizes in GB |
| `graphics` | `recommended` to prefer GPU acceleration when available; `optional` leaves the default off. An explicit user choice takes precedence |
| `restart` | `yes` to restart after all scripts succeed |

### How it runs

- Scripts run as root after first-boot setup, without an interactive terminal.
  Use noninteractive commands such as `apt-get install -y`, or
  `pacman -S --noconfirm` on Arch Linux.
- `systems: arch` is Arch Linux ARM, whose `/etc/os-release` calls it
  `archarm` (and `arch` in `ID_LIKE`).
- The `#!` line selects the interpreter; without one, SwiftVM uses `sh`.
  Python 3 is available in every Quick Create image.
- `SWIFTVM_USER` contains the account name. Output beginning with `==> ` is
  shown as the current step. A nonzero exit status marks the script as failed.
- Use `restart: yes` instead of restarting from the script itself. A script
  must reach its end to be marked complete.
- Make scripts safe to rerun: an interrupted or failed script starts from the
  beginning. The runner repairs interrupted package configuration first.
- Start background services with `systemctl`; background processes are stopped
  after setup ends.
- Each script may be up to 256 KB. Scripts remain in the guest and its
  first-boot data on your Mac, so keep passwords out of them.

## Examples

The built-in scripts are working examples you can copy into your scripts
folder:

- [Docker](../../Packages/SwiftVMKit/Sources/Installers/Resources/SetupScripts/docker.sh):
  install a package and add the account to its group.
- [Updates](../../Packages/SwiftVMKit/Sources/Installers/Resources/SetupScripts/updates.sh):
  update packages and request a restart.
- [Web Server](../../Packages/SwiftVMKit/Sources/Installers/Resources/SetupScripts/web-server.sh):
  configure nginx to serve `/srv/site`.
- [Xfce](../../Packages/SwiftVMKit/Sources/Installers/Resources/SetupScripts/xfce.sh):
  install and configure a desktop.

For example, create a web server and open it from your Mac:

```bash
swiftvm create debian-13 --name Web --script web-server
# Wait for setup to finish; swiftvm info web shows progress.
open "http://$(swiftvm ip web)"
```

For a custom desktop, keep the network card managed by systemd-networkd and
set `category: desktop` and `restart: yes` in the header.

## When a script fails

SwiftVM shows the failed script and step. Later scripts wait and the machine
doesn't restart. In the guest:

| Task | Command or location |
| --- | --- |
| Read output | `/var/log/swiftvm-setup.log` |
| Retry | `sudo systemctl start swiftvm-setup` |
| Find the scripts | `/usr/local/lib/swiftvm/setup/scripts`, numbered in run order |

Retrying starts with the failed script and skips completed scripts. After
three interrupted starts, automatic retries stop; use the retry command to
continue. Progress reporting requires the [guest tools](guest-tools.md),
which Quick Create installs automatically.
