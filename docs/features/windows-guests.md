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

**Graphics acceleration (experimental)** is on by default. Turn it off for a
display-only driver that stays sharp at any window size but draws more slowly;
see [Graphics acceleration](#graphics-acceleration).

Under **Advanced**, you can change the account name, processors, memory, disk
size, storage location, and whether to install your SSH key. Windows needs at
least 4 GB of memory and a 64 GB disk. You can also
[keep the disk compressed](disks.md#keeping-the-disk-compressed).

From the command line:

```bash
swiftvm create windows --password 'your password'
swiftvm create windows --iso ~/Downloads/Win11_Arm64.iso --password 'your password' --memory 8
swiftvm create windows --password 'your password' --no-gpu
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

## Graphics acceleration

GPU acceleration is **experimental and enabled by default for new Windows
machines**; turn it off when creating the machine to use the display-only driver
instead. Setup installs the signed Direct3D driver automatically. Once the
guest tools report that it is installed, the next cold boot uses your Mac's
GPU through DXMT and Metal. Windows Setup uses the firmware framebuffer before
the driver is available.

### Window size and sharpness

The 3D driver gives Windows a new screen size only when Windows starts. So that
the picture is sharp, Windows starts at the size of the machine's window in your
Mac's pixels, at the matching scale (200% on a Retina display). A new machine's
window is sized to fit your screen, and the window takes Windows' size whenever
it opens.

If you resize the window, Windows keeps its size and the window shows it
scaled. **Sharpen Display** then appears in the window's title bar:

- **Restart at This Size** restarts Windows, which then starts at the window's
  new size. Open apps close, as in any restart.
- **Return to Sharp Size** gives the window back the size Windows is sharp at.

Machines without graphics acceleration use the display-only driver, which
follows the window as you resize it and stays sharp at any size.

The experimental graphics stack can produce missing text, rendering failures,
hangs, Windows crashes, or unexpected VM stops, including during shutdown. Use
a disposable guest, not a machine you rely on, and keep important files backed
up. GPU acceleration does not yet guarantee reliable window resizing or Retina
quality at every resolution.

A machine keeps the display driver it was created with. Updating the
[guest tools](guest-tools.md#windows) updates that driver and doesn't switch
between the display-only and the 3D one.

[Custom builds](../tech/building.md#requirements) can leave Direct3D out with
`SWIFTVM_QEMU_DIRECT3D=0`. They install the display-only driver for new machines.
A machine that already has the 3D driver falls back to the firmware framebuffer
when opened in a build without Direct3D. This is a build setting, not a per-VM
switch.

Accelerated machines cannot suspend or save running graphics state. Shut
Windows down before taking a snapshot or quitting SwiftVM.

## Seamless Mode

Seamless Mode puts each Windows app in a window of its own on your Mac's desktop,
instead of showing the whole Windows desktop in the machine's window. Windows
apps sit alongside your Mac apps, switch with Command-`, and appear in Mission
Control.

To turn it on for a running machine, choose **Enter Seamless Mode** in the
machine's menu in the menu bar, in the window toolbar's **Power** menu, or in
the **Virtual Machine** menu. The machine's window closes and its open apps
appear on your desktop. To open the Start menu, click SwiftVM in the Dock or
choose **Show Start Menu**. The Start menu opens above the Dock, and apps you
start from it open as windows of their own.

Drag a window by its title bar to move it, as you would a Mac window. Windows
moves its own window there when you let go. Resize a window by dragging its edges
or corners, as you would a Mac window. You can grab an edge from just outside it,
and the pointer shows when you can. Windows resizes its own window as you drag.
Windows' own buttons minimize, maximize, and close windows, and double-clicking a
title bar maximizes the window.

To leave, choose **Exit Seamless Mode** in the machine's menu. The machine's
window opens again with the whole desktop. Seamless Mode also ends when the
machine shuts down or is suspended.

Seamless Mode requires guest tools 1.4 or newer. If **Enter Seamless Mode** is
unavailable, choose **Install Guest Tools…** to
[update them](guest-tools.md#windows).

- Windows' screen is laid over the area between the menu bar and the Dock on
  your Mac's main display. Its taskbar is not shown, and maximized windows fill
  that area. Without graphics acceleration, Windows' screen is resized to fit
  that area exactly. With it, Windows keeps the size it started at, and its
  windows are scaled to fit; see [Window size and sharpness](#window-size-and-sharpness).
- Windows appear on the main display only, and stay in the area between the
  menu bar and the Dock.
- Menus and the Start menu close when you switch to another app.
- Windows' animation effects are off during Seamless Mode, so the Start menu and
  windows appear without sliding or fading. They come back when you leave.
- Each app's window belongs to SwiftVM, so Windows apps do not get their own
  Dock icons.
- Like the machine's window, Seamless Mode sends Command shortcuts to Windows
  when **Send System Shortcuts to the Guest** is on.

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
  processor. GPU acceleration is experimental; graphics compatibility and
  performance vary. See [Graphics acceleration](#graphics-acceleration).
- Physical USB devices and microphone input are not supported. Disc and disk
  images can still be attached as [removable drives](disks.md).
- Display resizing requires someone to be logged in. The sign-in screen keeps
  its previous size.
- [Seamless Mode](#seamless-mode) supports Windows guests only, on your Mac's
  main display.
- TPM and Secure Boot are unavailable; software that requires them will not work.
- Reading the screen as an accessibility tree is not supported.
- Automated typing supports characters available on a US keyboard. Use
  commands or file copies for other text; see [Automation](automation.md).
- Attached disk images must be raw or ISO; ASIF is unsupported.
- Duplicates and machines made from a template keep the original Windows
  computer name. Rename them in Windows Settings if they will run together.
