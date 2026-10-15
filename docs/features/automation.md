# Automation

Use `swiftvm` to run commands, copy files, take screenshots, and control a
guest's mouse and keyboard. These commands work for scripts and AI agents
without a guest network connection or SSH key.

## Getting ready

```bash
swiftvm start desk
swiftvm wait desk               # until the guest tools answer
swiftvm info desk               # the Automation line says what works
swiftvm allow-accessibility desk --password '…'   # a macOS guest, once: for ui tree
```

If a command needs newer [guest tools](guest-tools.md), update them with
`swiftvm install-tools <machine>` on Linux or macOS, or use the
[guest tools disc](guest-tools.md#windows) on Windows. Linux automation
requires Python 3.9 or newer, included in every Quick Create image.

`wait` only waits for the guest tools to connect. It does not wait for setup
scripts, Windows installation, or a desktop login to finish. Check
`swiftvm info <machine>` for setup progress.

## What works where

| Command | Linux | macOS | Windows |
| --- | --- | --- | --- |
| `exec`, `cp` | Guest tools | Guest tools | Guest tools |
| `screenshot`, `ui` mouse and keyboard | Guest tools; works at the login screen and console | Works without guest tools, including login and locked screens | Works without guest tools, including the sign-in screen |
| `ui tree`, `press`, `set`, `focus` | Guest tools and a logged-in desktop session | Guest tools, a logged-in session, and [permission](#macos-guests) | Unavailable |

## Commands

```bash
swiftvm exec desk -- uname -a
swiftvm exec desk --root -- apt-get install -y nginx
swiftvm exec desk -- sh -c 'cd project && make test'
swiftvm exec desk -- sh -s < setup.sh
```

| Option | What it does |
| --- | --- |
| `--root` | Run as root, or SYSTEM on Windows |
| `--user <name>` | Run as this account; on Windows, it must be the account logged in at the guest's screen |
| `--cwd <folder>` | Where to run it. Otherwise the account's home folder |
| `--env <name>=<value>` | Add a variable to its environment. Give it again for more |
| `--timeout <seconds>` | Stop the command if it takes longer |

- Without `--root` or `--user`, the command runs as the machine's own account:
  its [SSH user](ssh.md), or whoever is logged in at its screen.
- No shell reads the command. For pipes, `&&`, and the like, run
  `sh -c '…'`.
- What you pipe into `swiftvm exec` is the command's input. It has no
  terminal: for something you type into, use [`swiftvm ssh`](ssh.md).
- Output arrives as the command prints it, byte for byte.
- A command stops when `swiftvm` does: at Control-C, or when the time is up.
  On Linux and macOS, you can leave a program running in the background:
  `swiftvm exec desk -- sh -c 'firefox > /dev/null 2>&1 &'`.
- A command that runs as the user who is logged in at the guest's screen can
  open windows there.

`swiftvm exec` ends with the command's own exit status, so a script can go by
it.

On Windows, the configured account must be logged in unless you use `--root`.
For shell commands, use `powershell.exe -Command '…'`.

| Status | Meaning |
| --- | --- |
| 124 | The time given with `--timeout` was up |
| 125 | The command never ran: the machine is down, has no guest tools, or automation is off |
| 126, 127 | The command couldn't be run, or isn't there |

## Files

```bash
swiftvm cp notes.txt desk:Documents/           # into the guest
swiftvm cp desk:/var/log/syslog ./syslog.txt   # out of it
swiftvm cp --root ./project desk:/srv          # a folder, with everything in it
swiftvm cp --root ./project/. desk:/srv/app    # only what is in the folder
swiftvm cp --root nginx.conf desk:/etc/nginx/nginx.conf
```

- The side in the guest is `<machine>:<path>`. Relative paths start in the
  account's home folder. Windows also accepts drive paths, for example
  `swiftvm cp notes.txt win:C:/Users/user/Documents/`.
- It works as `cp -R` does: into a folder that is there, under the name you
  give otherwise.
- Files arrive as the account that `--root` or `--user` names, as with `exec`.
- The guest needs `tar`, which every supported system has.

## The screen

```bash
swiftvm screenshot desk shot.png
swiftvm screenshot desk -        # to standard output
```

Without a file name the picture goes to the current folder, and `swiftvm`
prints where.

- The mouse pointer isn't in the picture.
- A desktop turns the display off after a while without input, and locks the
  screen. A screenshot then says that the display is off: wake it with
  `swiftvm ui <machine> key shift`, and look again before you type.

## Mouse and keyboard

```bash
swiftvm ui desk click 640 400
swiftvm ui desk double-click 640 400
swiftvm ui desk right-click 640 400
swiftvm ui desk drag 200 300 600 300
swiftvm ui desk scroll 640 400 down 5
swiftvm ui desk type 'Hello, world'
swiftvm ui desk key Return
swiftvm ui desk key ctrl+c
```

- Places are in the pixels of a screenshot, from its top left corner.
- `key` takes one key or several held together, joined by `+`: `Return`,
  `Escape`, `Tab`, `space`, `BackSpace`, `Delete`, `Home`, `End`, `PageUp`,
  `PageDown`, the arrows `Up` `Down` `Left` `Right`, `F1` to `F12`, any single
  character, and `ctrl`, `shift`, `alt`, `super` to hold. `cmd` and `super`
  are one key. Several keys in one command are pressed one after the other.
- `type` presses the keys of a US keyboard. A guest set to another layout
  gets other characters.
- Linux and Windows input supports characters available on a US keyboard.
  For other text, use [`ui set`](#what-is-on-the-screen) on Linux, or `exec`
  and `cp` to work with files on Windows. On macOS, the guest tools can type
  other characters once [macOS allows it](#macos-guests).
- All of this works at the login screen too, so a script can sign in.
- `scroll` goes the way it says in a macOS guest, whichever way the guest is
  set to scroll. Without the guest tools it takes the guest to scroll the way
  macOS comes: **Natural scrolling** on.

## What is on the screen

The accessibility tree describes windows, buttons, and text fields that
applications expose to screen readers. Use it to find controls by name and
act on them by ID.

```bash
swiftvm ui desk tree
swiftvm ui desk tree --app files
```

```json
{"applications":[{"id":"10345","role":"application","name":"org.gnome.Nautilus","children":[
  {"id":"10345/0","role":"frame","name":"Home","states":["active"],"children":[
    {"id":"10345/0/0/1/2","role":"button","name":"Close","actions":["click"]}]}]}],
 "truncated":false}
```

| Field | What it is |
| --- | --- |
| `id` | Identifier used to act on the element |
| `role`, `name`, `description`, `value` | Element type, label, description, and contents |
| `states` | `focused`, `selected`, `checked`, `expanded`, `editable`, `disabled`, and the like |
| `actions` | What it can be asked to do |
| `bounds` | Where it is on the screen, in the pixels of a screenshot: left, top, width, height |

Act on a part by its `id`:

```bash
swiftvm ui desk press 10345/0/0/1/2
swiftvm ui desk press 10345/0 --action showMenu
swiftvm ui desk set 10345/0/3/1 'Any text, also ünïcödé'
swiftvm ui desk focus 10345/0/3/1
```

- Boxes that only hold other parts are left out. `--all` shows them, and every
  action a part has. `--depth <levels>` stops further up.
- An `id` is good until the window changes. Read the tree again after you
  acted.
- `bounds` are only there when the desktop knows them. On Wayland, which GNOME
  and KDE Plasma use, an application isn't told where its windows are: the
  desktop's own parts have `bounds`, an application's don't. Press those by
  `id`, or click where the screenshot shows them.
- Not every text field takes `set`, and not every part takes `focus`. The
  answer says so. Click on it and `type` instead.
- A Linux guest needs the packages `python3-gi` and `gir1.2-atspi-2.0` for the
  tree. The [desktops](linux-guests.md#desktops-and-setup-scripts) SwiftVM
  installs bring them.

## macOS guests

Screenshots and basic mouse and keyboard input work without guest tools or
permission in the guest. The accessibility tree requires permission for
**swiftvm-agent**. Grant it once per guest:

```bash
swiftvm allow-accessibility desk --password 'the account password'
```

The command opens System Settings in the guest and enables access using the
supplied administrator password.

- Log in to an administrator account at the guest's screen first. Accounts
  created by SwiftVM are administrators.
- Leave the guest's mouse and keyboard alone while it runs.
- Guest tools version 1.2 or newer is required. `swiftvm info <machine>` shows
  the installed version.
- The password is typed on the machine's keyboard, so it has to be made of
  what a US keyboard has keys for.

To do it by hand instead, open **System Settings › Privacy & Security › Device
Control and Data Access** in the guest, which earlier versions call
**Accessibility**, and turn on **swiftvm-agent**.

A copy of the machine keeps what you allowed. `exec` and `cp` need none of it.

## Turning it off

Automation is enabled by default. To disable it, turn off **Allow Automation**
in the machine's settings, or run:

```bash
swiftvm automation desk off
```

`exec`, `cp`, `screenshot`, and `ui` then say that automation is off, and do
nothing in the guest. A command that is already running isn't stopped: end
the `swiftvm` that started it.

## For AI agents

`swiftvm help` lists every command. The usual loop:

1. `swiftvm screenshot <machine> shot.png`, and look at it.
2. `swiftvm ui <machine> tree`, to find a part by name where that is easier
   than by its place. A macOS guest [has to allow](#macos-guests) that first,
   with `swiftvm allow-accessibility`. The screenshot and the clicks work
   without.
3. Act: `press` a part by its `id`, or `click` where the screenshot shows it,
   and `type`.
4. Take another screenshot to see what happened.

`exec` and `cp` are quicker and surer than the screen for anything a command
can do. A [snapshot](snapshots.md) before a risky step lets you go back.
