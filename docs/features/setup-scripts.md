# Setup Scripts

A setup script sets a new Linux machine up the first time it starts. It can
install a desktop, Docker, your tools: anything a program can do as root. A
machine can have several, which run one after the other.

SwiftVM brings [templates](#templates): the desktops, Docker, a web server,
and updates. You can [add your own](#your-own-scripts).

Setup scripts are for machines made with
[Quick Create](linux-guests.md#quick-create).

## Adding them to a machine

In the **New Virtual Machine** window, choose **Add…** next to **Setup
Scripts**. Click the ones you want, anywhere on their row. They run in the
order you click them: the number in a script's box says when its turn is.
Click a script again to take it out. Each one you add gets a row in the form,
where you can take it out too.

Type in **Filter** to narrow the list. It looks for every word you type in a
script's name, in what it says about itself, and in its kind: `desktop`,
`nginx`, `docker`. Escape empties the filter.

| In the list | What it is |
| --- | --- |
| The templates | What SwiftVM brings, by kind |
| Your scripts | The files in [your folder](#the-folder), marked **From your folder** |
| **New Script…** | [Write one](#writing-one-in-the-app) on the spot. It is saved in your folder |
| **Choose File…** | A file for this machine only |
| **Open Scripts Folder** | Your folder, in the Finder |

Only scripts written for the distribution you chose are listed. On the right
of a row is the least memory and disk the script asks for.

On the command line:

```bash
swiftvm scripts                    # every script: SwiftVM's and yours
swiftvm scripts debian-13          # those written for one system
swiftvm create ubuntu-26.04 --script kde-plasma --password 'a password'
swiftvm create debian-13 --script xfce --script docker --password 'a password'
swiftvm create debian-13 --script ./mine.sh       # a file, by its path
```

`--script` takes a name from the list, or a file. What has a `/` in it is a
file: write `./mine.sh` for one in the current folder. Give `--script` again
for each further script. A machine takes up to 8.

### What happens

1. The machine starts as a server, as every Quick Create machine does.
2. The scripts run in their order. They need the internet for what they
   download.
3. If one of them asks for it, the machine restarts once, after the last one.

Meanwhile the panel, the machine's window, and `swiftvm info <machine>` say
which script is running and the step it is at. The machine can be used while
they run.

- If one fails, those after it wait. See [when a script fails](#when-a-script-fails).
- If the machine is shut down halfway, the scripts that were through stay
  done. The one that was cut short starts again the next time the machine
  starts.
- The machine gets the memory and disk that the most demanding script asks
  for, unless you set them yourself.
- The copy of a machine keeps what its scripts set up. Nothing runs again.

## Templates

| Template | Name for `--script` | Kind | Needs at least |
| --- | --- | --- | --- |
| GNOME | `gnome` | Desktop | 4 GB memory, 24 GB disk |
| KDE Plasma | `kde-plasma` | Desktop | 4 GB memory, 24 GB disk |
| Xfce | `xfce` | Desktop | 2 GB memory, 16 GB disk |
| Cinnamon | `cinnamon` | Desktop | 4 GB memory, 24 GB disk |
| Docker | `docker` | Development | 2 GB memory, 16 GB disk |
| Web Server | `web-server` | Server | |
| Updates | `updates` | System | |

Each one works on Ubuntu 26.04, Ubuntu 24.04, and Debian 13. The last three
are short, and shown in full under [Examples](#examples).

## Desktops

Installing a desktop takes about ten minutes, and the machine restarts into
the desktop's login screen. Scripts you add after a desktop run before that
restart.

A desktop needs a password: you type it at the login screen.

### What you get

- The desktop from the distribution's own packages, with its login screen.
- Firefox.
- The same network as before, which the desktop shows as connected. The
  machine keeps its address and its [SSH name](ssh.md).
- `spice-vdagent`, for the [shared clipboard](sharing.md#clipboard).
- A system that doesn't go to sleep by itself. Suspend it from your Mac.

### Good to know

- Linux guests draw without graphics acceleration. Xfce is the quickest of the
  four; GNOME and KDE Plasma want more processors and memory.
- The shared clipboard doesn't work in every Wayland session. If it matters,
  pick an X11 session at the login screen, or use Xfce or Cinnamon.
- The login screen goes dark after a few minutes without input. Click in the
  machine's window or press a key.
- The desktop's network settings show the connection but can't change it: the
  system's own network service keeps it, as in a machine without a desktop.

## Your own scripts

### The folder

Put a script in `~/.config/swiftvm/setup-scripts` and it is in the list from
then on:

```bash
mkdir -p ~/.config/swiftvm/setup-scripts
cp docker.sh ~/.config/swiftvm/setup-scripts/
swiftvm create debian-13 --script docker
```

In the app, **Open Scripts Folder** in the list of scripts makes the folder and
shows it in the Finder.

- Every file in the folder is a script, whatever its name ends in. It goes by
  its file name without the ending: `docker.sh` is `docker`.
- The folder is read whenever the list is shown. There is nothing to reload.
- A script with the name of one of SwiftVM's templates takes its place. Save
  your own `xfce.sh` and **Xfce** installs yours.
- Hidden files and folders inside it are passed over, and so is what an
  editor keeps next to a file it has open (`name~`, `#name#`). So is
  everything after the first 200 files.
- `swiftvm scripts` and the list in the app say which files in the folder
  can't be taken for a script, and why.

### Writing one in the app

**New Script…** in the list of scripts opens an editor with a script to start
from. Give it a name and choose **Save and Add**: it is saved under that name
in your folder, and added to the machine you are creating. The name is what
the script goes by, unless you give it another with `# name:` in its header. A
name that is taken, by one of your scripts or by a template, is turned down.
To change the script later, open the file in the folder with any editor.

### A file, once

To use a script for one machine without keeping it, choose **Choose File…** in
the list of scripts, or give its path to `--script`.

### Writing one

A setup script is one file: a program, with a few comment lines at the top
that say what it is.

```sh
#!/bin/sh
# name: Docker
# summary: Docker Engine, for the account to use without sudo
# category: development
# systems: ubuntu debian
# memory: 2
# disk: 16

set -eu

echo "==> Installing Docker"
apt-get update
apt-get install -y docker.io

echo "==> Letting $SWIFTVM_USER use it"
usermod -aG docker "$SWIFTVM_USER"
```

### The header

The header is the comment lines at the top of the file, after the `#!` line.
Every line is `# key: value`. All of them are optional.

| Key | What it says |
| --- | --- |
| `name` | What the script sets up. Shown in the list and while it runs. Without it, the file's name is used |
| `summary` | One line about it, shown when the script is picked |
| `category` | The heading it is listed under, such as `development`. `desktop` also makes a password required |
| `systems` | The systems it is written for: `ubuntu`, `debian`, or one release such as `ubuntu-26.04`. Without it, any |
| `memory` | The least memory the machine needs, in GB |
| `disk` | The least disk size, in GB |
| `restart` | `yes` to restart the machine once the scripts have succeeded: after the last one, not after this one |

Keys that SwiftVM doesn't know are ignored. Leave an empty line after the
header: comments below it are only comments.

### How it runs

- Once, as root, after the system has finished its own first-boot setup and
  the network is up.
- In the language its `#!` line names. Python 3 is in every Quick Create
  image. Without that line it is run by `sh`.
- Without a terminal. Nobody can answer a question, so pass `-y` to `apt-get`
  and the like. `apt` waits for the system's own updates to finish instead of
  failing, and keeps a changed configuration file without asking.
- `SWIFTVM_USER` holds the name of the account that was created.
- A line that the script prints starting with `==> ` is the step SwiftVM shows.
  That goes for the programs it runs too: a package manager that prints such a
  line names a step.
- An exit status other than 0 means it failed.
- To restart afterwards, say `restart: yes` in the header. A script that
  restarts the machine itself never comes to its end, and is run again.
- A script that is run again starts from its beginning, so write it to cope
  with what its first run left. `apt-get install` does. Before a script that
  failed or was cut short runs again, SwiftVM lets the package manager finish
  what it was stopped at.
- What a script leaves running in the background is stopped once the last
  script has ended. Start services with `systemctl`.
- The scripts stay in the machine, readable by root, and in the machine's
  first-boot data on your Mac. Don't put passwords in them.
- A script is a file of 256 KB at most.

## Examples

Each of these runs as it is on Ubuntu 26.04, Ubuntu 24.04, and Debian 13. The
first three are templates that come with SwiftVM, as they are. To change one,
save it in [your folder](#the-folder) under another name.

### Docker

The script under [Writing one](#writing-one) is the **Docker** template.

### Updates, and a restart

The smallest useful script. `restart: yes` brings the machine up on the new
kernel when the updates are in.

```sh
#!/bin/sh
# name: Updates
# summary: The updates the system has waiting, and a restart into the new kernel
# category: system
# systems: ubuntu debian
# restart: yes

set -eu

echo "==> Getting the list of updates"
apt-get update

echo "==> Installing updates"
apt-get full-upgrade -y
```

### A web server

Writes a configuration file and starts a service. The page is in `/srv/site`,
which belongs to your account, so you can change it without `sudo`.

```sh
#!/bin/sh
# name: Web Server
# summary: nginx, serving the pages in /srv/site
# category: server
# systems: ubuntu debian

set -eu

echo "==> Installing nginx"
apt-get update
apt-get install -y nginx

echo "==> Setting up the site"
mkdir -p /srv/site
echo "<h1>Hello from $(hostname)</h1>" > /srv/site/index.html
chown -R "$SWIFTVM_USER" /srv/site
cat > /etc/nginx/sites-available/default << 'END'
server {
    listen 80 default_server;
    root /srv/site;
}
END
systemctl reload nginx
```

Then, on your Mac:

```bash
swiftvm create debian-13 --name Web --script web-server
open "http://$(swiftvm ip web)"
```

### In another language

A script is run by whatever its first line names. This one is Python. It
installs command-line tools for your account, not for root.

```python
#!/usr/bin/env python3
# name: Python Tools
# summary: pipx, and command-line tools installed with it for the account
# category: development
# systems: ubuntu debian

import os
import subprocess

user = os.environ["SWIFTVM_USER"]
tools = ["httpie", "ruff"]


def step(text):
    # Without flush, Python holds the line back and SwiftVM shows the step late.
    print(f"==> {text}", flush=True)


def run(*command):
    subprocess.run(command, check=True)


step("Installing pipx")
run("apt-get", "update")
run("apt-get", "install", "-y", "pipx")

for tool in tools:
    step(f"Installing {tool}")
    # As the account, so that the tool lands in its home folder and not in root's.
    run("su", "-", user, "-c", f"pipx install {tool}")
```

The header needs `#` comments. A language that writes comments another way can
still be a script: it goes by its file name, and runs on any system.

### A desktop of your own

SwiftVM's desktops are setup scripts like any other. They are in the
[source](https://github.com/swiftvm-app/swiftvm/tree/main/Packages/SwiftVMKit/Sources/Installers/Resources/SetupScripts),
one file each, and the best place to start from: save one in your folder under
another name and change it.

What each of them does, in order:

1. Picks the packages for the distribution it finds: the desktop, its login
   screen, a browser, `spice-vdagent`.
2. Downloads everything, then installs it. These are two steps, so that you can
   tell a slow download from a slow installation.
3. Says which login screen and which session to use, where more than one got
   installed.
4. Leaves the network card with the system's own network service, and lets the
   desktop's NetworkManager only watch it. Two services that both configure
   one card undo each other's work, and the machine would lose its address.
5. Turns off sleep in the guest. Your Mac suspends the machine.
6. Makes the system start into the login screen, and fails if none was
   installed.

Its header says `category: desktop`, which makes the password required, and
`restart: yes`, which brings the login screen up when the script is done.

## When a script fails

SwiftVM says so, with the script and the step it stopped at. The scripts after
it are not run, and the machine doesn't restart. In the guest:

| What | Where |
| --- | --- |
| Everything the scripts printed | `/var/log/swiftvm-setup.log` |
| Carry on | `sudo systemctl start swiftvm-setup` |
| The scripts themselves | `/usr/local/lib/swiftvm/setup/scripts`, by their number: `1`, `2`, … |

Carrying on runs the script that failed again, and then those after it. The
ones that were through are not run a second time.

A script that is cut short three times in a row, by the machine being turned
off under it, is not started again by itself.

Progress and failures are reported through the
[guest tools](guest-tools.md), which every Quick Create machine has.
