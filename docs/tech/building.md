# Building

Building the app, running a development copy, and signing.

## Requirements

- macOS 27 or newer, on Apple silicon
- Xcode 27 or newer

No Apple Developer account is needed to build and run virtual machines.

For Windows guests and Linux
[graphics acceleration](../features/linux-guests.md#graphics-acceleration),
install QEMU's build dependencies and Xcode's Metal toolchain:

```bash
brew install cmake ninja meson pkgconf glib pixman openssl@3 python
xcodebuild -downloadComponent MetalToolchain
```

The build scripts build QEMU on the first run with `scripts/build-qemu.sh`:
QEMU 11 with SPICE, virglrenderer, and ANGLE, and the library the app shows
accelerated screens with. The patches in `Native/QEMU` port UTM's graphics work
to it, and `Native/QEMU/sources.tsv` pins every source by checksum. The first
build takes several minutes; later ones reuse `.build/qemu`. Set
`SWIFTVM_QEMU=-` to build without Windows guests or graphics acceleration.

Windows' Direct3D support is **experimental and included by default**, including
in release builds. It adds DXMT and the signed Windows 3D driver and compiles
LLVM 15, making the first build much longer. New Windows guests install the
driver automatically and use acceleration on the next cold boot after the
guest tools report it installed. Existing guests are not upgraded unless you
update their guest tools.

Set `SWIFTVM_QEMU_DIRECT3D=0` to leave Direct3D out while keeping Linux
acceleration. A Windows machine that already has the 3D driver falls back to
its firmware framebuffer over VNC when started in such a build.

Missing text, rendering failures, hangs, Windows crashes, and unexpected VM
stops can occur, including during shutdown. Use a disposable guest in a separate
[`SWIFTVM_HOME`](#the-development-copy). See [Windows graphics](../features/windows-guests.md#graphics-acceleration)
for the current limitations.

## Build

```bash
git clone https://github.com/swiftvm-app/swiftvm.git
cd swiftvm
scripts/build.sh          # the app, optimized, at build/SwiftVM.app
open build/SwiftVM.app
```

There is no Xcode project. The app is a Swift package: `swift build` compiles
it, and `scripts/bundle-app.sh` makes an app of the result and signs it. Xcode
opens `Package.swift`.

| Command | What it does |
| --- | --- |
| `scripts/build.sh` | Builds the app at `build/SwiftVM.app`, with `swiftvm` and the macOS guest agent inside |
| `scripts/build.sh debug` | The same, not optimized |
| `scripts/build.sh --output <app>` | Builds somewhere else, for example while SwiftVM is running from `build/` |
| `scripts/test.sh` | Runs the unit tests of both packages |

The scripts never replace an app that is running.

## The development copy

```bash
swift run SwiftVM
```

This builds and opens **SwiftVM Dev**, an app of its own to macOS. It keeps its
machines in `~/Library/Application Support/SwiftVM-Dev`, so it runs next to the
SwiftVM you use and never sees that app's machines.

- The copy is at `.build/SwiftVM Dev.app`, and its tool talks to that copy:
  `".build/SwiftVM Dev.app/Contents/Helpers/swiftvm" list`.
- The command stays in the terminal and shows what the copy prints. `Ctrl+C`
  asks the copy to quit, which it refuses while a machine is running. A second
  `Ctrl+C` leaves it running.
- `swift run SwiftVM --background` opens the copy behind your other windows
  and returns.
- Running the command again replaces a copy that is still open, unless it has
  a machine running.
- The two apps share the downloaded images, the SSH key SwiftVM makes, and the
  `swiftvm` link in `/usr/local/bin`.
- The development copy doesn't update itself.

Set `SWIFTVM_HOME` to give a copy another data folder, for a second set of
machines. The path must be short, about 90 characters at most, and `swiftvm`
needs the same setting to find that copy.

## Signing

With a signing certificate in your keychain, the app is signed with it:
Developer ID Application before Apple Development, and the other way round for
the development copy. Without one, the app is signed to run on your Mac, which
is enough to run virtual machines.

| Variable | What it does |
| --- | --- |
| `SWIFTVM_SIGN_IDENTITY` | Picks a certificate by name or SHA-1. `-` signs to run on your Mac |
| `SWIFTVM_PROVISIONING_PROFILE` | Names a provisioning profile to use. `-` builds without one |
| `SWIFTVM_HOME` | Another data folder for the app and for `swiftvm` |

## USB devices

Handing [USB devices](../features/usb-devices.md) to guests is the one thing
that takes more than a certificate. macOS only allows it in an app that carries
a provisioning profile:

- Made in a paid Apple Developer account, for the app's identifier, with the
  **Claim USB Accessory** capability.
- For the certificate the app is signed with: a Developer ID profile for
  `com.swiftvm.app`, or a development profile that lists your Mac for
  `com.swiftvm.app.dev`.

The build looks for such a profile where Xcode keeps profiles and puts it into
the app. When there is none, it says so and builds without: everything works
but USB devices, and the USB button isn't shown.

## Building only the tool

```bash
swift build --package-path Packages/SwiftVMKit --product swiftvm
```

Never build `swiftvm` at the repository's root. The file system takes `swiftvm`
and `SwiftVM` for one name, and the tool would replace the app's program.

## Layout

| Path | What |
| --- | --- |
| `Package.swift`, `App/` | The SwiftUI app |
| `Tests/SwiftVMTests/` | The app's unit tests |
| `Packages/SwiftVMKit/` | The engine, the `swiftvm` tool, and the guest agents, with their tests. See [Architecture](./architecture.md#modules) |
| `Config/` | The app's `Info.plist` and entitlements |
| `scripts/` | Build, test, and release scripts |
| `.github/workflows/` | Checks and [releases](./releasing.md) |
| `assets/` | The logo |
| `docs/` | These docs |
