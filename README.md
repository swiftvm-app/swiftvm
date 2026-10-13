<p align="center">
  <img src="assets/logo.png" alt="SwiftVM" width="128" height="128">
</p>

<h1 align="center">SwiftVM</h1>

<p align="center">Native macOS app for running virtual machines, built with Swift and Apple's Virtualization framework.</p>

## Supported guests

- Mac
- Linux
- Windows (Coming soon)

## Top level features

- macOS guests that install and set themselves up
- Linux guests from a cloud image, ready in seconds
- Linux desktops that install themselves: GNOME, KDE Plasma, Xfce, Cinnamon
- Setup scripts for everything else a new machine needs, in one file you write
- `ssh <machine>` from your Mac
- Snapshots and instant duplicates
- Templates: save a machine you set up, and create new ones from it
- Suspend and resume
- Shared folders and clipboard
- Port forwarding
- USB devices and disk images
- Lives in the menu bar
- `swiftvm` command-line tool
- Automation for scripts and AI agents: run commands in a guest, copy files, see its screen, use its mouse and keyboard

Windows guests are planned.

## Install

SwiftVM runs on macOS 27 or newer, on Apple silicon.

```bash
brew install --cask swiftvm-app/tap/swiftvm
```

Or download the DMG from the [latest release](https://github.com/swiftvm-app/swiftvm/releases/latest).

See [Getting started](docs/user-guide/getting-started.md) for your first virtual machine, the `swiftvm` command, and beta builds.

## Documentation

See [docs](https://swiftvm.app/docs).

## License

[Apache-2.0](LICENSE)
