#!/bin/bash
# name: Omarchy (experimental)
# summary: Omarchy's desktop and apps on Arch Linux ARM, with some apps unavailable
# category: desktop
# systems: arch
# memory: 8
# disk: 64
# restart: yes
#
# A setup script for SwiftVM. It runs as root in a new virtual machine the first time the machine
# starts. The lines above say what it is; a line it prints that starts with "==> " is the step
# SwiftVM shows. How these scripts are written: https://swiftvm.app/docs/features/setup-scripts/
#
# Omarchy (https://omarchy.org) is made for Arch Linux on PCs. This installs its own package list,
# source and package recipes on Arch Linux ARM, after Try Omarchy (https://github.com/omacom/try-omarchy,
# MIT). Packages not published for ARM are built where the upstream recipe supports it. Mise and
# Obsidian come from their official ARM releases. The few packages without an ARM installation here
# are listed in /usr/local/share/swiftvm/omarchy/unavailable-packages.txt, not silently left out.
#
# Hyprland draws with OpenGL: enable graphics acceleration when creating the machine for a
# smoother desktop. Without it, the processors do the drawing. Super is the Command key.

set -euo pipefail
. /etc/os-release

case $ID in
    arch | archarm) ;;
    *) echo "This script is written for Arch Linux, not for $ID." >&2; exit 1 ;;
esac
[[ $(uname -m) == aarch64 ]] || { echo "This script is written for 64-bit ARM." >&2; exit 1; }

version=4.0.4
repository=https://github.com/basecamp/omarchy.git
# The release, by its commit: a tag can be moved, a commit can't.
commit=c668141e9c42b13c80c9ca4ea108e11708c5e8a5
recipes_repository=https://github.com/omacom-io/omarchy-pkgs.git
recipes_commit=7e448b90313fea4fb78da9a78607287691d3b241

# Builds belong on disk, not in /tmp, which the guest may keep in memory. Nothing is built as root.
work=$(mktemp -d /var/tmp/swiftvm-omarchy.XXXXXX)
source=$work/source
recipes=$work/recipes
build_home=$work/build
build_user=''
cleanup() {
    [[ -z $build_user ]] || userdel "$build_user" || true
    rm -rf "$work"
}
trap cleanup EXIT

fetch() {
    mkdir -p "$1"
    git -C "$1" init --quiet
    git -C "$1" fetch --quiet --depth 1 "$2" "$3"
    git -C "$1" checkout --quiet FETCH_HEAD
    [[ $(git -C "$1" rev-parse HEAD) == "$3" ]] || { echo "The source isn't the revision asked for." >&2; exit 1; }
}

as_builder() {
    runuser -u "$build_user" -- env HOME="$build_home" CARGO_HOME="$build_home/.cargo" \
        RUSTUP_HOME="$build_home/.rustup" MAKEFLAGS=-j2 CARGO_BUILD_JOBS=2 "$@"
}

echo "==> Getting the list of packages"
# The keys that sign today's packages first, which may be newer than the system's.
pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')
pacman -Su --noconfirm --needed git

echo "==> Downloading Omarchy $version"
fetch "$source" "$repository" "$commit"
fetch "$recipes" "$recipes_repository" "$recipes_commit"

# Start with the release's own manifest, not a second list of what its desktop happens to need.
# An unexpected missing package fails setup; only the exceptions below are left out.
packages=()
source_packages=()
: > "$work/unavailable-packages.txt"
while read -r package rest; do
    [[ -z $package || $package == \#* ]] && continue
    case $package in
        nvim) packages+=(neovim) ;;
        ttf-jetbrains-mono-nerd-basic) packages+=(ttf-jetbrains-mono-nerd) ;;
        qemu-user-static-binfmt) packages+=(qemu-user-binfmt) ;;
        aether | cliamp | herdr | localsend | omacalc | omacut | omawrite | omarchy-nvim | ttfx | tobi-try | ttf-ia-writer | ufw-docker | yaru-icon-theme | yay | mise-bin | obsidian)
            source_packages+=("$package") ;;
        asdcontrol)
            echo "$package: controls a physical Apple display, not a virtual display." >> "$work/unavailable-packages.txt" ;;
        dotnet-runtime | pinta)
            echo "$package: the .NET packages are not in Arch Linux ARM; Omarchy's Pinta recipe targets x86_64." >> "$work/unavailable-packages.txt" ;;
        hyprland-preview-share-picker | tensaku | tzupdate)
            echo "$package: the pinned upstream package recipe does not support ARM." >> "$work/unavailable-packages.txt" ;;
        obs-studio)
            echo "$package: not available from Arch Linux ARM." >> "$work/unavailable-packages.txt" ;;
        *) packages+=("$package") ;;
    esac
