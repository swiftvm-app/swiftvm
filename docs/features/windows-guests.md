# Windows Guests

SwiftVM runs Windows 11 for Arm on Apple silicon. It can download Windows from
Microsoft or use an Arm64 ISO you already have, then install Windows and set up
your account automatically.

## Creating

Choose **Windows** in the **Type** dropdown, enter an account password, and
choose **Create**. Installation can take about half an hour, depending on your
Mac and internet connection. You can keep using your Mac while it runs.

To use your own installer, choose **Choose ISO…**. The ISO must be Windows 11
for **Arm64**; installers for Intel and AMD processors are not supported.

Under **Advanced**, you can change the account name, processors, memory, disk
size, storage location, and whether to install your SSH key. Windows needs at
least 4 GB of memory and a 64 GB disk. You can also
[keep the disk compressed](disks.md#keeping-the-disk-compressed).

From the command line:

```bash
swiftvm create windows --password 'your password'
swiftvm create windows --iso ~/Downloads/Win11_Arm64.iso --password 'your password' --memory 8
```

SwiftVM downloads the required drivers and caches downloads for reuse. If
Microsoft blocks the automatic download, download the ISO from
[Microsoft's Windows 11 Arm64 page](https://www.microsoft.com/software-download/windows11arm64)
and select it with **Choose ISO…**.

## What gets installed

- **Windows 11 Pro.** You need your own license to activate it in Windows
  Settings.
- Your administrator account, with automatic sign-in.
- Device drivers and the [guest tools](guest-tools.md), including clipboard
  sharing and display resizing.
- SSH, when Windows Update is reachable. If you enabled **Sign in over SSH
  with my key**, SwiftVM installs your Mac's SSH key. SSH sessions use PowerShell.

The machine's window shows setup progress. Windows restarts when setup
finishes, and SwiftVM removes the installation discs.

## Guest tools and automation

The guest tools are installed automatically. To install or update them in an
existing Windows guest, follow the [Windows guest tools instructions](guest-tools.md#windows).

With the tools, `swiftvm exec` runs commands and `swiftvm cp` copies files.
Commands run as the configured account while it is logged in, or as SYSTEM
with `--root`. Screenshots, mouse actions, and keyboard input work without the
tools. See [Automation](automation.md).

## Shared folders

Folders you share from your Mac appear on drive **Z:** in File Explorer. This
requires the guest tools and a connection to SwiftVM's virtual network.
Changes to the shared-folder list apply while the machine runs. See
[Shared folders](sharing.md).

## Remote Desktop

Enable **Settings > System > Remote Desktop** in Windows, then connect to the
machine's address from a Remote Desktop app on your Mac. Use the Windows
account name and password you chose during creation.

## Limitations

- Windows uses QEMU, included with SwiftVM, with hardware acceleration for the
  processor. Graphics acceleration is unavailable, so animations, video, and
  games can be slow.
- Physical USB devices and microphone input are not supported. Disc and disk
  images can still be attached as [removable drives](disks.md).
- Display resizing requires someone to be logged in. The sign-in screen keeps
  its previous size.
- TPM and Secure Boot are unavailable; software that requires them will not work.
- Reading the screen as an accessibility tree is not supported.
- Automated typing supports characters available on a US keyboard. Use
  commands or file copies for other text; see [Automation](automation.md).
- Attached disk images must be raw or ISO; ASIF is unsupported.
- Duplicates and machines made from a template keep the original Windows
  computer name. Rename them in Windows Settings if they will run together.
