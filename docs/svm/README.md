# svm

`svm` creates and runs Linux virtual machines from a terminal, on macOS and on
Linux. It is one small program, about 6 MB, that needs neither the SwiftVM app
nor a background service: each running machine is a process of its own. Apps
can ship it inside them and drive it through its JSON output.

It is a separate project, at
[swiftvm-app/cli](https://github.com/swiftvm-app/cli).

## svm or swiftvm

The SwiftVM app comes with a command of its own, [`swiftvm`](../features/command-line.md),
which drives the app. `svm` works without it.

| | `swiftvm` | `svm` |
| --- | --- | --- |
| Needs | The SwiftVM app, open | Nothing else |
| Runs on | macOS 27 or newer, on Apple silicon | macOS 14 or newer, and Linux with KVM, on arm64 and x86-64 |
| Guests | macOS, Linux and Windows | Linux: Debian 13 and Ubuntu 24.04 |
| Machines kept in | `~/Library/Application Support/SwiftVM` | `~/Library/Application Support/svm`, or `~/.local/share/svm` on Linux |

Both can be installed on the same Mac. They keep their machines, downloads and
settings apart, and neither sees the other's machines.

## Install

```bash
curl -fsSL https://github.com/swiftvm-app/cli/releases/latest/download/install.sh | sh
```

It installs `svm` in `~/.local/bin`. `SVM_INSTALL_DIR` picks another folder, and
`SVM_VERSION` another release. Or with Homebrew, on macOS and Linux:

```bash
brew install swiftvm-app/tap/svm
```

On a Mac, `svm` is signed and notarized. On Linux, your user needs to be in the
`kvm` group, and `svm` downloads the hypervisor it uses,
[Cloud Hypervisor](https://www.cloudhypervisor.org), the first time it creates a
machine.

## Use

```bash
svm create debian-13 --name dev --script docker
svm start dev
svm wait dev                  # until the guest is up and its setup has run
svm exec dev -- docker --version
svm cp ./project dev:project
svm snapshot dev before-upgrade
svm ssh dev
svm forward dev 8080:80       # until Ctrl-C
```

| Commands | What they do |
| --- | --- |
| `create`, `start`, `stop`, `delete`, `list`, `info`, `watch` | Make machines, run them, and see what they are doing |
| `wait`, `exec`, `cp`, `ssh`, `console`, `forward` | Work in the guest, without a network address or an SSH key to set up |
| `snapshot`, `revert`, `image save`, `image export`, `image import` | Keep a machine as it is, and make new machines from it |
| `screenshot`, `click`, `type`, `key`, `open`, `vnc` | See and work a guest's desktop, from `--script xfce` and the others |
| `mcp` | Serve all of this to AI agents as a Model Context Protocol server |

`svm help` lists every command and its options.

## In your own app

Every command takes `--json` and prints one JSON document: its result, or an
error with a code to act on. Long commands report their progress as JSON lines,
and `svm watch --json` says whenever a machine changes. The
[API](https://github.com/swiftvm-app/cli/blob/main/docs/api.md) describes it
all, and keeps to its version.

An app that ships `svm` inside it gives it folders of its own with
`SVM_HOME`, `SVM_CACHE` and `SVM_RUNTIME`. Its machines are then its own, and it
never meets an `svm` that the user installed.
