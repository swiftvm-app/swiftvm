#!/bin/sh
# name: Docker
# summary: Docker Engine, for the account to use without sudo
# category: development
# systems: ubuntu debian
# memory: 2
# disk: 16

set -eu

echo "==> Installing Docker"
apt-get update
apt-get install -y docker.io

echo "==> Letting $SWIFTVM_USER use it"
usermod -aG docker "$SWIFTVM_USER"
