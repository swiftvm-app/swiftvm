#!/bin/bash
# name: Omarchy (experimental)
# summary: DHH's Hyprland desktop, from Omarchy's own source on Arch Linux ARM
# category: desktop
# systems: arch
# memory: 8
# disk: 32
# restart: yes
#
# A setup script for SwiftVM. It runs as root in a new virtual machine the first time the machine
# starts. The lines above say what it is; a line it prints that starts with "==> " is the step
# SwiftVM shows. How these scripts are written: https://swiftvm.app/docs/features/setup-scripts/
#
# Omarchy (https://omarchy.org) is made for Arch Linux on PCs, and its package repository has
# nothing for 64-bit ARM yet. This puts one release of its source in place the way its own package
# does, on Arch Linux ARM's packages, after Try Omarchy (https://github.com/omacom/try-omarchy, MIT).
# What Omarchy brings from its own repository, or from the AUR, isn't there: walker, mise, yay,
# Omarchy's own apps and its fonts. The rest of the desktop is.
#
# Hyprland draws with OpenGL, which a virtual machine on a Mac does on its processors: give the
# machine a few of them. Super is the Command key.

set -euo pipefail
. /etc/os-release

case $ID in
    arch | archarm) ;;
    *) echo "This script is written for Arch Linux, not for $ID." >&2; exit 1 ;;
esac

version=4.0.4
repository=https://github.com/basecamp/omarchy.git
# The release, by its commit: a tag can be moved, a commit can't.
commit=c668141e9c42b13c80c9ca4ea108e11708c5e8a5

# What Omarchy's desktop runs on, as far as Arch Linux ARM has it.
packages=(
    hyprland hyprpicker hyprsunset hyprlock hypridle quickshell uwsm xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk qt6-wayland qt6-imageformats xorg-xwayland mesa vulkan-swrast
    sddm polkit gnome-keyring libsecret networkmanager power-profiles-daemon
    pipewire pipewire-alsa pipewire-pulse wireplumber pamixer playerctl brightnessctl
    foot xdg-terminal-exec chromium nautilus gvfs udiskie imv mpv
    fcitx5 fcitx5-gtk fcitx5-qt
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd woff2-font-awesome fontconfig
    bash-completion bat btop dua-cli eza fastfetch fd fzf git gum jq less man-db neovim ripgrep
    starship tmux unzip zoxide imagemagick inotify-tools libnotify slurp grim socat wl-clipboard
    desktop-file-utils shared-mime-info xdg-user-dirs xdg-utils pacman-contrib python
    spice-vdagent
)
# What the guest tools read the screen with, part by part, for whoever drives this machine from
# the Mac (swiftvm ui): the desktop's own accessibility, and what Python takes to ask it.
packages+=(at-spi2-core python-gobject)

echo "==> Getting the list of packages"
# The keys that sign today's packages first, which may be newer than the system's.
pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')

echo "==> Downloading Omarchy's packages"
# The whole system is brought up to date with them: Arch Linux doesn't mix old packages with new.
pacman -Su --noconfirm --needed --downloadonly "${packages[@]}"

echo "==> Installing Omarchy's packages"
pacman -Su --noconfirm --needed "${packages[@]}"

echo "==> Downloading Omarchy $version"
source=$(mktemp -d)
trap 'rm -rf "$source"' EXIT
git -C "$source" init --quiet
git -C "$source" fetch --quiet --depth 1 "$repository" "$commit"
git -C "$source" checkout --quiet FETCH_HEAD
[[ $(git -C "$source" rev-parse HEAD) == "$commit" ]] || { echo "Omarchy's source isn't the release asked for." >&2; exit 1; }

echo "==> Installing Omarchy $version"
omarchy=/usr/share/omarchy
rm -rf "$omarchy"
mkdir -p "$omarchy/bin"
# Where Omarchy's package puts each part.
for tree in config default install migrations shell applications themes; do
    cp -a "$source/$tree" "$omarchy/$tree"