done < "$source/install/omarchy-base.packages"

# The VM's display, sound and guest integration, beyond the ISO's base manifest.
packages+=(
    hyprlock hypridle qt6-wayland xorg-xwayland mesa vulkan-swrast polkit
    pipewire pipewire-alsa pipewire-pulse playerctl gvfs libnotify
    desktop-file-utils shared-mime-info xdg-user-dirs xdg-utils spice-vdagent
    at-spi2-core python-gobject
)
# Build dependencies of the pinned recipes. Rustup supplies cargo for the Rust apps and LocalSend.
packages+=(
    base-devel cmake fvm go lld meson ninja npm patchelf rustup sassc
    qt6-declarative qt6-multimedia libayatana-appindicator webkit2gtk-4.1 nss libxss
)

echo "==> Downloading Omarchy's packages"
# The whole system is brought up to date with them: Arch Linux doesn't mix old packages with new.
pacman -Su --noconfirm --needed --downloadonly "${packages[@]}"

echo "==> Installing Omarchy's packages"
pacman -Su --noconfirm --needed "${packages[@]}"

# A separate, locked account can build packages but cannot install them or use sudo. A new name on
# each attempt also lets setup resume after a power loss without adopting an abandoned account.
builder=swiftvm-omarchy-$(printf '%s' "${work##*.}" | tr '[:upper:]' '[:lower:]')
useradd --system --user-group --no-create-home --home-dir "$build_home" --shell /usr/bin/nologin "$builder"
build_user=$builder
chmod 0755 "$work"
mkdir -p "$build_home"
for package in "${source_packages[@]}"; do
    if [[ -d $recipes/pkgbuilds/$package ]]; then
        cp -a "$recipes/pkgbuilds/$package" "$build_home/$package"
    else
        mkdir -p "$build_home/$package"
    fi
done

# This legacy theme is only used by Omarchy 3.8, but LazyVim still tries to fetch it on startup.
# Its repository is gone, so disable the unused plugin rather than leaving Neovim unable to start.
sed -i 's|"gthelding/monokai-pro.nvim",|&\n\t\tenabled = false,|' "$build_home/omarchy-nvim/lua/plugins/all-themes.lua"

