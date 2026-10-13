# Automation

`swiftvm` can work inside a running guest: run commands in it, copy files, see
its screen, and use its mouse and keyboard. It is made for scripts and for AI
agents, which get a machine of their own to work in instead of your Mac.

Most of it goes through the [guest tools](guest-tools.md), over the machine's
own socket device. The guest needs no network and no SSH key for it. The
screen, the mouse, and the keyboard of a macOS guest are the machine's own:
SwiftVM reads the display and presses the keys itself, and the guest isn't
asked.

## Getting ready

```bash
swiftvm start desk
swiftvm wait desk               # until the guest tools answer
swiftvm info desk               # the Automation line says what works
swiftvm allow-accessibility desk --password '…'   # a macOS guest, once: for ui tree
```

Guest tools that came with an older SwiftVM do none of this.
`swiftvm install-tools <machine>` updates them. A Linux guest needs Python 3.9
or newer for it, which every system SwiftVM sets up has.

## What works where

| | Linux | macOS |
| --- | --- | --- |
| `exec`, `cp` | With the guest tools | With the guest tools |
| `screenshot` | With the guest tools: any desktop, the login screen, and the console | Always: whatever the display shows, also the login screen and a locked screen |
| `ui` mouse and keyboard | The same | The same |
| `ui tree`, `press`, `set`, `focus` | A desktop that someone is logged in to | The same, once [macOS allows it](#macos-guests) |

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

- The mouse pointer isn't in the picture.
- A desktop turns the display off after a while without input, and locks the
  screen. A screenshot then says that the display is off: wake it with
  `swiftvm ui <machine> key shift`, and look again before you type.
- A macOS guest's screen can be looked at, clicked on, and typed into in any
  state: without the guest tools, before anyone is logged in, while it is
  locked.

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
- Text beyond those keys isn't typed in a Linux guest: put it into a text
  field with [`ui set`](#what-is-on-the-screen). In a macOS guest the guest
  tools type it, once [macOS allows it](#macos-guests).
- All of this works at the login screen too, so a script can sign in.
- `scroll` goes the way it says in a macOS guest, whichever way the guest is
  set to scroll. Without the guest tools it takes the guest to scroll the way
  macOS comes: **Natural scrolling** on.

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

`screenshot`, and the mouse and keyboard of `ui`, need nothing in the guest:
no guest tools, no login, and nothing allowed.

The tree is different. macOS asks whoever sits at the screen before a program
may read what others show there, and the guest tools are such a program. Each
macOS guest has to allow it once:

```bash
swiftvm allow-accessibility desk --password 'the account password'
```

SwiftVM gives the answer the way a person at the guest's screen would, with
the machine's own mouse and keyboard. It opens System Settings in the guest,
turns on the switch for **swiftvm-agent**, and types the password where macOS
asks for it. Then it closes System Settings again.

- It takes a few seconds. The first time, reading the guest's screen can take
  half a minute.
- Someone has to be logged in at the guest's screen, and the password has to
  be that of an administrator there. An account that SwiftVM created is one.
- Leave the guest's mouse and keyboard alone while it runs.
- The guest tools have to be version 1.2 or newer. `swiftvm info <machine>`
  shows the version, and `swiftvm install-tools <machine>` updates them.
- The password is typed on the machine's keyboard, so it has to be made of
  what a US keyboard has keys for.
- A machine that is already allowed is left as it is.

To do it by hand instead, open **System Settings › Privacy & Security › Device
Control and Data Access** in the guest, which earlier versions call
**Accessibility**, and turn on **swiftvm-agent**.

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
   than by its place. A macOS guest [has to allow](#macos-guests) that first,
   with `swiftvm allow-accessibility`. The screenshot and the clicks work
   without.
3. Act: `press` a part by its `id`, or `click` where the screenshot shows it,
   and `type`.
4. Take another screenshot to see what happened.

`exec` and `cp` are quicker and surer than the screen for anything a command
can do. A [snapshot](snapshots.md) before a risky step lets you go back.