done
# Qt 6.12, which Arch Linux ARM has, brings a Color type of its own that hides the shell's theme
# colours, and the bar comes up empty. Omarchy's fix, from a release after this one, asks for the
# QtQuick of Qt 6.11: https://github.com/omacom/omarchy/pull/14845
grep -rlE --include='*.qml' '^import QtQuick[[:space:]]*$' "$omarchy/shell" | while IFS= read -r file; do
    sed -i -E 's/^import QtQuick[[:space:]]*$/import QtQuick 6.11/' "$file"
done
for file in icon.png icon.txt logo.svg logo.txt version; do
    install -m 0644 "$source/$file" "$omarchy/$file"
done
install -D -m 0644 "$source/LICENSE" /usr/share/licenses/omarchy/LICENSE
# Its commands are in /usr/bin, and also where code that asks for $OMARCHY_PATH/bin looks.
for command in "$source"/bin/*; do
    [[ -f $command ]] || continue
    name=${command##*/}
    install -m 0755 "$command" "/usr/bin/$name"
    ln -sfn "/usr/bin/$name" "$omarchy/bin/$name"
done

# What a new account starts with.
rm -rf /etc/skel/.config
cp -a "$source/config" /etc/skel/.config
install -m 0644 "$source/default/bashrc" /etc/skel/.bashrc
mkdir -p /etc/skel/.local/share/applications /etc/skel/.local/state/omarchy/toggles/hypr /etc/skel/.config/omarchy/branding
cp -a "$source/applications/." /etc/skel/.local/share/applications/
install -m 0644 "$source/default/hypr/toggles/flags.lua" /etc/skel/.local/state/omarchy/toggles/hypr/flags.lua
# Omarchy's migrations bring older installations up to this release. A new one is there already,
# which is what Omarchy's installer notes for a new account.
mkdir -p /etc/skel/.local/state/omarchy/migrations
for migration in "$source"/migrations/*.sh; do
    [[ -f $migration ]] && : > "/etc/skel/.local/state/omarchy/migrations/${migration##*/}"
done
install -m 0644 "$source/icon.txt" /etc/skel/.config/omarchy/branding/about.txt
install -m 0644 "$source/logo.txt" /etc/skel/.config/omarchy/branding/screensaver.txt
ln -sfn "$omarchy" /etc/skel/.local/share/omarchy
if [[ -d $source/default/nautilus-python/extensions ]]; then
    mkdir -p /etc/skel/.local/share/nautilus-python
    cp -a "$source/default/nautilus-python/extensions" /etc/skel/.local/share/nautilus-python/extensions
fi
# Animations, blur and shadows cost the most when the drawing is done by the processors: with
# animations, switching workspaces takes six times the work.
cat >> /etc/skel/.config/hypr/looknfeel.lua << 'END'

-- Added by SwiftVM: a virtual machine on a Mac draws on its processors, where animations, blur
-- and shadows cost the most. Take these lines out to have them back.
hl.config({
  animations = { enabled = false },
  decoration = { blur = { enabled = false }, shadow = { enabled = false } },
})
END
# Omarchy's update puts its own package configuration in place, which is made for PCs. This puts
# Arch Linux ARM's back before anything is installed with it.
mkdir -p /usr/local/share/swiftvm/omarchy /etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d
cp /etc/pacman.conf /etc/pacman.d/mirrorlist /usr/local/share/swiftvm/omarchy/
cat > /etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d/restore-arm-pacman << 'END'
#!/bin/bash
# Added by SwiftVM. Omarchy's package configuration is for PCs: this is Arch Linux ARM.
sudo install -m 0644 /usr/local/share/swiftvm/omarchy/pacman.conf /etc/pacman.conf
sudo install -m 0644 /usr/local/share/swiftvm/omarchy/mirrorlist /etc/pacman.d/mirrorlist
END
chmod 0755 /etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d/restore-arm-pacman