# Official ARM binaries where the package is absent from Arch Linux ARM. The digests pin the
# downloaded bytes, and makepkg checks them before packaging; neither installer is piped into a shell.
cat > "$build_home/mise-bin/PKGBUILD" << 'END'
pkgname=mise-bin
pkgver=2026.8.11
pkgrel=1
pkgdesc='Development tool manager, from the official ARM64 release'
arch=('aarch64')
url='https://github.com/jdx/mise'
license=('MIT')
depends=('glibc' 'gcc-libs')
provides=("mise=$pkgver")
conflicts=('mise')
options=('!strip' '!debug')
source=("https://github.com/jdx/mise/releases/download/v$pkgver/mise-v$pkgver-linux-arm64.tar.xz")
sha256sums=('fefd580d2c6a8169762f40ce5019a61de5b2dcf0b38c5d428ef6b97d5ce76fba')
package() {
    install -Dm755 mise/bin/mise "$pkgdir/usr/bin/mise"
    install -Dm644 mise/LICENSE "$pkgdir/usr/share/licenses/mise-bin/LICENSE"
    install -Dm644 mise/man/man1/mise.1 "$pkgdir/usr/share/man/man1/mise.1"
}
END
cat > "$build_home/obsidian/PKGBUILD" << 'END'
pkgname=obsidian
pkgver=1.14.4
pkgrel=1
pkgdesc='Knowledge base, from the official ARM64 release'
arch=('aarch64')
url='https://obsidian.md'
license=('custom:Commercial')
depends=('alsa-lib' 'gtk3' 'nss' 'libxss' 'libsecret' 'libnotify' 'xdg-utils')
options=('!strip' '!debug')
source=("https://github.com/obsidianmd/obsidian-releases/releases/download/v$pkgver/obsidian-$pkgver-arm64.tar.gz")
sha256sums=('fc212804515713ed85fe5ef5bc4b009872bcc01847c4be4fcc14971deee2a42d')
package() {
    install -d "$pkgdir/opt/obsidian" "$pkgdir/usr/bin" "$pkgdir/usr/share/applications"
    cp -a "obsidian-$pkgver-arm64/." "$pkgdir/opt/obsidian/"
    ln -s /opt/obsidian/obsidian "$pkgdir/usr/bin/obsidian"
    install -Dm644 "obsidian-$pkgver-arm64/resources/icon.png" "$pkgdir/usr/share/pixmaps/obsidian.png"
    cat > "$pkgdir/usr/share/applications/obsidian.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Obsidian
Exec=obsidian %U
Icon=obsidian
Terminal=false
Categories=Office;
MimeType=x-scheme-handler/obsidian;
DESKTOP
}
END
chown -R "$build_user:" "$build_home"

echo "==> Preparing the application builds"
as_builder rustup toolchain install stable --profile minimal
as_builder rustup default stable

