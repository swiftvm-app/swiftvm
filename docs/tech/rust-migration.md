# Moving to a Rust service

SwiftVM is moving its virtual machine management into a Rust program, `swiftvm`,
so that it can run on Linux and other apps can drive it. The macOS app becomes
a client of that program. This page is the plan and where it stands.

## Why a service

A virtual machine lives in the process that starts it. If another app linked a
library that ran machines, its machines would stop when it quit, and two apps
would compete for the same machine library and network. So `swiftvm` becomes a
service that owns the machines, and every app, the SwiftVM app included, is a
client of it. Docker, Lima, and libvirt work the same way.

Other apps can use the service in three ways:

1. Run `swiftvm` commands, with `--json` for output a program reads.
2. Talk to its socket directly, for live state, events, consoles, and job
   streams.
3. Use a client library: a Rust crate, with a C header for other languages.

## Steps

Each step ships on its own.

| Step | What changes | State |
| --- | --- | --- |
| 1. Rust CLI | `swiftvm` is rewritten in Rust as a client of today's app, with the same commands, output, and exit statuses. The protocol crate starts here | Done |
| 2. `swiftvm serve` | A long-running service that runs QEMU machines. The app hands those machines to it. This is the first part that runs on Linux, on KVM | Planned |
| 3. Machine library | The machine library, creation, templates, and snapshots move into the service. The app reads them from it | Planned |
| 4. VZ runner | Machines on Apple's Virtualization framework run in a process of their own: the app's program started as a runner, inside the app bundle | Planned |

## The public API

Once other apps depend on the service, its protocol can't change freely. Step 2
adds:

- a protocol version and a handshake when a client connects
- stable error codes, besides the messages
- `--json` on every command
- a way to subscribe to events, such as a machine's state changing
- permission for each client, since every process of the user can connect today
  and can run commands in guests

Step 3 adds labels, so that an app can find its own machines. A private library
for one app already works through `SWIFTVM_HOME`.

## Limits

- macOS guests run only on a Mac: Apple's Virtualization framework is macOS-only,
  and Apple's license allows macOS guests only on Apple hardware.
- Only the process that runs a machine on Apple's framework can show its screen
  live. Other apps get screenshots and input through `swiftvm control`. Screens
  of QEMU machines are reachable over VNC or SPICE.
- Today every guest is ARM64. On x86-64 Linux, KVM runs only x86-64 guests at
  full speed, which needs x86-64 images, firmware, and Windows drivers.
