# API v1

`swiftvm serve` is the service that every client of SwiftVM talks to: the
`swiftvm` tool, its MCP server, and other apps. This page is its protocol. A
Rust client is in `crates/swiftvm-protocol` (`ServiceClient`, and the message
types in `wire`).

In this version the service answers the handshake, events and client
permission itself. It passes every other request on to the app, which still
runs the machines, and passes the app's answer back.

## Connecting

The service listens on `service.sock` in the data folder:

| Copy | Socket |
| --- | --- |
| SwiftVM on a Mac | `~/Library/Application Support/SwiftVM/service.sock` |
| SwiftVM Dev | `~/Library/Application Support/SwiftVM-Dev/service.sock` |
| Linux | `$XDG_DATA_HOME/swiftvm/service.sock`, or `~/.local/share/swiftvm/service.sock` |
| `SWIFTVM_HOME` set | `$SWIFTVM_HOME/service.sock` |

Only the user who runs the service can open it. When nothing listens there,
start `swiftvm serve`. The `swiftvm` tool does that by itself, and the app does
it when it opens. Only one service runs for a data folder. It stops by itself
when its program file is replaced, by an update or a new build, and the next
client starts the new one.

## Messages

Each message is one line of JSON. Dates are in RFC 3339, in UTC
(`2025-11-16T15:33:20.5Z`). Machine and snapshot IDs are UUIDs in capitals.
Fields that have no value are left out, except `machines`, which every answer
carries, empty when there is nothing in it.

### The handshake

The first line a client sends is `hello`:

```json
{"id":0,"command":"hello","protocol":1,"client":"notes-robot 2.1"}
```

The answer says what the service is:

```json
{"id":0,"ok":true,"machines":[],"service":{"version":"0.1.0","protocol":1,"platform":"macos","offers":["watch","hello","clients","clients-allow","clients-deny","clients-remove","service-stop"],"app":{"running":true}}}
```

`offers` lists the commands the service answers itself. `app.running` says
whether the app, which does everything else, is running.

The service closes the connection after any other first line, or a protocol it
doesn't speak (`unsupported-protocol`). It also closes it for a program that
isn't allowed (`not-allowed`); see [Permission](#permission).

### Requests and answers

After the handshake, a connection carries any number of requests, each answered
in turn. Every request has an `id`, a whole number the client chooses, which
comes back in its answer. To do several things at once, open several
connections.

```json
{"id":7,"command":"start","machine":"desk"}
{"id":7,"ok":true,"machines":[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"desk","state":"running",…}]}
```

The commands and their fields are those of the `swiftvm` tool. `swiftvm --json
<command>` prints the answer to each, and the fixtures in
`crates/swiftvm-protocol/tests/fixtures/api-v1` show every kind of request and
answer.

### Failures

A failure has `ok` false, and an `error` with a code and a message:

```json
{"id":7,"ok":false,"error":{"code":"wrong-state","message":"“desk” isn't running."},"machines":[]}
```

Act on the code; the message is for people and can change. The codes don't
change. New ones may be added, so treat a code you don't know as `failed`.

| Code | Meaning |
| --- | --- |
| `bad-request` | Something is missing from the request, or doesn't make sense |
| `unsupported-protocol` | The service doesn't speak the version of the API asked for |
| `not-allowed` | The program isn't allowed to use SwiftVM |
| `automation-off` | The machine doesn't take jobs or control: `swiftvm automation <machine> on` |
| `app-not-running` | The app, which does this, isn't running |
| `not-found` | No machine, template, snapshot, device or file goes by that name |
| `wrong-state` | The machine isn't in a state for this, such as running when it has to be shut down |
| `busy` | Something else is under way that this has to wait for |
| `timed-out` | It didn't happen in time. `wait` says what it is still waiting for |
| `guest-tools` | The guest tools aren't there, don't answer, or couldn't do it |
| `unavailable` | This computer can't do it, or isn't set up for it |
| `cancelled` | It was called off |
| `failed` | Anything else |

### Streams

After an answer that says yes, these commands turn the connection into a
stream:

| Command | The stream |
| --- | --- |
| `console` | The serial console's bytes, both ways |
| `vsock` | A connection to a port in the guest, both ways |
| `job` | A guest job's frames: one byte for the kind, four for the length, then the bytes |
| `control` | A `ControlOutcome` in frames |
| `watch` | Events, one per line |

Closing the connection ends the stream, and calls off a job.

### Events

`watch` is answered like `list`, with the machines and the machines being
created. Then the connection carries one event per line, until the client
closes it:

