#!/bin/sh
# name: KDE Plasma
# summary: The KDE Plasma desktop, with its own login screen
# category: desktop
# systems: ubuntu debian arch
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
    # Named, the login screen's own look is what gets installed. Left to the system, it picks
    # the one of another desktop.
    ubuntu) packages="kde-plasma-desktop sddm sddm-theme-breeze network-manager-config-connectivity-ubuntu spice-vdagent" ;;
    debian) packages="kde-plasma-desktop sddm network-manager-config-connectivity-debian firefox-esr spice-vdagent" ;;
    arch | archarm) packages="plasma-desktop sddm konsole dolphin plasma-nm networkmanager pipewire-pulse wireplumber firefox spice-vdagent" ;;
    *) echo "This script is written for Ubuntu, Debian and Arch Linux, not for $ID." >&2; exit 1 ;;
esac
# What the guest tools read the screen with, part by part, for whoever drives this machine from
# the Mac (swiftvm ui): the desktop's own accessibility, and what Python takes to ask it.
case $ID in
    arch | archarm) packages="$packages at-spi2-core python-gobject" ;;
    *) packages="$packages at-spi2-core python3-gi gir1.2-atspi-2.0" ;;
esac
# Ubuntu's kernel for virtual machines may come without the sound driver. The full one has it.
if [ "$ID" = ubuntu ] && ! modinfo virtio_snd > /dev/null 2>&1; then
    packages="$packages linux-image-generic"
fi

if command -v pacman > /dev/null; then
    echo "==> Getting the list of packages"
    # The keys that sign today's packages first, which may be newer than the system's.
    pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')

    echo "==> Downloading KDE Plasma"
    # The whole system is brought up to date with it: Arch Linux doesn't mix old packages with new.
    pacman -Su --noconfirm --needed --downloadonly $packages

    echo "==> Installing KDE Plasma"
    pacman -Su --noconfirm --needed $packages
    # One login screen at a time: a desktop installed before this one keeps its own.
    [ -e /etc/systemd/system/display-manager.service ] || systemctl enable sddm
    systemctl enable NetworkManager
else
    echo "==> Getting the list of packages"
    # A setup that was cut short carries on here. Unlike apt, dpkg doesn't wait for its lock.
    tries=0
    until dpkg --configure -a; do
        tries=$((tries + 1))
        [ "$tries" -lt 18 ] || exit 1
        sleep 10
    done
    apt_get update

    echo "==> Downloading KDE Plasma"
    apt_get install --download-only $packages

    echo "==> Installing KDE Plasma"
    apt_get install $packages

    if [ "$ID" = ubuntu ]; then
        echo "==> Installing Firefox"
        # Ubuntu's Firefox comes from its store, which may not answer. A desktop without a browser is
        # still a desktop.
        apt_get install firefox || echo "Firefox couldn't be installed. Install it later with: sudo apt install firefox"
    fi
fi

echo "==> Finishing"
if [ "$ID" != debian ]; then
    mkdir -p /etc/sddm.conf.d
    printf '[Theme]\nCurrent=breeze\n' > /etc/sddm.conf.d/90-swiftvm.conf
fi
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
