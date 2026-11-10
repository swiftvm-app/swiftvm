# SSH

Every machine gets an SSH name made from its name: `Web Server` becomes
`web-server`. Use it to connect from your Mac without looking up addresses.

The SSH name stays when you rename the machine. To change it, set **Name** in the
**SSH** pane of the machine's settings. A Linux guest keeps the
host name it was created with.

## Connecting

```bash
swiftvm ssh web-server            # a shell in the guest
swiftvm ssh web-server uname -a   # or one command
```

From the app, choose **Open in Terminal** or **Copy SSH Command** in the
machine's menu.

### Plain `ssh`

Turn on **Settings → Network → Add machines to ~/.ssh/config** to connect with
just `ssh web-server`. It also makes `scp`, `rsync`, and editors that work over
SSH find your machines.

SwiftVM adds one `Include` line to your SSH configuration and changes nothing
else in the file. The machines themselves are listed in a file SwiftVM keeps
up to date.

## Keys

- SwiftVM uses the key you already have (`id_ed25519`, `id_ecdsa`, or
  `id_rsa` in `~/.ssh`). If you have none, it makes `~/.ssh/swiftvm_ed25519`.
- With **Sign in over SSH with my key** on, the key is installed in guests that
  SwiftVM sets up: [Quick Create](linux-guests.md#quick-create) Linux machines,
  [macOS](macos-guests.md) 27 or newer, and [Windows](windows-guests.md) when
  SSH installation succeeds.
- The guests' host keys are kept apart from your own `known_hosts`. A guest's
  key is accepted the first time you connect and checked from then on.

For a new account made with `swiftvm create`, `--ssh-identity <private-key-path>` selects an existing pair, or `--managed-ssh-key` creates or reuses a dedicated pair in `SSH Identity` inside the selected SwiftVM data folder. Managed selection does not consult personal keys. Without either option, the automatic selection above is unchanged. The two options are mutually exclusive, conflict with `--no-ssh-key`, and cannot be used with templates, which keep their existing account. An older app rejects explicit selection rather than falling back to its automatic choice.

Explicit selection requires an unencrypted private key and its matching adjacent `.pub` file. Both files and their folder must belong to the current user. Symbolic or multiple links refuse; the private key must not be accessible to other users, and the public key and folder must not be writable by them. Paths with control characters, quotes, backslashes, `#`, `$` or `%` refuse because SSH configuration can parse or expand them. Ordinary spaces are supported. Missing, mismatched, invalid, partial managed or unsafe identities fail without selecting another key or overwriting existing material.

Explicit encrypted keys refuse without prompting, including when an SSH agent has them loaded. Automatic selection retains its existing passphrase/agent behavior. A managed pair is generated without a passphrase in its private directory; it is published as a complete pair and reused thereafter. Only the public key is installed in the guest. The selected private-key path is used for bootstrap and generated SSH configuration with `IdentitiesOnly yes`; the private key stays on the host. macOS explicit selection needs an image that provisions an account with Remote Login, as macOS 27 does.

## Guests you installed yourself

A guest installed from a disc may have no SSH server. Install one in the
guest, add your public key to the account, and set **User** in the
**SSH** pane of the machine's settings. If the server listens on
another port than 22, set **Port** there too.

## Without a network

`--vsock` connects through the machine's own socket device, not its network.
It still works when the guest's network is down or its cable is pulled.

```bash
swiftvm ssh web-server --vsock
```

- It is for Linux guests. Ubuntu 26.04, Debian 13, Fedora 45, and Arch Linux ARM support it as they come;
  older systems such as Ubuntu 24.04 need the [guest tools](guest-tools.md).
- To use it from your own SSH configuration, for `scp`, `rsync`, or an editor:

```
Host web-server-vsock
    User user
    IdentityFile ~/.ssh/swiftvm_ed25519
    ProxyCommand swiftvm vsock web-server 22
```

Replace `user` and the key path with the guest's account and your SSH key.
`swiftvm ssh --vsock` uses the machine's configured account and key for you.
