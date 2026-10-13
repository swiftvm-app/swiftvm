# SSH

Every machine gets an SSH name made from its name: `Web Server` becomes
`web-server`. Use it to connect from your Mac without looking up addresses.

The SSH name stays when you rename the machine. To change it, set **SSH Name**
under **Network and SSH** in the machine's settings. A Linux guest keeps the
host name it was created with.

## Connecting

```bash
swiftvm ssh web-server            # a shell in the guest
swiftvm ssh web-server uname -a   # or one command
```

From the app, choose **Open in Terminal** or **Copy SSH Command** in the
machine's menu.

### Plain `ssh`

Turn on **Settings → SSH → Add machines to ~/.ssh/config** to connect with
just `ssh web-server`. It also makes `scp`, `rsync`, and editors that work over
SSH find your machines.

SwiftVM adds one `Include` line to your SSH configuration and changes nothing
else in the file. The machines themselves are listed in a file SwiftVM keeps
up to date.

## Keys

- SwiftVM uses the key you already have (`id_ed25519`, `id_ecdsa`, or
  `id_rsa` in `~/.ssh`). If you have none, it makes `~/.ssh/swiftvm_ed25519`.
- With **Sign in over SSH with my key** on, the key is installed in guests that
  SwiftVM sets up: [Quick Create](linux-guests.md#quick-create) Linux machines
  and [macOS](macos-guests.md) 27 or newer.
- The guests' host keys are kept apart from your own `known_hosts`. A guest's
  key is accepted the first time you connect and checked from then on.

## Guests you installed yourself

A guest installed from a disc may have no SSH server. Install one in the
guest, add your public key to the account, and set **SSH User** under
**Network and SSH** in the machine's settings. If the server listens on
another port than 22, set **SSH Port** there too.

## Without a network

`--vsock` connects through the machine's own socket device, not its network.
It still works when the guest's network is down or its cable is pulled.

```bash
swiftvm ssh web-server --vsock
```

- It is for Linux guests. Ubuntu 26.04 and Debian 13 support it as they come;
  older systems such as Ubuntu 24.04 need the [guest tools](guest-tools.md).
- To use it from your own SSH configuration, for `scp`, `rsync`, or an editor:

```
Host web-server-vsock
    ProxyCommand swiftvm vsock web-server 22
```
