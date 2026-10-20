#!/bin/bash
# name: Omarchy (ARM edge)
# summary: Omarchy's upstream ARM desktop, from a ready-made image
# category: desktop
# systems: arch
# memory: 8
# disk: 64
# graphics: recommended
# restart: yes
#
# A setup script for SwiftVM. It runs as root in a new virtual machine the first time the machine
# starts. The lines above say what it is; a line it prints that starts with "==> " is the step
# SwiftVM shows. How these scripts are written: https://swiftvm.app/docs/features/setup-scripts/
#
# The desktop and applications are installed when the image is built, not compiled in every new
# machine. Omarchy owns its packages and updates; this finishes setup for the account from the seed.

set -euo pipefail
[[ $(uname -m) == aarch64 && -f /usr/local/share/swiftvm/omarchy-image ]] || {
    echo "This script needs SwiftVM's ready-made Omarchy ARM image. Create an Arch machine with the built-in Omarchy setup." >&2
    exit 1
}
home=$(getent passwd "$SWIFTVM_USER" | cut -d: -f6)
[[ -n $home && -d $home ]] || { echo "There is no home folder for $SWIFTVM_USER." >&2; exit 1; }

# The image defers hardware detection and its package-manager identity to each machine. This also
# waits for the upstream first-boot service if it is already doing that work.
echo "==> Preparing Omarchy for this machine"
omarchy-provision-hardware

# Limine keys its entries by machine ID. Keeping the factory's entry would leave a stale UKI hash
# after the first kernel update, so give this machine its own entries, as upstream's owner setup does.
machine_id=$(cat /etc/machine-id)
mapfile -t image_ids < <(grep -oE 'machine-id=[0-9a-f]{32}' /boot/limine.conf | cut -d= -f2 | sort -u || true)
if [[ ${image_ids[*]} != "$machine_id" ]]; then
    cp /usr/share/omarchy/default/limine/limine.conf /boot/limine.conf
    for old_id in "${image_ids[@]}"; do
        [[ $old_id == "$machine_id" ]] || rm -rf "/boot/$old_id"
    done
    limine-update
fi

# Replay upstream's account groups, without granting Docker's root-equivalent access by default.
# Raw input access is only granted when the package that needs it is installed, as upstream does.
groups=(wheel)
if [[ -f /var/lib/omarchy/provisioning/groups ]]; then
    while IFS= read -r group; do
        [[ -n $group && $group != docker ]] || continue
        if [[ $group == input ]] && ! pacman -Qq xpadneo-dkms &>/dev/null && ! pacman -Qq ydotool &>/dev/null; then
            continue
        fi
        getent group "$group" >/dev/null && groups+=("$group")
    done < /var/lib/omarchy/provisioning/groups
fi
usermod -aG "$(IFS=,; echo "${groups[*]}")" "$SWIFTVM_USER"

echo "==> Setting Omarchy up for $SWIFTVM_USER"
# Node is bundled in the image. Resolving every optional tool's latest version here otherwise
# waits on the network even though account provisioning needs none of those downloads.
runuser -u "$SWIFTVM_USER" -- env HOME="$home" USER="$SWIFTVM_USER" LOGNAME="$SWIFTVM_USER" \
    SHELL=/bin/bash OMARCHY_SETUP_CONTEXT=provision-owner MISE_OFFLINE=true \
    omarchy-provision-user --first-install

# Upstream conservatively disables effects in every VM. Keep that for software rendering, but let
# a GPU-backed desktop use its normal effects. These are first-account defaults, not update hooks.
if grep -Eq '^virgl[[:space:]]*:[[:space:]]*yes$' /sys/kernel/debug/dri/*/virtio-gpu-features 2>/dev/null; then
    rm -f "$home/.local/state/omarchy/toggles/hypr/no-animations.lua" \
        "$home/.local/state/omarchy/toggles/hypr/window-opaque.lua"
fi

# Offer the account and Omarchy session at the login screen, without an automatic login or a
# password kept on disk beyond cloud-init's first-boot data.
mkdir -p /var/lib/sddm
printf '[Last]\nSession=/usr/share/wayland-sessions/omarchy.desktop\nUser=%s\n' "$SWIFTVM_USER" > /var/lib/sddm/state.conf
chown -R sddm:sddm /var/lib/sddm

echo "==> Finishing"
systemctl set-default graphical.target
