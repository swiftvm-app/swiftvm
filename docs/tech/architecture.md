# Architecture

The programs, the modules, and how they work together.

## Programs

| Program | Where it runs | What it does |
| --- | --- | --- |
| SwiftVM | Your Mac | The app. Owns every machine and runs the guests |
| `swiftvm` | Your Mac | The command-line tool, inside the app at `Contents/Helpers`. Sends requests to the running app |
| `swiftvm-agent` | macOS guests | The guest agent for macOS. Built with the app and carried into guests by an installer |
| `swiftvm-agent.py` | Linux guests | The guest agent for Linux: one Python script and its systemd units |

## Modules

The app is the package at the repository's root. Everything that isn't
interface is in `Packages/SwiftVMKit`.

```mermaid
flowchart TB
    APP["SwiftVM app"] --> VZ["VZEngine"]
    APP --> INSTALLERS["Installers"]
    APP --> SSH["SSHIntegration"]
    APP --> CONTROL["VMControl"]
    CLI["swiftvm"] --> CONTROL
    VZ --> NETWORKING["VMNetworking"]
    VZ --> DISK["DiskTools"]
    INSTALLERS --> DISK
    VZ --> CORE["VMCore"]
    NETWORKING --> CORE
    DISK --> CORE
    SSH --> CORE
    INSTALLERS --> CORE
    CORE --> CHANNEL["GuestChannel"]
    AGENT["swiftvm-agent"] --> AGENTMAC["GuestAgentMac"]
    AGENTMAC --> CHANNEL
```

| Module | Role |
| --- | --- |
| `App/` | The SwiftUI app: the menu bar panel, the windows, and the model behind them |
| `VMCore` | What a machine is: its configuration, its package on disk, the library, snapshots, the serial console, USB rules. Knows no engine |
| `VZEngine` | Runs machines on the Virtualization framework, and installs macOS |
| `VMNetworking` | The shared network, address reservations, and the port relay |
| `SSHIntegration` | SSH names, keys, and the generated SSH configuration |
| `DiskTools` | Creates, grows, and converts disk images, and builds small ISO images |
| `Installers` | The distribution catalog, setup scripts, downloads, first-boot setup for Linux, and the guest agent installers |
| `VMControl` | The messages between the app and `swiftvm`, and which copy of the app a program belongs to |
| `GuestChannel` | The messages between the app and a guest agent |
| `GuestAgentMac` | The guest agent for macOS |

`VMCore` defines a backend protocol, and `VZEngine` is its only
implementation today. A second engine for Windows guests would sit next to it.

## A machine on disk

A machine is a `.swiftvm` package in the library folder.

| File | What it holds |
| --- | --- |
| `config.json` | The machine's configuration. Newer fields decode with defaults, so older machines keep opening |
| `disk.img`, `disk.asif` | The disk: raw for Quick Create machines, ASIF for the rest |
| `efi-vars.fd` | Linux: UEFI variables |
| `aux.img`, `hardware-model.bin`, `machine-identifier.bin` | macOS: firmware state and the machine's identity |
| `seed.iso` | Linux Quick Create: the first-boot setup data, with the setup script if one was picked |
| `state.vzvmsave` | Saved memory, while suspended |
| `snapshots/` | One folder per snapshot |
| `logs/console.log` | Serial console output |

New machines are built in a staging folder and moved into the library once
they are complete, so a creation that is cut short leaves nothing behind.

## Starting a machine

```mermaid
sequenceDiagram
    participant User as Panel or swiftvm
    participant Machine as Machine
    participant Network as Network manager
    participant VZ as Virtualization framework
    participant Agent as Guest agent
    User->>Machine: Start
    Machine->>Network: Attach
    Note over Network: The first machine creates the network
    Machine->>VZ: Build the configuration, then boot or restore
    VZ-->>Machine: Running
    loop Until it answers
        Machine->>Agent: Connect over the socket device
    end
    Agent-->>Machine: Hello: system, kernel, addresses
    Machine->>Agent: Set the clock, mount shared folders
```

## The control socket

- The app listens on a Unix socket, `control.sock`, in its data folder. Only
  the current user can connect.
