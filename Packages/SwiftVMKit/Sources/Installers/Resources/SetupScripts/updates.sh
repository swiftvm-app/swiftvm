#!/bin/sh
# name: Updates
# summary: The updates the system has waiting, and a restart into the new kernel
# category: system
# systems: ubuntu debian
# restart: yes

set -eu

echo "==> Getting the list of updates"
apt-get update

echo "==> Installing updates"
apt-get full-upgrade -y
