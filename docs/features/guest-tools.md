# Guest Tools

The guest tools are a small agent that runs inside a virtual machine. It talks
to SwiftVM over the machine's own socket device, or a serial line of its own in
Windows guests, so it works even when the guest has no network.

## What they add

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| SwiftVM knows the guest's system, kernel, and address | Yes | Yes | Yes |
| The clock is set the moment the guest resumes | Yes | Yes | Yes |
| **Shut Down** works at once, without a question on the guest's screen | Yes | Yes | Yes |
| SwiftVM shows what a [setup script](setup-scripts.md) is doing | Yes | No | SwiftVM's own setup |
| [Shared folders](sharing.md) are mounted | Yes | macOS mounts them by itself | As drive Z: |
| [Shared clipboard](sharing.md#clipboard) | Uses `spice-vdagent` instead | Yes | Yes |
| The time zone follows your Mac's, once | No | Yes | Yes |
| [SSH without a network](ssh.md#without-a-network) on older systems | Yes | No | No |
| `swiftvm` [runs commands and copies files](automation.md) in the guest | Yes | Yes | Yes |
| `swiftvm` [sees the screen and uses the mouse and keyboard](automation.md#the-screen) | Yes | Works without the guest tools | Works without the guest tools |
| `swiftvm` [reads the screen as a tree](automation.md#what-is-on-the-screen) | Yes | Yes, once [macOS allows it](automation.md#macos-guests): `swiftvm allow-accessibility` | No |
| The display follows the window | Works without the guest tools | Works without the guest tools | Yes, with the driver they bring |

## Which machines have them

Machines that SwiftVM sets up come with the guest tools:

- Linux machines made with [Quick Create](linux-guests.md#quick-create).
- [macOS](macos-guests.md) 27 or newer, created with **Sign in over SSH with
  my key** on.
- [Windows](windows-guests.md) machines that SwiftVM installed.

`swiftvm info <machine>` shows the installed version.

## Installing

For any other running guest, choose **Install Guest Tools…** in the machine's
menu, or use `swiftvm install-tools`. The same command updates them when
SwiftVM brings a newer version.

### Linux

```bash
swiftvm install-tools web-server          # over SSH
swiftvm install-tools web-server --disc   # from a disc, inside the guest
```

- Over SSH works when your key can sign in and `sudo` asks for no password.
- Otherwise SwiftVM plugs in a disc and shows one command to run in the guest.
- The guest needs systemd and Python 3. Ubuntu and Debian have both; other
  distributions haven't been tried.
- Reading the screen [as a tree](automation.md#what-is-on-the-screen) also
  takes `python3-gi` and `gir1.2-atspi-2.0`, which a desktop brings.

### macOS

macOS asks for the account's password before installing:

```bash
swiftvm install-tools build-mac --password 'the account password'
```

Or choose **Install Guest Tools…**, which plugs in a disc. In the guest's
Terminal, run:

```bash
sudo sh /Volumes/SWIFTVM/install.sh
```

macOS then says that a background item was added: that is the agent. The guest
needs macOS 27 or newer.

### Windows

Choose **Install Guest Tools…**, or run `swiftvm install-tools <machine> --disc`.
SwiftVM plugs in the guest tools disc and the drivers for virtual machines. In
the guest, open the SWIFTVM disc in File Explorer and run `install.cmd`, which
asks to run as an administrator. Restart Windows afterwards, so that its
display follows the window.

## Removing

In the guest, Linux or macOS:

```bash
sudo sh /usr/local/lib/swiftvm/install.sh --remove
```

In a Windows guest, stop and delete the service (`sc.exe stop SwiftVMAgent` and
`sc.exe delete SwiftVMAgent` in an administrator's terminal), and delete
`C:\Program Files\SwiftVM`.

## What is installed

| Guest | What |
| --- | --- |
| Linux | One Python script and its systemd units |
| macOS | One program, `swiftvm-agent`, and two launchd jobs: one runs as root, one in the session of whoever is logged in, for the clipboard and for reading the screen as a tree |
| Windows | One program, `C:\Program Files\SwiftVM\swiftvm-agent.exe`, built in the guest from its source by the C# compiler that comes with Windows. It runs as a service, `SwiftVMAgent`, and in the session of whoever logs in, for the clipboard and the shared folders' drive. Also the drivers for the machine's devices |

The agent only takes orders from your Mac, and only over the machine's socket
device, or in Windows over a serial port that only SYSTEM and administrators
may open. What `swiftvm` may have it do in a guest can be
[turned off](automation.md#turning-it-off) for each machine.
