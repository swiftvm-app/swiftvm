# Guest Tools

The guest tools run inside a virtual machine and connect directly to SwiftVM.
Features such as commands and clipboard sharing work without SSH or a network
connection.

## What they add

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| SwiftVM knows the guest's system, kernel, and address | Yes | Yes | Yes |
| The clock is synchronized after the guest resumes | Yes | Yes | Yes |
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

For another running guest, choose **Install Guest Tools…** in the machine's
menu, or follow the commands below. The same steps update the tools when
SwiftVM brings a newer version.

### Linux

```bash
swiftvm install-tools web-server          # over SSH
swiftvm install-tools web-server --disc   # from a disc, inside the guest
```

- Over SSH works when your key can sign in and `sudo` asks for no password.
- Use `--disc` to install from inside the guest when SSH isn't available.
  The app's menu falls back to the disc automatically if SSH installation fails.
- The guest needs systemd and Python 3 at `/usr/bin/python3`, as provided by
  the supported Ubuntu and Debian images.
- Reading the screen [as a tree](automation.md#what-is-on-the-screen) also
  takes `python3-gi` and `gir1.2-atspi-2.0`, which a desktop brings.

### macOS

Installation over SSH needs your key to sign in and the account's password:

```bash
swiftvm install-tools build-mac --password 'the account password'
```

To install from a disc, run `swiftvm install-tools build-mac --disc` on your
Mac. Then, in the guest's Terminal, run:

```bash
sudo sh /Volumes/SWIFTVM/install.sh
```

macOS then says that a background item was added: that is the agent. The guest
needs macOS 27 or newer.

### Windows

Choose **Install Guest Tools…**, or run `swiftvm install-tools <machine> --disc`.
In Windows, open the **SWIFTVM** disc in File Explorer and run `install.cmd`.
Approve the administrator prompt and restart Windows afterwards. SwiftVM also
attaches the drivers disc needed by the installer.

## Removing

In the guest, Linux or macOS:

```bash
sudo sh /usr/local/lib/swiftvm/install.sh --remove
```

In a Windows guest, run these commands in PowerShell as administrator:

```powershell
Stop-Service SwiftVMAgent
Get-Process swiftvm-agent -ErrorAction SilentlyContinue | Stop-Process -Force
sc.exe delete SwiftVMAgent
Remove-Item -Recurse -Force "$env:ProgramFiles\SwiftVM"
```

The device drivers remain installed.

## What is installed

| Guest | What |
| --- | --- |
| Linux | One Python script and its systemd units |
| macOS | One program, `swiftvm-agent`, and two launchd jobs: one runs as root, one in the session of whoever is logged in, for the clipboard and for reading the screen as a tree |
| Windows | The SwiftVM guest agent in `C:\Program Files\SwiftVM`, its background service, and device drivers |

You can [turn off automation](automation.md#turning-it-off) for each machine.