# What the session and the system around it take from Omarchy.
install -D -m 0644 "$source/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
mkdir -p /usr/lib/environment.d /usr/share/xdg-terminal-exec /usr/lib/systemd/user /usr/lib/systemd/system/user@.service.d
cp -a "$source/default/environment.d/." /usr/lib/environment.d/
cp -a "$source/default/xdg-terminal-exec/." /usr/share/xdg-terminal-exec/
cp -a "$source/default/systemd/user/." /usr/lib/systemd/user/
cp -a "$source/default/systemd/user@.service.d/." /usr/lib/systemd/system/user@.service.d/
install -D -m 0644 "$source/default/applications/mimeapps.list" /usr/share/applications/mimeapps.list
install -D -m 0644 "$source/default/fontconfig/conf.avail/50-omarchy.conf" /usr/share/fontconfig/conf.avail/50-omarchy.conf
ln -sfn /usr/share/fontconfig/conf.avail/50-omarchy.conf /etc/fonts/conf.d/50-omarchy.conf
install -D -m 0644 "$source/default/fonts/omarchy/omarchy.ttf" /usr/share/fonts/omarchy/omarchy.ttf
install -D -m 0644 "$source/default/wayland-sessions/omarchy.desktop" /usr/share/wayland-sessions/omarchy.desktop
install -D -m 0644 "$source/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
install -D -m 0644 "$source/etc/fastfetch/config.jsonc" /etc/fastfetch/config.jsonc
for name in omarchy-dns omarchy-theme-browser; do
    install -m 0440 "$source/etc/sudoers.d/$name" "/etc/sudoers.d/$name"
done
install -D -m 0644 "$source/icon.png" /usr/share/pixmaps/omarchy.png
# The login screen in Omarchy's look.
rm -rf /usr/share/sddm/themes/omarchy
cp -a "$source/default/sddm/omarchy" /usr/share/sddm/themes/omarchy
install -D -m 0644 "$source/etc/sddm.conf.d/10-theme.conf" /etc/sddm.conf.d/10-theme.conf
# A few of the steps of Omarchy's own installer that suit any system: Chromium's policies, which
# its themes are set with, and a login keyring that the login screen leaves alone.
OMARCHY_PATH=$omarchy OMARCHY_INSTALL=$omarchy/install bash -euo pipefail -c '
    source "$OMARCHY_INSTALL/config/browser-policy.sh"
    source "$OMARCHY_INSTALL/login/sddm.sh"
'

echo "==> Setting Omarchy up for $SWIFTVM_USER"
# The account was made before Omarchy was here, so it starts from what a new one would have.
# Omarchy does the rest itself the first time the account signs in.
home=$(getent passwd "$SWIFTVM_USER" | cut -d: -f6)
[[ -n $home && -d $home ]] || { echo "There is no home folder for $SWIFTVM_USER." >&2; exit 1; }
cp -a /etc/skel/. "$home/"
chown -R "$SWIFTVM_USER:" "$home"
# The login screen offers Omarchy first, to this account.
mkdir -p /var/lib/sddm
printf '[Last]\nSession=/usr/share/wayland-sessions/omarchy.desktop\nUser=%s\n' "$SWIFTVM_USER" > /var/lib/sddm/state.conf
chown -R sddm:sddm /var/lib/sddm

echo "==> Finishing"
# The network card stays with the service that has it, which asks for an address by the card's
# own: that is what the Mac keeps the machine's address by. NetworkManager only watches the card,
# so that the desktop knows it is online. Two services that both configure one card would take
# turns at undoing each other's work.
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
# The Mac suspends the virtual machine. A system that goes to sleep by itself may not wake up.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# One login screen at a time: a desktop installed before this one keeps its own.
[[ -e /etc/systemd/system/display-manager.service ]] || systemctl enable sddm
systemctl enable NetworkManager power-profiles-daemon
systemctl set-default graphical.target
