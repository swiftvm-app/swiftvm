#!/bin/bash
# Bootstraps the native Arch builder on a disposable Ubuntu ARM Actions runner.
# Uses the same signed Arch rootfs and pinned signing key as build-arch-image.sh.
#   sudo scripts/omarchy-image/build-on-ubuntu.sh OUTPUT
set -euo pipefail
umask 022

[[ $(id -u) == 0 && $(uname -m) == aarch64 ]] || {
  echo "This requires a disposable ARM64 Linux runner, as root." >&2
  exit 1
}
source=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "${1:?output directory required}"
output=$(cd "$1" && pwd)
work=$(mktemp -d /var/tmp/swiftvm-omarchy.XXXXXX)
root=$work/root
mkdir "$root"

cleanup() {
  local status=$?
  gpgconf --kill all 2>/dev/null || true
  if mountpoint -q "$root"; then
    umount -R "$root" || true
  fi
  if grep -q " $work/" /proc/mounts; then
    echo "Mounts remain in $work; leaving it intact." >&2
  else
    rm -rf --one-file-system "$work"
  fi
  exit "$status"
}
trap cleanup EXIT

# The rootfs mirror offers HTTP; only this exact signing key may authenticate it.
tarball=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
signing_key=68B3537F39A313B3E574D06777193F152BDBE6A6
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
curl -fsSL --retry 3 "$tarball" -o "$work/root.tar.gz"
curl -fsSL --retry 3 "$tarball.sig" -o "$work/root.tar.gz.sig"
curl -fsSL --retry 3 "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$signing_key" | gpg --quiet --import
verification=$(gpg --status-fd 1 --verify "$work/root.tar.gz.sig" "$work/root.tar.gz" 2>/dev/null) || true
grep -q "^\[GNUPG:\] VALIDSIG $signing_key " <<< "$verification" || {
  echo "Arch Linux ARM rootfs signature verification failed." >&2
  exit 1
}
bsdtar -xpf "$work/root.tar.gz" -C "$root"
rm "$work/root.tar.gz" "$work/root.tar.gz.sig"

# Keep all mounts under one private tree; package hooks must not unmount the runner's devices.
mount --bind "$root" "$root"
mount --make-private "$root"
mount -t proc proc "$root/proc"
mount --rbind --make-rslave /sys "$root/sys"
mount --rbind --make-rslave /dev "$root/dev"
mount -t tmpfs tmpfs "$root/run"
rm -f "$root/etc/resolv.conf"
cp /etc/resolv.conf "$root/etc/resolv.conf"
mkdir -p "$root/opt/swiftvm/scripts" "$root/output" "$root/work"
cp "$source/scripts/build-omarchy-image.sh" "$root/opt/swiftvm/scripts/"
cp -R "$source/scripts/omarchy-image" "$root/opt/swiftvm/scripts/"
mount --bind "$output" "$root/output"

# No Actions credentials or runner environment enter the builder. Package scripts run as root;
# publication therefore runs in a separate job with its own write-scoped token.
chroot "$root" /usr/bin/env -i HOME=/root PATH=/usr/bin:/usr/sbin \
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-swiftvm-app/swiftvm}" /bin/bash -euc '
    pacman-key --init
    pacman-key --populate archlinuxarm
    pacman -Sy --noconfirm archlinuxarm-keyring
    pacman -Syu --noconfirm --needed arch-install-scripts btrfs-progs dosfstools \
      e2fsprogs jq python qemu-img zstd curl
    bash /opt/swiftvm/scripts/build-omarchy-image.sh --output /output --work /work
  '
