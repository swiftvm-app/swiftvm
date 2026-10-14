# Windows Guests

SwiftVM installs Windows 11 for Arm by itself: it downloads Windows from
Microsoft, or takes an ISO you have, installs it, creates your account, and
skips every question Windows Setup would ask. The machine is ready at its
desktop, logged in, about half an hour later.

Windows runs on [QEMU](#how-it-runs), which SwiftVM brings along, rather than on
Apple's Virtualization framework.

## Creating

Choose **Windows** in the **Type** dropdown, enter a password for the account,
and choose **Create**.

| Setting | What it is |
| --- | --- |
| Version | **Windows 11 for Arm, from Microsoft**, or an ISO you chose with **Choose ISO…** or dropped on the window |
| Password | Required. Windows doesn't let an account without one sign in over SSH or Remote Desktop |
| Full Name, Account Name | Under **Advanced**. Default to your Mac's |
| **Sign in over SSH with my key** | Lets your SSH key in once Windows has set SSH up |
| **Keep the disk compressed** | See [Disks](disks.md#keeping-the-disk-compressed) |

The ISO has to be Windows for Arm (Arm64). An ISO for Intel and AMD
processors is turned down when you choose it. Microsoft offers the Arm64 ISO at
[microsoft.com/software-download/windows11arm64](https://www.microsoft.com/software-download/windows11arm64).

```bash
swiftvm create windows --password 'a password'
swiftvm create windows --iso ~/Downloads/Win11_Arm64.iso --password 'a password' --memory 8
```

What it downloads is kept in the folder for downloads, and the next Windows
machine is made from there:

- Windows itself, about 9 GB, in the language your Mac prefers when Microsoft
  offers it, otherwise in English.
- The drivers for virtual machines, about 880 MB: Red Hat's `virtio-win`, signed
  for Windows. Windows on Arm has no drivers of its own for the machine's
  network card, display and the line its guest tools talk to SwiftVM over.

Microsoft sometimes turns automated downloads away, often over a VPN. SwiftVM
then says so: download the ISO from Microsoft's page yourself, and create the
machine from that.

## What SwiftVM sets up

- **Windows 11 Pro**, which [Remote Desktop](#remote-desktop) can reach. It is
  installed with Microsoft's key for installing that edition, which doesn't
  activate it: activate Windows in its settings with a key of your own.
- Your account, an administrator that logs in by itself.
- The drivers, and the [guest tools](guest-tools.md).
- **SSH**, from Windows Update, with your key. Sessions start in PowerShell.
- A display that follows the window. Windows Setup can only draw on a
  framebuffer of one size, so a new machine restarts once at the end of its
  setup, onto the display whose driver it has by then.

Windows Setup is told that the machine's processor, memory, TPM and Secure Boot
pass its checks. Windows runs well without them, but nothing that needs a TPM
works: BitLocker, for one.

While setup runs, the machine's window shows how far it has come. When it is
over, SwiftVM ejects the installer and the drivers, and deletes the setup disc,
which held the account's password.

## The guest tools

The guest tools for Windows are a service and a part in the session of whoever
is logged in. They do what the [guest tools](guest-tools.md) do in other guests:

- Show the version and addresses, and set the clock after a resume.
- Shut Windows down without anyone at its screen.
- Share the clipboard.
- Run commands for `swiftvm exec` and copy files for `swiftvm cp`, as the
  account at the screen, or as SYSTEM with `--root`.
- Map the [shared folders](sharing.md) as drive **Z:**.

A machine you installed from your own ISO without SwiftVM's setup gets them
with **Install Guest Tools…** in the machine's menu. SwiftVM plugs in the guest
tools disc and the drivers disc; run `install.cmd` on the SWIFTVM disc, and
restart Windows afterwards.

Screenshots, clicks and keys for [automation](automation.md) don't need the
guest tools: SwiftVM uses the machine's own display, mouse and keyboard, from
the firmware on.

## Shared folders

Windows has no driver for the file sharing other guests use. SwiftVM serves the
shared folders to it over WebDAV instead, on the virtual network only, and the
guest tools map them as drive **Z:** for whoever logs in. Each machine sees
only its own folders. Folders added in the settings appear on the drive right
away.

## Remote Desktop

Windows Pro can be reached with Remote Desktop. Turn it on in Windows under
**Settings > System > Remote Desktop**, then connect to the machine's address
from a Remote Desktop app on your Mac.

## How it runs

Apple's Virtualization framework doesn't start Windows. SwiftVM runs Windows
machines on QEMU, built for this and nothing else and inside the app, on Apple's
Hypervisor framework: Windows runs at the speed of the Mac's processor, as the
other guests do.

A Windows machine is on the same [network](networking.md) as the others, with
its own address, [forwarded ports](networking.md) and [SSH name](ssh.md). Its
window, [snapshots](snapshots.md), [templates](templates.md), suspending and
resuming, and disc and disk images as [USB drives](disks.md) work as they do for
any machine.

## Good to know

- USB devices of your Mac can't be handed to a Windows guest yet.
- Windows draws without graphics acceleration. Video and games are slow.
- The display follows the window while someone is logged in. At Windows'
  sign-in screen it keeps the size it had.
- A [duplicate](virtual-machines.md) or a machine made from a
  [template](templates.md) keeps the computer name of the original. Give it
  another in Windows' settings if both are on the network at once.
- Windows' clock is set to the Mac's time zone by the guest tools.
- Windows' devices list some it has no driver for: QEMU's unused slots. They
  do no harm.
