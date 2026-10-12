#!/bin/sh
# Installs the SwiftVM guest tools in a Linux system, or replaces an older copy of them.
#
# They are one small program, the guest agent, that lets the SwiftVM app on the Mac see this
# system's version and addresses, set its clock after the virtual machine was suspended, mount
# the folders shared with it and shut it down. For the swiftvm command on the Mac it runs
# commands here, shows the screen, and uses the mouse and the keyboard. It talks to the app over
# the virtual machine's socket device, so none of that needs a network.
#
# Run it as root:    sudo sh install.sh
# To remove it all:  sudo sh install.sh --remove
#
# Everything it installs is in this file, in plain text, below.
set -eu

directory=/usr/local/lib/swiftvm
units=/etc/systemd/system

fail() {
    echo "swiftvm: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "this has to run as root, for example: sudo sh $0"
command -v systemctl >/dev/null 2>&1 || fail "this system doesn't use systemd, which the guest agent needs"

if [ "${1:-}" = "--remove" ]; then
    systemctl disable --now swiftvm-agent.service swiftvm-sshd-vsock.socket >/dev/null 2>&1 || true
    rm -f "$units/swiftvm-agent.service" "$units/swiftvm-sshd-vsock.socket" "$units/swiftvm-sshd-vsock@.service"
    # What ran this machine's setup scripts lives in the same place, and goes with it. The note that
    # they have run stays, in /var/lib/swiftvm: a copy of this machine goes through its first-boot
    # setup once more, and that note is what keeps the scripts from running a second time.
    systemctl disable swiftvm-setup.service >/dev/null 2>&1 || true
    rm -f "$units/swiftvm-setup.service"
    rm -rf "$directory"
    systemctl daemon-reload
    echo "The SwiftVM guest tools are removed."
    exit 0
fi

[ -x /usr/bin/python3 ] || fail "the guest agent needs Python 3 at /usr/bin/python3. Install it and run this again"

mkdir -p "$directory"
umask 022

cat > "$directory/swiftvm-agent.py.new" <<'SWIFTVM_END_OF_FILE'
@@swiftvm-agent.py@@
SWIFTVM_END_OF_FILE
chmod 755 "$directory/swiftvm-agent.py.new"
mv -f "$directory/swiftvm-agent.py.new" "$directory/swiftvm-agent.py"

cat > "$units/swiftvm-agent.service" <<'SWIFTVM_END_OF_FILE'
@@swiftvm-agent.service@@
SWIFTVM_END_OF_FILE

cat > "$units/swiftvm-sshd-vsock.socket" <<'SWIFTVM_END_OF_FILE'
@@swiftvm-sshd-vsock.socket@@
SWIFTVM_END_OF_FILE

cat > "$units/swiftvm-sshd-vsock@.service" <<'SWIFTVM_END_OF_FILE'
@@swiftvm-sshd-vsock@.service@@
SWIFTVM_END_OF_FILE

# A copy of this file stays behind, for removing the tools again. It may be the file that is running,
# under another spelling of its name: then there is nothing to copy, and cp saying so is no failure.
case "$0" in
    */install.sh | install.sh) cp "$0" "$directory/install.sh" 2>/dev/null || true ;;
esac

systemctl daemon-reload
systemctl --quiet enable swiftvm-agent.service swiftvm-sshd-vsock.socket
# Restarting is what puts a newer agent in the place of a running older one.
systemctl restart swiftvm-agent.service
# Does nothing where systemd itself already puts the SSH server on the socket device.
systemctl start swiftvm-sshd-vsock.socket >/dev/null 2>&1 || true

echo "The SwiftVM guest tools are installed."
