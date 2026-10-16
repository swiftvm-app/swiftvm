#!/bin/bash
# Builds the disk image that SwiftVM's Arch Linux ARM machines start from: Arch Linux ARM, set up the
# way a cloud image is, for cloud-init to configure on a machine's first start. Arch Linux publishes no
# such image for 64-bit ARM, which is all a Mac runs. The release workflow (build-arch-image.yml) runs
# this, and the image it publishes goes into Packages/SwiftVMKit/Sources/Installers/Resources/
# distributions.json, by its address and SHA-256.
#   sudo scripts/build-arch-image.sh [output folder]
#
# It runs as root on 64-bit ARM Linux (a Debian or Ubuntu system with libarchive-tools, dosfstools,
# fdisk, e2fsprogs, gpg, curl and qemu-utils), and writes archlinuxarm-<date>.qcow2 and a SHA256SUMS
# for it into the output folder, ./output when none is given.
#
# The image starts from Arch Linux ARM's own root file system, which its build key signs. What is done
# to it, and why:
#   - The packages are brought up to date, and cloud-init, GRUB and growpart added.
#   - The accounts the tarball comes with are taken out: both have a password everyone knows. The one
#     account a machine has is the one SwiftVM asks cloud-init for.
#   - cloud-init looks for SwiftVM's seed disc and nothing else, so that it doesn't spend minutes asking
#     a cloud for settings first. It configures the network with systemd-networkd, which asks DHCP for
#     an address by the card's MAC address: that is what the Mac keeps the machine's address by.
#   - The kernel writes to the serial console (hvc0) too, where `swiftvm console` reads it.
#   - What makes a system one of a kind (machine ID, SSH host keys, the package manager's keys) is left
#     out, for each machine to make its own on its first start.
set -euo pipefail

output=${1:-output}
tarball_url=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
# Arch Linux ARM Build System <builder@archlinuxarm.org>. The tarball comes over plain HTTP, which is
# all that server offers, so the signature is what says it is theirs.
signing_key=68B3537F39A313B3E574D06777193F152BDBE6A6
# The disk as it is published. A machine's own is larger: its root partition grows into the space on
# its first start.
size=6G
name=archlinuxarm-$(date -u +%Y.%m.%d)

fail() {
    echo "$1" >&2
    exit 1
}

[[ $(id -u) == 0 ]] || fail "This has to run as root, for example: sudo $0"
[[ $(uname -m) == aarch64 ]] || fail "This has to run on 64-bit ARM Linux: the image's packages are set up by running them."
for command in bsdtar curl gpg losetup mkfs.ext4 mkfs.vfat qemu-img sfdisk; do
    command -v $command > /dev/null || fail "$command is missing."
done

mkdir -p "$output"
output=$(cd "$output" && pwd)
# Not /tmp, which may be in memory: the disk alone is gigabytes.
work=$(mktemp -d -p /var/tmp)
root=$work/root
loop=''

cleanup() {
    if mountpoint -q "$root"; then
        umount -R "$root" || umount -R --lazy "$root" || true
    fi
    [[ -z $loop ]] || losetup -d "$loop" 2> /dev/null || true
    # The system's own /dev and /sys are mounted in there while it is set up. Whatever is still
    # mounted stays, and the rest is left where it is with it.
    if grep -q " $work/" /proc/mounts; then
        echo "Something is still mounted in $work, which is left as it is." >&2
    else
        rm -rf --one-file-system "$work"
    fi
}
trap cleanup EXIT

echo "==> Downloading Arch Linux ARM"
curl -fsSL -o "$work/root.tar.gz" "$tarball_url"
curl -fsSL -o "$work/root.tar.gz.sig" "$tarball_url.sig"
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$signing_key" | gpg --quiet --import
# Signed by that key, and no other: a key that the keyserver handed over besides counts for nothing.
verification=$(gpg --status-fd 1 --verify "$work/root.tar.gz.sig" "$work/root.tar.gz" 2> /dev/null) || true
grep -q "^\[GNUPG:\] VALIDSIG $signing_key " <<< "$verification" ||
    fail "The tarball's signature isn't one of Arch Linux ARM's build key."

echo "==> Making the disk"
disk=$work/disk.img
truncate -s $size "$disk"
# An EFI system partition for the boot loader, and the root partition after it, which grows into what
# the machine's disk has to spare. The root partition is typed as one for 64-bit ARM.
sfdisk --quiet "$disk" << 'END'
label: gpt
size=300MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name="root"
END
loop=$(losetup --find --show --partscan "$disk")
mkfs.vfat -F 32 -n EFI "${loop}p1" > /dev/null
mkfs.ext4 -q -L root "${loop}p2"
mkdir "$root"
mount "${loop}p2" "$root"

echo "==> Unpacking Arch Linux ARM"
bsdtar -xpf "$work/root.tar.gz" -C "$root"
mkdir -p "$root/efi"
mount "${loop}p1" "$root/efi"
mount -t proc proc "$root/proc"
# Unmounting these again mustn't take the system's own along.
mount --rbind --make-rslave /sys "$root/sys"
mount --rbind --make-rslave /dev "$root/dev"
mount -t tmpfs tmpfs "$root/run"
# The image's own points at systemd-resolved, which doesn't run in here.
rm -f "$root/etc/resolv.conf"
cp -L /etc/resolv.conf "$root/etc/resolv.conf"

