#!/bin/sh
# name: Hyprland
# summary: The Hyprland tiling compositor, with a bar and a launcher
# category: desktop
# systems: arch
# memory: 4
# disk: 16
# restart: yes
#
# A setup script for SwiftVM. It runs as root in a new virtual machine the first time the machine
# starts. The lines above say what it is; a line it prints that starts with "==> " is the step
# SwiftVM shows. How these scripts are written: https://swiftvm.app/docs/features/setup-scripts/
#
# Hyprland draws with OpenGL, which a virtual machine on a Mac does on its processors: give the
# machine a few of them. Super is the Command key: Command-Q opens a terminal, Command-R the
# launcher, and Command-M leaves Hyprland.

set -eu
. /etc/os-release

case $ID in
    arch | archarm) ;;
    *) echo "This script is written for Arch Linux, not for $ID." >&2; exit 1 ;;
esac
# The compositor and what its own configuration starts: kitty, Dolphin and hyprlauncher. Then a
# bar, what lets applications share the screen and ask for a password, sound, a login screen and
# a browser.
packages="hyprland kitty dolphin hyprlauncher waybar woff2-font-awesome noto-fonts xdg-desktop-portal-hyprland
    hyprpolkitagent qt6-wayland xorg-xwayland pipewire-pulse wireplumber sddm firefox spice-vdagent"
# What the guest tools read the screen with, part by part, for whoever drives this machine from
# the Mac (swiftvm ui): the desktop's own accessibility, and what Python takes to ask it.
packages="$packages at-spi2-core python-gobject"

echo "==> Getting the list of packages"
# The keys that sign today's packages first, which may be newer than the system's.
pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')

echo "==> Downloading Hyprland"
# The whole system is brought up to date with it: Arch Linux doesn't mix old packages with new.
pacman -Su --noconfirm --needed --downloadonly $packages

echo "==> Installing Hyprland"
pacman -Su --noconfirm --needed $packages

echo "==> Finishing"
# Hyprland's own configuration, without the note that it was made for nobody in particular, and
# with the bar. One the account has already stays as it is.
home=$(getent passwd "$SWIFTVM_USER" | cut -d: -f6)
config=$home/.config/hypr/hyprland.lua
if [ -n "$home" ] && [ ! -e "$config" ]; then
    mkdir -p "$home/.config/hypr"
    {
        cat /usr/share/hypr/hyprland.lua
        printf '\n-- Added by SwiftVM: the bar.\nhl.on("hyprland.start", function ()\n    hl.exec_cmd("waybar")\nend)\n'
        # Animations cost the most when the drawing is done by the processors.
        printf '\n-- Added by SwiftVM: a virtual machine on a Mac draws on its processors, where animations\n-- cost the most. Take this line out to have them back.\nhl.config({ animations = { enabled = false } })\n'
    } > "$config"
    chown -R "$SWIFTVM_USER:" "$home/.config"
fi
# The Mac suspends the virtual machine. A system that goes to sleep by itself may not wake up.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# One login screen at a time: a desktop installed before this one keeps its own.
[ -e /etc/systemd/system/display-manager.service ] || systemctl enable sddm
systemctl set-default graphical.target
