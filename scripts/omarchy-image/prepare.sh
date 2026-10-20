#!/bin/bash
# Runs in the image's chroot, after Omarchy has configured the system. The desktop, kernel and
# updates stay upstream's; only account provisioning, guest tools and the VM's network are SwiftVM's.
set -euo pipefail

passwd --lock root
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/90-swiftvm.cfg << 'END'
datasource_list: [NoCloud, None]
system_info:
  distro: arch
network:
  config: disabled
END
systemctl enable cloud-init-main.service cloud-init-local.service cloud-init-network.service \
    cloud-config.service cloud-final.service sshd.service

# Omarchy already uses NetworkManager. Keep it the only owner of the card, and ask for DHCP by
# the card's address, which is how the Mac identifies a machine (including a clone).
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/90-swiftvm.conf << 'END'
[connection]
ipv4.dhcp-client-id=mac
END
systemctl disable systemd-networkd.service systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# The chroot shares the builder's kernel. Add the rule while UFW is inactive in its configuration,
# then restore upstream's boot-time enablement without trying to alter the builder's firewall.
sed -i 's/^ENABLED=.*/ENABLED=no/' /etc/ufw/ufw.conf
ufw allow 22/tcp
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf

# The seed creates the account and schedules its setup before the login screen offers it. No
# factory account, password, or host SSH key is carried in a published image.
mkdir -p /etc/systemd/system/sddm.service.d
cat > /etc/systemd/system/sddm.service.d/90-swiftvm.conf << 'END'
[Unit]
After=cloud-final.service swiftvm-setup.service
END
rm -f /var/lib/omarchy/provisioning/pending
systemctl disable omarchy-provision-owner.service 2>/dev/null || true

# The console is a virtio device on both SwiftVM engines. UEFI and Omarchy retain ownership of
# the boot chain, so updates keep using the guest's own kernel rather than a host-supplied one.
cat > /etc/limine-entry-tool.d/50-swiftvm-console.conf << 'END'
KERNEL_CMDLINE[default]+=" console=hvc0 console=tty0"
END
cat > /etc/mkinitcpio.conf.d/50-swiftvm.conf << 'END'
MODULES+=(virtio_pci virtio_blk virtio_net virtio_console virtio_gpu virtiofs 9p 9pnet_virtio)
END

mkdir -p /usr/local/share/swiftvm
pacman -Q omarchy-dev omarchy-settings-dev linux-omarchy > /usr/local/share/swiftvm/omarchy-image
