# Automation

`swiftvm` can work inside a running guest: run commands in it, copy files, see
its screen, and use its mouse and keyboard. It is made for scripts and for AI
agents, which get a machine of their own to work in instead of your Mac.

All of it goes through the [guest tools](guest-tools.md), over the machine's
own socket device. The guest needs no network and no SSH key for it.

## Getting ready

```bash
swiftvm start desk
swiftvm wait desk               # until the guest tools answer
swiftvm info desk               # the Automation line says what they do
```

Guest tools that came with an older SwiftVM do none of this.
`swiftvm install-tools <machine>` updates them. A Linux guest needs Python 3.9
or newer for it, which every system SwiftVM sets up has.

## What works where

| | Linux | macOS |
| --- | --- | --- |
| `exec`, `cp` | Yes | Yes |
| `screenshot` | Any desktop, the login screen, and the console | Once someone is logged in, and [macOS allows it](#macos-guests) |
| `ui` mouse and keyboard | The same | The same |
| `ui tree`, `press`, `set`, `focus` | A desktop that someone is logged in to | The same |

## Commands

```bash
swiftvm exec desk -- uname -a
swiftvm exec desk --root -- apt-get install -y nginx
swiftvm exec desk -- sh -c 'cd project && make test'
swiftvm exec desk -- sh -s < setup.sh
```

| Option | What it does |
| --- | --- |
| `--root` | Run the command as root |
| `--user <name>` | Run it as another account |
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
  To leave something running, start it in the background:
  `swiftvm exec desk -- sh -c 'firefox > /dev/null 2>&1 &'`.
- A command that runs as the user who is logged in at the guest's screen can
  open windows there.

`swiftvm exec` ends with the command's own exit status, so a script can go by
it.

| Status | Meaning |
| --- | --- |
| 124 | The time given with `--timeout` was up |
| 125 | The command never ran: the machine is down, has no guest tools, or automation is off |
| 126, 127 | The command couldn't be run, or isn't there |

## Files

```bash
swiftvm cp notes.txt desk:Documents/           # into the guest
swiftvm cp desk:/var/log/syslog ./syslog.txt   # out of it
swiftvm cp ./project desk:/srv                 # a folder, with everything in it
swiftvm cp ./project/. desk:/srv/app           # only what is in the folder
swiftvm cp --root nginx.conf desk:/etc/nginx/nginx.conf
```

- The side in the guest is `<machine>:<path>`. A path that doesn't start with
  `/` is in the account's home folder.
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

- In a Linux guest the mouse pointer isn't in the picture.
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
- In a Linux guest, `type` presses the keys of a US keyboard. A guest set to
  another layout gets other characters, and text beyond those keys isn't
  typed: put it into a text field with [`ui set`](#what-is-on-the-screen).
  A macOS guest takes any text.
- Linux guests take all of this at the login screen too, so a script can sign
  in.

## What is on the screen

A screenshot shows the screen. The tree says what is on it: every window,
button, and text field that applications describe to the system's
accessibility, the way a screen reader gets to know them.

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
| `id` | What the part is asked for by |
| `role`, `name`, `description`, `value` | What kind of thing it is, what it is called, and what is in it |
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

macOS asks whoever sits at the screen before a program may record it, or use
its mouse and keyboard. Nothing can say yes for you, so each macOS guest needs
this once:

1. Log in at the guest's screen.
2. Run `swiftvm screenshot <machine>` and `swiftvm ui <machine> tree`. Both
   fail the first time, and macOS puts its question on the guest's screen.
3. In the guest, open **System Settings › Privacy & Security**. Turn on
   **swiftvm-agent** under **Screen & System Audio Recording**, and under
   **Accessibility**.
4. Run the commands again.

A copy of the machine keeps what you allowed. `exec` and `cp` need none of it.

## Turning it off

Automation is on for every machine that has the guest tools. For a machine
that nothing but you should touch, turn off **Allow Automation** in its
settings, or run:

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
   than by its place.
3. Act: `press` a part by its `id`, or `click` where the screenshot shows it,
   and `type`.
4. Take another screenshot to see what happened.

`exec` and `cp` are quicker and surer than the screen for anything a command
can do. A [snapshot](snapshots.md) before a risky step lets you go back.
