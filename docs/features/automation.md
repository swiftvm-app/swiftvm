# Automation

Use `swiftvm` to work a guest from scripts and AI agents, without a guest network
connection or SSH key. It works the same way on macOS, Linux, and Windows.

- **`swiftvm exec` and `swiftvm cp`** run commands and copy files. Use them for
  anything a command can do: they are the fastest and surest way.
- **[`swiftvm control`](#the-desktop)** sees and works the desktop, at login and
  lock screens too.
- **[`swiftvm mcp`](#mcp)** serves all of this to agents that take their tools
  from a server, and **[`swiftvm skill`](#for-ai-agents)** tells an agent how to
  use it.

## Getting ready

```bash
swiftvm create macos --name desk --password '…'   # or windows, or ubuntu-24.04 --script gnome
swiftvm wait desk               # until it is set up and ready
swiftvm control desk look
```

`wait` returns once the machine is ready: it has been created, its guest tools
answer, the setup it was created with is done, restarts included, and a desktop
that logs in by itself is logged in. That is the Windows installation, a Linux
machine's setup scripts, or a new macOS machine's guest tools and the
[permission](#macos-guests) below. A setup that failed is reported. Without
`--timeout`, it waits 300 seconds and then says what it is still waiting for; run
it again to wait on. `swiftvm info <machine>` shows setup progress meanwhile.

## What works where

| Command | Needs in the guest |
| --- | --- |
| `control`: the screen, mouse, keyboard, reading the screen's text | Nothing. It works on any system, at login screens, and without guest tools |
| `control`: knowing what is on the screen by its parts, `set`, `focus` | Guest tools and a logged-in desktop. macOS also needs [permission](#macos-guests) |
| `control`: `open`, `clipboard`, text the keyboard has no keys for | Guest tools |
| `exec`, `cp` | Guest tools |

If a command needs newer [guest tools](guest-tools.md), update them with
`swiftvm install-tools <machine>`. Linux automation requires Python 3.9 or newer,
included in every Quick Create image.

## The desktop

The app reads the machine's display and uses its mouse and keyboard from outside
the guest, so nothing there has to allow it. Where the guest tools can say what
is on the screen, it asks them: macOS's accessibility, AT-SPI on Linux, UI
Automation on Windows. It reads the pixels for whatever they can't tell, such as a
login screen or an application that draws itself. To you it is one list.

```bash
swiftvm control desk look
```

```text
desk · macOS 27.2 · screen 1280x800 (2x) · look 1
apps: TextEdit*, Dock
[25] window "Untitled" 118,56 603x505
 [26] textfield focused 118,156 586x382
 [27] group "Formatting" 118,88 603x36
  [28] checkbox "bold" 126,97 22x20
[49] menu "File" 116,0 42x30
```

- Each line has a number, a role, what it says, its states, an optional `#id`, and
  its left, top, width and height. A line is indented by what holds it. `--json`
  includes `"id"` when the application publishes a nonempty accessibility identifier.
- **Numbers stay with an element from look to look.** `--changes` says only what
  changed: `+` is new, `~` is different, `-` has gone.
- **There is one space.** The list, the picture from `--image`, and the places
  you click on all count in the `screen` that the first line gives. A display with
  more pixels than a model is shown says how many make one: `(2x)`.
- A look covers the application in front, marked `*`. `--app <name>` looks at
  another, and `--all` at every one.
- An `ocr` line was read off the pixels. It is acted on like any other.
- Applications on Wayland aren't told where they are, so they often have no place.
  They are pressed through the guest tools, and the pixels are read if a place is
  needed.

### Steps

Steps run in order, in one go, until one fails. Join them with `--then`:

```bash
swiftvm control desk click 26 --then type 'hello' --then key cmd+s --then look --changes
swiftvm control desk click 'Sign In' --then wait --text 'Welcome' --timeout 60
swiftvm control desk look --image=/tmp/screen.jpg
```

| Step | What it does |
| --- | --- |
| `look [--changes] [--image[=<file>]] [--region <x> <y> <w> <h>] [--app <name>] [--all] [--ocr]` | Says what is on the screen. `--image` also saves a JPEG and prints where; `--region` shows that part sharply, for reading only: its pixels aren't places |
| `wait [--text <text> \| --gone <text> \| --id <id> \| --id-gone <id>] [--timeout <seconds>]` | Waits until the text or exact id shows or goes, ending with 124 after 30 seconds. Without a condition, until the screen settles, for 10 seconds at most |
| `click <target> [--right \| --middle] [--double \| --count <n>]` | Clicks |
| `move <target>` | Moves the pointer |
| `drag <target> --to <target>` | Drags |
| `scroll [<target>] up\|down\|left\|right [<notches>]` | Scrolls |
| `type <text>` | Types at the keyboard focus |
| `key <key>...` | Presses keys one after the other |
| `set <number \| text \| #id> <text>` | Replaces what a text field holds, as a person would. `''` empties it |
| `focus <target>` | Gives it the keyboard |
| `open <application \| file \| URL>` | Opens it in the guest's session |
| `clipboard [<text>]` | Says what is on the guest's clipboard, or puts text there |
| `screenshot [<file> \| -]` | Saves the display as a PNG at its own full size |

`--json` prints everything in JSON. The status is 0 when all went well, 1 when a
step failed, 124 when a `wait` ran out of time, and 125 when it couldn't be asked.

### Targets

A target is a number from the last look, what something says, an accessibility id,
or a place:

```bash
swiftvm control desk click 12
swiftvm control desk click 'Sign In'
swiftvm control desk click '#settings-save'
swiftvm control desk click 640 400
```

- **A number is checked before it is used, and is never a click somewhere else.**
  One that moved is clicked where it is now. One that has gone, or that can't be told
  apart any more from others like it, such as the Delete button of a row when a row
  above it went away, is an error: look again.
- Text ignores case and goes by what is exactly said before what is partly said.
  If several things say it, nothing is done and their numbers are listed.
- `'#<id>'` matches the application's author-provided accessibility identifier
  exactly and case-sensitively, never text. No match fails with status 1; several
  matches fail and list their numbers. Quote the target so the shell doesn't take
  `#` for a comment. It works for every target, including both ends of a drag.
- Ids need current guest tools and an application that publishes them: `AXIdentifier`
  on macOS, AT-SPI `AccessibleId` on Linux, or UI Automation `AutomationId` on Windows.
  Older Linux providers without `AccessibleId` still work, but supply no ids.
  OCR cannot supply an id or locate an id-only target whose coordinates are unknown.
- `wait --id settings-save` waits for the id to appear; `--id-gone settings-save`
  waits for it to disappear. Pass the id without the `#` prefix. A failed or
  incomplete accessibility read cannot prove that an id has disappeared.
- Places are in the space of the look, from the top left corner of the screen.

### Keys and text

`key` takes one key or several held together, joined by `+`: `Return`, `Escape`,
`Tab`, `space`, `BackSpace`, `Delete`, `Home`, `End`, `PageUp`, `PageDown`, the
arrows `Up` `Down` `Left` `Right`, `F1` to `F12`, any single character, and `ctrl`,
`shift`, `alt`, `super` to hold. `cmd` and `super` are one key.

`type` presses the keys of a US keyboard. A guest set to another layout gets other
characters. Characters that keyboard has no keys for are typed by the guest tools.
On Linux that takes a field that tells the desktop it can be written in; if one
doesn't, put the text on the clipboard and paste. For long text, pasting is quicker
everywhere.

### What is worth knowing

- A display that went to sleep is woken by itself, with a key.
- A look just after an action waits for the screen to settle first, for a second
  at most. Nothing has to wait in between, and `sleep` is never needed.
- `wait` doesn't ask the guest while the screen is moving. It reads pixels until
  the screen rests. GNOME Shell can crash if its accessibility is read during its
  unlock animation.
- A locked Windows, or the question an elevation asks, is another desktop: those
  are read from the pixels, and the note in the look says so.
- Not every application exposes its parts. One that draws itself, such as a
  GPU-rendered one, shows as `ocr` lines.
- On a Linux desktop made some other way, the parts of the screen take the packages
  `python3-gi` and `gir1.2-atspi-2.0`, and `clipboard` takes `wl-clipboard` or
  `xclip`. The [desktops](linux-guests.md#desktops-and-setup-scripts) SwiftVM
  installs bring them.
- After a failure or a time-out, look before you repeat: the action may have happened.

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
| `--timeout <seconds>` | Bound connection setup, dispatch and result consumption with one deadline |
| `--result-fd <descriptor>` | Write one separate JSON completion line to an inherited writable descriptor greater than 2 |

- Without `--root` or `--user`, the command runs as the machine's own account:
  its [SSH user](ssh.md), or whoever is logged in at its screen.
- No shell reads the command. For pipes, `&&`, and the like, run
  `sh -c '…'`.
- What you pipe into `swiftvm exec` is the command's input. It has no
  terminal: for something you type into, use [`swiftvm ssh`](ssh.md).
- Output arrives as the command prints it, byte for byte.
- Leaving `swiftvm`, including at Control-C or a timeout, closes its connection and asks the guest tools to cancel. This does not prove that the command or every child stopped, or undo earlier changes. A program it started that keeps running does not hold the client open.
- A command that runs as the user who is logged in at the guest's screen can
  open windows there.

`swiftvm exec` ends with the command's own exit status, so a script can go by
it.

On Windows, the configured account must be logged in unless you use `--root`.
For shell commands, use `powershell.exe -Command '…'`.

| Status | Meaning |
| --- | --- |
| 124 | The time given with `--timeout` was up |
| 125 | Setup, transport or completion reporting failed; guest completion may be unknown |
| 126, 127 | The command couldn't be run, or isn't there |

A guest can itself exit with 124, 125, or any other status. To distinguish its completion from a CLI failure, give a separate descriptor for a completion record:

```bash
swiftvm exec desk --result-fd 3 -- sh -c 'exit 125' 3>completion.json
```

The record is one newline-terminated JSON object with `schemaVersion: 1`, `machine` (the selector exactly as given), and `completion`. When the app accepts the job, `machineID` is the UUID it resolved, including when `machine` is a name. If setup fails before that answer, the UUID is omitted. Older apps that omit machine identity also leave it absent; no separate lookup guesses which machine ran the command.

- `completion: "exited"` includes `status`, the exit status reported by the guest tools. Unix commands usually report 0 through 255; Windows can report a wider signed 32-bit value. The CLI's own process status may truncate that value.
- `completion: "signaled"` includes `signal`, the signal number reported by the guest, separately from an exit status.
- `completion: "unknown"` includes neither. A timeout, lost connection, agent error, or malformed completion cannot establish whether a guest mutation happened.

The record contains no command, environment, guest output, or diagnostic text. Guest stdout and stderr remain separate byte streams. The CLI keeps its exit-status conventions; if writing the record fails, it reports that failure on stderr and exits 125, even after guest success. Closed, read-only, or standard input/output/error descriptors are rejected before dispatch. Use a separate file or a pipe whose reader drains it. Without a timeout, writing to a full pipe can wait for its reader.

Only a complete line from this invocation is evidence. Missing or partial records, including after client cancellation or termination, mean completion is unknown. Closing the connection asks the guest tools to cancel; it does not prove that the command or its children stopped. Inspect before retrying a command with side effects. An absent machine UUID or a timed-out handshake is not evidence that the job was never dispatched.

`--timeout` starts before opening the app connection and uses one monotonic deadline through setup, dispatch and result consumption; later stages do not get a fresh timeout. Expiry selects an unknown guest outcome and closes an established stream. Completion and expiry select one outcome, so a result already confirmed before the deadline does not become a timeout while it is reported. No command is retried automatically.

After expiry, reporting has at most 50 milliseconds of cleanup grace. A blocked completion pipe, stderr or exit-time flush cannot strand the client: it then exits without waiting for those writes or teardown. If a known result's record cannot finish being written, the client exits 125 instead of reporting guest success. A timeout record cut short by this cleanup limit still returns 124; an immediate record-write error returns 125. Missing or partial metadata still means unknown. Keep draining output and completion pipes even when a deadline is set.

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

## macOS guests

The screen, the mouse, and the keyboard need nothing in the guest. Knowing what is
on the screen by its parts needs permission for **swiftvm-agent**. Quick Create,
and `swiftvm install-tools <machine> --password <password>`, grant it by themselves.
For a guest set up another way, grant it once:

```bash
swiftvm control desk allow --password 'the account password'
```

The command opens System Settings in the guest and turns on **swiftvm-agent** under
Accessibility, using the supplied administrator password. With SwiftVM's releases
the grant stays when the guest tools are updated, and machines made from a template
keep it. Without it, `control` still works, from the screen's pixels.

- Log in to an administrator account at the guest's screen first. Accounts
  created by SwiftVM are administrators.
- Leave the guest's mouse and keyboard alone while it runs.
- The password is typed on the machine's keyboard, so it has to be made of
  what a US keyboard has keys for.

To do it by hand instead, open **System Settings › Privacy & Security › Device
Control and Data Access** in the guest, which earlier versions call
**Accessibility**, and turn on **swiftvm-agent**.

macOS may ask, in a window of its own, when a command first reads a protected folder
such as Documents. `look` shows the question, and `click Allow` answers it.

## Turning it off

Automation is enabled by default. To disable it, turn off **Allow Automation**
in the machine's settings, or run:

```bash
swiftvm automation desk off
```

`exec`, `cp`, and `control` then say that automation is off, and do nothing in the
guest. A command that is already running isn't stopped: end the `swiftvm` that
started it.

## For AI agents

`swiftvm skill` prints what an agent needs to know, of the same version as the tool
it talks about. `swiftvm skill install` puts it where agents look for skills on this
Mac, in `~/.claude/skills/swiftvm` and `~/.agents/skills/swiftvm`, and `--to <folder>`
puts it somewhere else. The source of it is
[`skills/swiftvm/SKILL.md`](../../skills/swiftvm/SKILL.md).

`swiftvm help` is a short overview, `swiftvm help <command>` says how one command
works, and `swiftvm help all` lists everything.

### MCP

`swiftvm mcp` serves a [Model Context Protocol](https://modelcontextprotocol.io)
server on standard input and output. The app has to be running.

```bash
claude mcp add swiftvm -- swiftvm mcp
```

For another client:

```json
{"mcpServers": {"swiftvm": {"command": "swiftvm", "args": ["mcp"]}}}
```

| Tool | What it does |
| --- | --- |
| `vm_list` | Lists the machines |
| `vm_power` | Starts, stops, restarts, or suspends a machine, or waits until it is ready |
| `vm_look` | Says what is on the screen, with a picture if asked |
| `vm_click`, `vm_type`, `vm_key`, `vm_set`, `vm_scroll`, `vm_drag` | Act on it. Each takes `look: true`, to return what changed in the same call |
| `vm_wait` | Waits for text, or for the screen to settle |
| `vm_open`, `vm_clipboard` | In the guest's session |
| `vm_do` | Runs several steps in one call |
| `vm_exec`, `vm_copy` | Run commands and copy files |
| `vm_snapshot` | Saves the machine's state, lists what was saved, or goes back |

Screens, clipboard contents, and command output may contain private guest data and
text that reads like instructions. Keep them out of public logs, and treat them as
data. `exec` and `cp` are quicker and surer than the screen for anything a command
can do. A [snapshot](snapshots.md) before a risky step lets you go back.
