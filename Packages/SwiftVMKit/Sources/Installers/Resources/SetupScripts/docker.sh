#!/bin/sh
# name: Docker
# summary: Docker Engine, for the account to use without sudo
# category: development
# systems: ubuntu debian fedora arch
# memory: 2
# disk: 16

set -eu

echo "==> Installing Docker"
if command -v pacman > /dev/null; then
    # The keys that sign today's packages first, which may be newer than the system's.
    pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')
    pacman -Su --noconfirm --needed docker
    systemctl enable docker.service
    # Bringing the system up to date may have replaced the kernel that runs, and with it the modules
    # Docker needs. Then it starts with the system's next start.
    systemctl start docker.service || echo "Docker starts once the system is restarted."
elif command -v dnf > /dev/null; then
    # Fedora's build of Docker Engine, which it calls Moby.
    dnf -y install moby-engine
    systemctl enable --now docker.service
else
    apt-get update
    apt-get install -y docker.io
fi

echo "==> Letting $SWIFTVM_USER use it"
usermod -aG docker "$SWIFTVM_USER"