- `swiftvm` sends one JSON request per line and waits for the answer, however
  long the operation takes.
- The console and socket-device commands turn the connection into a byte
  stream after the app agrees.
- The tool finds its app by where it is: it follows its own path up to the app
  it is inside of, and uses that app's data folder.

## The guest channel

- Each machine has a virtio socket device. The agent listens on port 717 and
  the app connects, again whenever a guest comes up or resumes.
- Both sides send one JSON object per line and ignore what they don't know.
  The agent names what it can do in its hello, and the app asks for nothing
  else.
- Only root can listen below port 1024 in a guest, so the app knows who
  answers. The agent only accepts connections from the host.
- The macOS agent runs as two halves. A root daemon talks to the app and
  handles power, clock, and time zone. A second half in the login session
  owns the clipboard and reaches the daemon over a Unix socket.
- The Linux agent also passes on how the machine's
  [setup script](#setup-scripts) is doing, unasked, whenever that changes.

## Networking

- All machines share one NAT network made with vmnet. It is created when the
  first machine starts and released when the last one stops.
- Each machine's address is reserved for its MAC address when the network is
  created.
- Forwarded ports are relayed by the app itself, so they can change while
  machines run.
- The app picks a private address range that the Mac isn't using, and moves to
  another if that one can't be created.

## Creating machines

- **Linux, Quick Create.** Download the cloud image and verify its checksum,
  convert it to a raw disk, and write a cloud-init seed image with the account,
  SSH key, host name, network setup, guest tools, and the setup script if one
  was picked.
- **Linux, installer disc.** Create an empty disk and attach the ISO as a USB
  drive.
- **macOS.** Install the restore image onto an empty disk, then start with an
  account for macOS to create by itself. SwiftVM then installs the SSH key and
  the guest tools over SSH.

## Setup scripts

A [setup script](../features/setup-scripts.md) is one file with a comment
header. One catalog is the only place scripts come from: the templates, which
are scripts inside the app, and the files in the user's folder,
`~/.config/swiftvm/setup-scripts`. A list fetched from elsewhere has one place
to join. The app and the command line show the same list, by kind.

A machine takes several scripts. They travel in its first-boot data, numbered
in the order they run, and the runner in the guest goes through them: it notes
each one that came to its end, so that a run that failed or was cut short
carries on with the one that wasn't through.

```mermaid
sequenceDiagram
    participant Seed as First-boot setup
    participant Unit as swiftvm-setup.service
    participant Runner as Runner
    participant Agent as Guest agent
    participant App as App
    Seed->>Runner: Write the script, the runner, the unit. Schedule
    Runner-->>Agent: status: pending
    Agent->>App: setup: pending
    Note over Seed: First-boot setup ends
    Unit->>Runner: Run
    loop While the script runs
        Runner-->>Agent: status and step
        Agent->>App: setup: running, step
    end
    Runner-->>Agent: status: finished or failed
    Agent->>App: setup: finished or failed
    Runner->>Unit: Disable. Restart the guest if asked
```

- The script travels in the seed image, next to a runner and a systemd unit.
  First-boot setup writes them down and schedules the unit, which runs once
  that setup is over.
- The runner writes everything the script prints to a log, keeps a note of the
  state and the step, and restarts the guest if the header asks. The agent
  reads the note and tells the app.
- The unit stays enabled until the script has finished or failed. A setup that
  is cut short carries on at the next start; one that keeps being cut short is
  given up on.
- A copy of a machine goes through first-boot setup again. The runner leaves a
  disk alone where a setup was scheduled before, so nothing is installed twice.

## Snapshots and copies

- A snapshot is a copy of the machine's disk, firmware, and saved memory, kept
  in the package. On APFS the copy is a clone and takes no time.
- A running machine is suspended, copied, and resumed.
- Going back copies the snapshot's files next to the machine's first, then
  swaps them in. If that is cut short, the machine never ends up with memory
  saved next to a disk it doesn't belong to.

## The app in the menu bar

- The app has no Dock icon by default. It enters the Dock while one of its
  windows is open and leaves once another app comes to the front.
- Messages that have no window to show in become a card at the top of the
  panel.
- Updates come through Sparkle. See [Releasing](./releasing.md).