```json
{"event":"creation","creation":{"name":"box","system":"Ubuntu 24.04 LTS","status":"Preparing disk…","fraction":0.43}}
{"event":"creation-ended","creation":{"name":"box",…}}
{"event":"machine-added","machine":{"name":"box","state":"stopped",…}}
{"event":"machine-changed","machine":{"name":"box","state":"running","address":"192.168.64.5",…}}
{"event":"guest-tools","machine":{…},"guestTools":{"version":"1.8","kernel":"Linux 6.8"}}
```

| Event | When |
| --- | --- |
| `machine-added` | A machine is added to the library |
| `machine-changed` | A machine's state, name or address changes |
| `machine-removed` | A machine is deleted or moved out of the library. It carries the machine as it was |
| `guest-tools` | A machine's guest tools connect or go away, or setting up the guest moves on (`setup`) |
| `creation` | A machine is being created, its creation moves on, or it fails (`error`) |
| `creation-ended` | A creation is over. A `machine-added` follows when it worked out |
| `app` | The app starts or quits (`running`). After it starts, list again |

An event tells how the machine or creation is now, so hearing of one twice does
no harm. A client that falls far behind is let go, and watches again to catch
up. Skip events of a kind you don't know.

## Permission

The service knows a client by the program at the other end of the socket. The
`swiftvm` tool and the app need no permission. The first time another program
says hello, the app asks the person at the Mac whether to allow it, and the
service keeps the answer in `clients.json` in the data folder. Until then the
handshake waits, for two minutes at most. Without the app, the program is
refused, and `swiftvm clients allow <path>` allows it.

| Command | Does |
| --- | --- |
| `clients` | Lists the programs that were allowed or refused, in `clients` |
| `clients-allow`, `clients-deny` | Allows or refuses the program at `program`, a full path |
| `clients-remove` | Forgets what was decided for it, so that it is asked about again |

A script is known by its interpreter, such as `python3`: allowing it allows
every script it runs. This keeps other apps off the service. It doesn't stop a
program that runs `swiftvm`, which needs no permission, or one that talks to
the app's own `control.sock`, which any process of the user can still reach
while the app does the work. Step 3 of [the move to the
service](rust-migration.md) closes that socket to everything but the service.

## The service itself

| Command | Does |
| --- | --- |
| `service-stop` | Stops the service once the work under way is done |

`swiftvm service` shows the service and the machines it runs on QEMU, and
`swiftvm service stop` stops it. What the service says is in `service.log` in
the data folder.

## Engine requests

The service runs the app's QEMU machines (Windows, and Linux with graphics
acceleration). The app hands a machine over and drives it with these requests.
They are the app's: other clients use the commands above, and these may still
change. Each names the machine by `machine`, its UUID.

| Command | Does |
| --- | --- |
| `qemu-start` | Starts the machine in `bundle` with its guest held, from `savedState` if given. Descriptors ride on the request (`SCM_RIGHTS`), named in order by `descriptors`: `console`, one `network` per card, `display`. `diskSources` names the NBD socket of each compressed disk. Answers with `qemu`, then the connection carries the machine's events |
| `qemu-attach` | The machine's events, as after `qemu-start`. Answers with `qemu`, or with `exit` for a machine that ended meanwhile |
| `qemu-continue` | Lets a held guest run |
| `qemu-stop` | Asks QEMU to quit, or with `force` ends it at once. With `bundle` instead of `machine`, also ends a QEMU left behind for that bundle |
| `qemu-powerdown`, `qemu-pause`, `qemu-resume` | The power button, and pausing |
| `qemu-save` | Saves a paused machine's memory to `path` |
| `qemu-link` | Plugs the cable of network card `index` in or out (`connected`) |
| `qemu-attach-image`, `qemu-detach-image` | Plugs `image` in as a USB drive, or unplugs `imageId` |
| `qemu-connect` | A connection to `port` in the guest, over its agent's serial line. The connection carries it |
| `qemu-frame` | A picture of the display: `frame` with its size, then `length` bytes, four a pixel, blue first |
| `qemu-pointer`, `qemu-keys` | The machine's own mouse (`pointer`, as `GuestPointer`) and keyboard (`keys`) |
| `qemu-list` | The machines the service runs, in `qemuMachines` |

A machine's event stream ends with one line:

```json
{"event":"qemu-exited","machine":"4F2B1C9E-…","exit":{"reason":"guest-shutdown","expected":false}}
```

`reason` is QEMU's, such as `guest-shutdown` or `guest-reset`, and missing when
QEMU crashed; `message` then says what it said last. A stream that ends without
it means the service stopped: QEMU goes on running, and the next service takes
it on. `qemu-attach` there.

Each machine has a runtime folder for the sockets QEMU listens on, short enough
for a socket's path: `/tmp/swiftvm-<uid>/<data folder>/<machine>/` on a Mac,
`$XDG_RUNTIME_DIR/swiftvm/…` on Linux. Its `machine.json` is what the next
service reads to take the machine on.