echo "==> Setting the system up"
chroot "$root" /bin/bash -euo pipefail << 'END'
export LANG=C.UTF-8
pacman-key --init
pacman-key --populate archlinuxarm
# Firmware for hardware that a virtual machine doesn't have, a gigabyte of it, and the network tools
# that systemd-networkd stands in for.
pacman -Rns --noconfirm linux-firmware netctl dhcpcd
# The keys first: one that signs today's packages may be newer than the tarball.
pacman -Sy --noconfirm --needed archlinuxarm-keyring
pacman -Su --noconfirm
pacman -S --noconfirm --needed cloud-init cloud-guest-utils grub efibootmgr python sudo openssh inetutils

# Nobody signs in with the tarball's accounts: alarm/alarm and root/root.
userdel --remove alarm
passwd --lock root
echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# The drivers of a Mac's virtual machines, whatever system the image is built on: the initramfs is
# otherwise made for the devices of the machine building it.
sed -i 's/^MODULES=()/MODULES=(virtio_pci virtio_blk virtio_net virtio_console virtiofs)/' /etc/mkinitcpio.conf
grep -q '^MODULES=(virtio_pci ' /etc/mkinitcpio.conf
mkinitcpio -P

# The kernel's messages go to the serial console too. The display (tty1) is named last, so that it
# stays the console that systemd reports to.
sed -i -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' \
    -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 console=hvc0 console=tty1"/' /etc/default/grub
# Arch Linux ARM's kernel is /boot/Image, and grub-mkconfig doesn't find an initramfs by that name.
echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="initramfs-linux.img"' >> /etc/default/grub
# Where the firmware looks when it has no boot entries of its own, which a new machine doesn't.
grub-install --target=arm64-efi --efi-directory=/efi --removable --no-nvram
grub-mkconfig -o /boot/grub/grub.cfg
# The root file system goes by the name of the loop device it is on while the image is built, which
# no machine has. It is found by its identifier instead.
device=$(findmnt -no SOURCE /)
uuid=$(findmnt -no UUID /)
sed -i "s|root=$device |root=UUID=$uuid |" /boot/grub/grub.cfg
grep -q "root=UUID=$uuid " /boot/grub/grub.cfg
if grep -q "root=$device " /boot/grub/grub.cfg; then
    exit 1
fi

# Only the seed disc a machine is made with: the clouds that cloud-init would ask first would keep a
# first start waiting for minutes.
cat > /etc/cloud/cloud.cfg.d/90-swiftvm.cfg << 'CONFIG'
datasource_list: [NoCloud, None]
system_info:
  distro: arch
# The network is configured by the file below. What cloud-init writes for systemd-networkd leaves out
# that DHCP is to be asked by the card's MAC address.
network:
  config: disabled
CONFIG
# Every wired card asks DHCP for an address by its MAC address, which is what the Mac keeps the
# machine's address by. A copy of a machine, with a card of its own, is asked for by that one's.
rm -f /etc/systemd/network/en.network /etc/systemd/network/eth.network
cat > /etc/systemd/network/20-wired.network << 'NETWORK'
[Match]
Type=ether

[Network]
DHCP=yes

[DHCPv4]
ClientIdentifier=mac
NETWORK
systemctl enable cloud-init-main.service cloud-init-local.service cloud-init-network.service \
    cloud-config.service cloud-final.service

# Each machine makes the package manager's keys of its own on its first start, before anything installs.
cat > /etc/systemd/system/pacman-init.service << 'UNIT'
[Unit]
Description=Initialize the package manager's keyring
# The keyring's sockets turn up in the folder before this runs, so its trust database is what tells.
ConditionPathExists=!/etc/pacman.d/gnupg/trustdb.gpg
Before=cloud-final.service

[Service]
Type=oneshot
ExecStart=/usr/bin/pacman-key --init
ExecStart=/usr/bin/pacman-key --populate archlinuxarm

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable pacman-init.service

pacman -Scc --noconfirm
END

echo "==> Leaving out what makes a system one of a kind"
rm -rf "$root/etc/pacman.d/gnupg"
mkdir -m 755 "$root/etc/pacman.d/gnupg"
rm -f "$root"/etc/ssh/ssh_host_*
: > "$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id"
rm -rf "$root"/var/log/* "$root"/var/cache/pacman/pkg/* "$root/root/.bash_history" "$root"/tmp/*
ln -sf /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
# The disk is found by its file systems' identifiers, which stay with the image.
cat > "$root/etc/fstab" << END
UUID=$(blkid -s UUID -o value "${loop}p2") / ext4 rw,relatime 0 1
UUID=$(blkid -s UUID -o value "${loop}p1") /efi vfat rw,relatime,fmask=0077,dmask=0077 0 2
END

echo "==> Packing the image"
sync
umount -R "$root"
losetup -d "$loop"
loop=''
# Compressed with zlib, which SwiftVM reads.
qemu-img convert -c -f raw -O qcow2 -o compression_type=zlib "$disk" "$output/$name.qcow2"
(cd "$output" && sha256sum "$name.qcow2" > SHA256SUMS)
cat "$output/SHA256SUMS"
