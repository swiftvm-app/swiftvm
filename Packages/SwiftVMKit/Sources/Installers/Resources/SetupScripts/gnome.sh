#!/bin/sh
# name: GNOME
# summary: The GNOME desktop, as Ubuntu and Debian set it up
# category: desktop
# systems: ubuntu debian
# memory: 4
# disk: 24
# restart: yes
#
# A setup script for SwiftVM. It runs as root in a new virtual machine the first time the machine
# starts. The lines above say what it is; a line it prints that starts with "==> " is the step
# SwiftVM shows. How these scripts are written: https://swiftvm.app/docs/features/setup-scripts/

set -eu
. /etc/os-release
export DEBIAN_FRONTEND=noninteractive

# apt, with an answer to everything it could ask. It waits for the package lock, which the
# system's own updates may hold on a first start.
apt_get() {
    apt-get -y -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

case $ID in
    # A minus takes a package out: the assistant that would ask for an account that is there
    # already, and Firefox, which has a step of its own further down.
    ubuntu) packages="ubuntu-desktop-minimal network-manager-config-connectivity-ubuntu spice-vdagent gnome-initial-setup- firefox-" ;;
    debian) packages="gnome-core network-manager-config-connectivity-debian firefox-esr spice-vdagent gnome-initial-setup-" ;;
    *) echo "This script is written for Ubuntu and Debian, not for $ID." >&2; exit 1 ;;
esac
# What the guest tools read the screen with, part by part, for whoever drives this machine from
# the Mac (swiftvm ui): the desktop's own accessibility, and what Python takes to ask it.
packages="$packages at-spi2-core python3-gi gir1.2-atspi-2.0"
# Ubuntu's kernel for virtual machines may come without the sound driver. The full one has it.
if [ "$ID" = ubuntu ] && ! modinfo virtio_snd > /dev/null 2>&1; then
    packages="$packages linux-image-generic"
fi

echo "==> Getting the list of packages"
# A setup that was cut short carries on here. Unlike apt, dpkg doesn't wait for its lock.
tries=0
until dpkg --configure -a; do
    tries=$((tries + 1))
    [ "$tries" -lt 18 ] || exit 1
    sleep 10
done
apt_get update

echo "==> Downloading GNOME"
apt_get install --download-only $packages

echo "==> Installing GNOME"
apt_get install $packages

if [ "$ID" = ubuntu ]; then
    echo "==> Installing Firefox"
    # Ubuntu's Firefox comes from its store, which may not answer. A desktop without a browser is
    # still a desktop.
    apt_get install firefox || echo "Firefox couldn't be installed. Install it later with: sudo apt install firefox"
fi

echo "==> Finishing"
# The network card stays with the service that has it, which asks for an address by the card's
# own: that is what the Mac keeps the machine's address by. The desktop's NetworkManager only
# watches the card, so that the desktop knows it is online. Two services that both configure
# one card would take turns at undoing each other's work.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/zz-swiftvm.conf << 'END'
[main]
no-auto-default=*

[keyfile]
unmanaged-devices=

[device-swiftvm]
match-device=type:ethernet
managed=1
END
# Ubuntu's desktop would hand every card to NetworkManager.
if [ -e /usr/lib/netplan/00-network-manager-all.yaml ]; then
    printf 'network:\n  version: 2\n  renderer: networkd\n' > /etc/netplan/00-network-manager-all.yaml
    chmod 600 /etc/netplan/00-network-manager-all.yaml
fi
# The Mac suspends the virtual machine. A system that goes to sleep by itself may not wake up.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl set-default graphical.target
[ -e /etc/systemd/system/display-manager.service ] || { echo "No login screen was installed." >&2; exit 1; }
