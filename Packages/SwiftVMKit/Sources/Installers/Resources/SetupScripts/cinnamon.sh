#!/bin/sh
# name: Cinnamon
# summary: The desktop of Linux Mint, from the distribution's own packages
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
    ubuntu) packages="cinnamon-core lightdm slick-greeter network-manager-config-connectivity-ubuntu spice-vdagent" ;;
    debian) packages="cinnamon-core lightdm slick-greeter network-manager-config-connectivity-debian firefox-esr spice-vdagent" ;;
    *) echo "This script is written for Ubuntu and Debian, not for $ID." >&2; exit 1 ;;
esac
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

echo "==> Downloading Cinnamon"
apt_get install --download-only $packages

echo "==> Installing Cinnamon"
apt_get install $packages

if [ "$ID" = ubuntu ]; then
    echo "==> Installing Firefox"
    # Ubuntu's Firefox comes from its store, which may not answer. A desktop without a browser is
    # still a desktop.
    apt_get install firefox || echo "Firefox couldn't be installed. Install it later with: sudo apt install firefox"
fi

echo "==> Finishing"
# The login screen and the desktop it starts, by name: more than one of each may be installed.
# The account is offered there rather than asked for by name.
# A virtual machine draws without graphics acceleration, which is what "cinnamon2d" is for.
session=cinnamon
[ ! -e /usr/share/xsessions/cinnamon2d.desktop ] || session=cinnamon2d
mkdir -p /etc/lightdm/lightdm.conf.d
printf '[Seat:*]\ngreeter-session=slick-greeter\nuser-session=%s\ngreeter-hide-users=false\n' "$session" > /etc/lightdm/lightdm.conf.d/90-swiftvm.conf
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