# Keep locally built packages in a root-owned repository. Omarchy's updater then leaves them pinned
# instead of treating them as foreign packages to replace from the AUR.
local_repo=/usr/local/share/swiftvm/omarchy/packages
mkdir -p "$local_repo"
for package in "${source_packages[@]}"; do
    echo "==> Building $package for ARM"
    as_builder bash -c 'cd "$1"; exec makepkg --noconfirm --nocheck --clean' bash "$build_home/$package"
    as_builder bash -c 'cd "$1"; exec makepkg --packagelist' bash "$build_home/$package" > "$work/package-files"
    archives=()
    while IFS= read -r archive; do
        # A split recipe can build other packages too (Yaru's GNOME session, for example). Install
        # only the one Omarchy asked for, and not a separate debug package.
        case ${archive##*/} in
            "$package"-[0-9]*.pkg.tar.*) archives+=("$archive") ;;
        esac
    done < "$work/package-files"
    [[ ${#archives[@]} == 1 ]] || { echo "No single package was built for $package." >&2; exit 1; }
    install -m 0644 "${archives[0]}" "$local_repo/"
    pacman -U --noconfirm --needed "$local_repo/${archives[0]##*/}"
done

# Without graphics acceleration llvmpipe draws on the processors, and Hyprland shows each frame
# before it is drawn: it waits only for software renderers it recognises by the graphics card's
# driver, which is virtio_gpu here. The Mac then keeps what the frame held before, a window that
# was closed for one. This makes Hyprland wait when llvmpipe draws, and leaves everything else be.
mkdir -p /usr/local/lib/swiftvm-hyprland
cat > /usr/local/lib/swiftvm-hyprland/hyprland-finish.c << 'END'
/* Added by SwiftVM: Hyprland waits for llvmpipe to draw a frame before it shows it. Only Hyprland
   loads this, through /usr/local/bin/Hyprland, and the programs it starts don't inherit it. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#define SELF "/usr/local/lib/swiftvm-hyprland/hyprland-finish.so"
#define GL_RENDERER 0x1F01

const unsigned char *glGetString(unsigned int name);
void glFinish(void);

__attribute__((constructor)) static void leave_preload(void) {
    const char *preload = getenv("LD_PRELOAD");
    if (!preload || strncmp(preload, SELF, strlen(SELF)) != 0)
        return;
    if (preload[strlen(SELF)] == ':')
        setenv("LD_PRELOAD", preload + strlen(SELF) + 1, 1);
    else
        unsetenv("LD_PRELOAD");
}

void glFlush(void) {
    static void (*flush)(void);
    static int software = -1;
    if (software < 0) {
        const char *renderer = (const char *)glGetString(GL_RENDERER);
        if (renderer)
            software = strstr(renderer, "llvmpipe") != NULL;
    }
    if (software == 1) {
        glFinish();
        return;
    }
    if (!flush)
        flush = (void (*)(void))dlsym(RTLD_NEXT, "glFlush");
    flush();
}
END
gcc -O2 -shared -fPIC -o /usr/local/lib/swiftvm-hyprland/hyprland-finish.so /usr/local/lib/swiftvm-hyprland/hyprland-finish.c
# Hyprland's launcher finds it by name, and /usr/local/bin comes first.
cat > /usr/local/bin/Hyprland << 'END'
#!/bin/sh
# Added by SwiftVM: Hyprland with /usr/local/lib/swiftvm-hyprland/hyprland-finish.so, whose source says why.
LD_PRELOAD=/usr/local/lib/swiftvm-hyprland/hyprland-finish.so${LD_PRELOAD:+:$LD_PRELOAD} exec /usr/bin/Hyprland "$@"
END
chmod 0755 /usr/local/bin/Hyprland

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
commands=()
for command in "$source"/bin/*; do
    [[ -f $command ]] || continue
    name=${command##*/}
    install -m 0755 "$command" "/usr/bin/$name"
    ln -sfn "/usr/bin/$name" "$omarchy/bin/$name"
    commands+=("usr/bin/$name")
done
# Omarchy's signing keys and Arch's PC keyring don't sign the ARM packages. Its update calls this
# before the full system upgrade, so refresh the keyring that the guest actually uses.
cat > /usr/bin/omarchy-update-keyring << 'END'
#!/bin/bash
# Added by SwiftVM: these packages come from Arch Linux ARM.
set -euo pipefail
exec sudo pacman -Sy --noconfirm archlinuxarm-keyring
END

# What a new account starts with. Keep the Neovim configuration and plugin cache that omarchy-nvim
# has already installed into /etc/skel; replacing .config would discard part of the desktop again.
mkdir -p /etc/skel/.config
cp -a "$source/config/." /etc/skel/.config/
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
cat >> /etc/skel/.config/hypr/looknfeel.lua << 'END'

-- Added by SwiftVM: keep effects inexpensive for machines without graphics acceleration.
-- Remove this block to turn them back on.
hl.config({
  animations = { enabled = false },
  decoration = { blur = { enabled = false }, shadow = { enabled = false } },
})
END
# The screensaver redraws the whole screen 120 times a second from 2.5 minutes idle until the lock,
# which keeps every processor busy without graphics acceleration. The Mac has a screensaver of its
# own; Omarchy's menu turns this one back on.
touch /etc/skel/.local/state/omarchy/toggles/screensaver-off

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
install -D -m 0644 "$source/etc/mise/conf.d/omarchy.toml" /etc/mise/conf.d/omarchy.toml
for name in omarchy-dns omarchy-theme-browser; do
    install -m 0440 "$source/etc/sudoers.d/$name" "/etc/sudoers.d/$name"
done
install -D -m 0644 "$source/icon.png" /usr/share/pixmaps/omarchy.png
# The login screen in Omarchy's look.
rm -rf /usr/share/sddm/themes/omarchy
cp -a "$source/default/sddm/omarchy" /usr/share/sddm/themes/omarchy
install -D -m 0644 "$source/etc/sddm.conf.d/10-theme.conf" /etc/sddm.conf.d/10-theme.conf
# The application setup that suits this guest. Hardware, bootloader, filesystem and firewall setup
# stay with SwiftVM: applying the ISO's configuration here could take away the network or SSH.
OMARCHY_PATH=$omarchy OMARCHY_INSTALL=$omarchy/install bash -euo pipefail -c '
    source "$OMARCHY_INSTALL/config/theme-system.sh"
    source "$OMARCHY_INSTALL/config/browser-policy.sh"
    source "$OMARCHY_INSTALL/login/sddm.sh"
'
systemctl enable cups.service avahi-daemon.service docker.socket

# Register the installed runtime too: Omarchy reads its version through pacman. The local repository
# keeps the ARM adaptations paired with the pinned source instead of replacing them with PC packages.
mkdir -p "$work/runtime"
cat > "$work/runtime/.PKGINFO" << END
pkgname = omarchy
pkgver = $version-1
pkgdesc = Omarchy $version adapted for SwiftVM on Arch Linux ARM
url = $repository
arch = any
license = MIT
conflict = omarchy-dev
END
bsdtar --zstd -cf "$local_repo/omarchy-$version-1-any.pkg.tar.zst" \
    -C "$work/runtime" .PKGINFO -C / usr/share/omarchy usr/share/licenses/omarchy "${commands[@]}"
pacman -U --dbonly --noconfirm "$local_repo/omarchy-$version-1-any.pkg.tar.zst"
repo-add "$local_repo/swiftvm-omarchy.db.tar.gz" "$local_repo/"*.pkg.tar.*
if ! grep -q '^\[swiftvm-omarchy\]$' /etc/pacman.conf; then
    # First repository wins, even if a remote later publishes a package with the same name.
    grep -q '^\[core\]$' /etc/pacman.conf || { echo "Arch Linux ARM's core repository is missing." >&2; exit 1; }
    sed -i '/^\[core\]$/i\
[swiftvm-omarchy]\
SigLevel = Optional TrustAll\
Server = file:///usr/local/share/swiftvm/omarchy/packages\
' /etc/pacman.conf
fi
pacman -Syu --noconfirm

# Omarchy's update puts its own package configuration in place, which is made for PCs. This puts
# Arch Linux ARM's back, including the locally built packages, before anything is installed with it.
mkdir -p /etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d
cp /etc/pacman.conf /etc/pacman.d/mirrorlist /usr/local/share/swiftvm/omarchy/
install -m 0644 "$work/unavailable-packages.txt" /usr/local/share/swiftvm/omarchy/unavailable-packages.txt
cat > /etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d/restore-arm-pacman << 'END'
#!/bin/bash
# Added by SwiftVM. Omarchy's package configuration is for PCs: this is Arch Linux ARM.
sudo install -m 0644 /usr/local/share/swiftvm/omarchy/pacman.conf /etc/pacman.conf
sudo install -m 0644 /usr/local/share/swiftvm/omarchy/mirrorlist /etc/pacman.d/mirrorlist
END
chmod 0755 /etc/skel/.config/omarchy/hooks/pre-refresh-pacman.d/restore-arm-pacman

echo "==> Setting Omarchy up for $SWIFTVM_USER"
# The account was made before Omarchy was here, so it starts from what a new one would have.
# Omarchy does the rest itself the first time the account signs in, including its mise tools.
home=$(getent passwd "$SWIFTVM_USER" | cut -d: -f6)
[[ -n $home && -d $home ]] || { echo "There is no home folder for $SWIFTVM_USER." >&2; exit 1; }
cp -a /etc/skel/. "$home/"
chown -R "$SWIFTVM_USER:" "$home"
# The login screen offers Omarchy first, to this account.
mkdir -p /var/lib/sddm
printf '[Last]\nSession=/usr/share/wayland-sessions/omarchy.desktop\nUser=%s\n' "$SWIFTVM_USER" > /var/lib/sddm/state.conf
chown -R sddm:sddm /var/lib/sddm

echo "==> Apps unavailable in this ARM installation"
cat /usr/local/share/swiftvm/omarchy/unavailable-packages.txt

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
