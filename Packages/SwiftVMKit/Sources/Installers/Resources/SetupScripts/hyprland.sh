#!/bin/sh
# name: Hyprland
# summary: The Hyprland tiling compositor, with a bar and a launcher
# category: desktop
# systems: arch
# memory: 4
# disk: 16
# restart: yes
#
# A setup script for SwiftVM. It runs as root in a new virtual machine the first time the machine
# starts. The lines above say what it is; a line it prints that starts with "==> " is the step
# SwiftVM shows. How these scripts are written: https://swiftvm.app/docs/features/setup-scripts/
#
# Hyprland draws with OpenGL: enable graphics acceleration when creating the machine for a
# smoother desktop. Without it, the processors do the drawing. Super is the Command key:
# Command-Q opens a terminal, Command-R the launcher, and Command-M leaves Hyprland.

set -eu
. /etc/os-release

case $ID in
    arch | archarm) ;;
    *) echo "This script is written for Arch Linux, not for $ID." >&2; exit 1 ;;
esac
# The compositor and what its own configuration starts: a terminal, Dolphin and hyprlauncher. Then a
# bar, what lets applications share the screen and ask for a password, sound, a login screen and
# a browser. The terminal is foot rather than the configuration's kitty, which needs a newer OpenGL
# than graphics acceleration gives a Linux machine and doesn't start there.
packages="hyprland foot dolphin hyprlauncher waybar woff2-font-awesome noto-fonts xdg-desktop-portal-hyprland
    hyprpolkitagent qt6-wayland xorg-xwayland pipewire-pulse wireplumber sddm firefox spice-vdagent"
# What the guest tools read the screen with, part by part, for whoever drives this machine from
# the Mac (swiftvm ui): the desktop's own accessibility, and what Python takes to ask it.
packages="$packages at-spi2-core python-gobject"
# A compiler for the few lines that make Hyprland wait for its drawing (below). It goes again
# afterwards, unless the system had one already.
had_compiler=no
pacman -Q gcc > /dev/null 2>&1 && had_compiler=yes
packages="$packages gcc"

echo "==> Getting the list of packages"
# The keys that sign today's packages first, which may be newer than the system's.
pacman -Sy --noconfirm --needed $(pacman -Qqs '^arch.*-keyring$')

echo "==> Downloading Hyprland"
# The whole system is brought up to date with it: Arch Linux doesn't mix old packages with new.
pacman -Su --noconfirm --needed --downloadonly $packages

echo "==> Installing Hyprland"
pacman -Su --noconfirm --needed $packages

echo "==> Finishing"
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
# Kept when something installed since depends on it.
[ "$had_compiler" = yes ] || pacman -Rns --noconfirm gcc || true

# Hyprland's own configuration, without the note that it was made for nobody in particular, and
# with the bar. One the account has already stays as it is.
home=$(getent passwd "$SWIFTVM_USER" | cut -d: -f6)
config=$home/.config/hypr/hyprland.lua
if [ -n "$home" ] && [ ! -e "$config" ]; then
    mkdir -p "$home/.config/hypr"
    {
        sed -E 's/^(local terminal[[:space:]]*=[[:space:]]*)"kitty"/\1"foot"/' /usr/share/hypr/hyprland.lua
        printf '\n-- Added by SwiftVM: the bar.\nhl.on("hyprland.start", function ()\n    hl.exec_cmd("waybar")\nend)\n'
        cat << 'END'

-- Added by SwiftVM: keep effects inexpensive for machines without graphics acceleration.
-- Remove this block to turn them back on.
hl.config({
  animations = { enabled = false },
  decoration = { blur = { enabled = false }, shadow = { enabled = false } },
})
END
    } > "$config"
    chown -R "$SWIFTVM_USER:" "$home/.config"
fi
# The Mac suspends the virtual machine. A system that goes to sleep by itself may not wake up.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# One login screen at a time: a desktop installed before this one keeps its own.
[ -e /etc/systemd/system/display-manager.service ] || systemctl enable sddm
systemctl set-default graphical.target
