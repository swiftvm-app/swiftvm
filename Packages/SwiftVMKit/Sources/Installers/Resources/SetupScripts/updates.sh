#!/bin/sh
# name: Updates
# summary: The updates the system has waiting, and a restart into the new kernel
# category: system
# systems: ubuntu debian arch
# restart: yes

set -eu

echo "==> Getting the list of updates"
if command -v pacman > /dev/null; then
    # The keys that sign today's packages first, which may be newer than the system's.
    pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')

    echo "==> Installing updates"
    pacman -Su --noconfirm
else
    apt-get update

    echo "==> Installing updates"
    apt-get full-upgrade -y
fi
