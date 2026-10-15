#!/bin/zsh
# Builds the QEMU that runs Windows guests, with what it needs to run from inside the app, and prints
# the folder it is in. scripts/bundle-app.sh copies that folder to Contents/Helpers/QEMU. The other
# build scripts run this; there is rarely a reason to run it by hand.
#   scripts/build-qemu.sh
#
# Only what Windows on Apple silicon needs is built: the one machine for 64-bit ARM, run on Apple's
# Hypervisor framework with no emulator, a VNC server for the app to show the screen through, and
# CoreAudio. Its program, the four libraries it can't do without and its firmware come to about 25 MB.
# The result is kept in .build/qemu and used again until this script or those libraries change.
#
# The libraries are Homebrew's, and so are the tools to build with:
#   brew install ninja meson pkgconf glib pixman python
#
# QEMU is GPL. What goes into the app carries the licences and says where the source is, which is
# also what the README in the result is for.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"

version=11.1.2
# The app runs on macOS 27 and later, as its packages say, and so has what it brings.
export MACOSX_DEPLOYMENT_TARGET=27.0
checksum=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
source_url=https://download.qemu.org/qemu-$version.tar.xz
display_patch=$root/scripts/qemu-vnc-refresh.patch
# Everything that isn't asked for here is left out.
configure_options=(
    --target-list=aarch64-softmmu --without-default-features
    --enable-hvf --disable-tcg --enable-vnc --enable-coreaudio --enable-pixman --enable-fdt=internal
    --disable-docs --disable-tools --disable-werror --enable-trace-backends=nop
)

for tool in ninja meson pkg-config; do
    (( $+commands[$tool] )) || fail "Building QEMU takes $tool, which isn't installed: brew install ninja meson pkgconf glib pixman python"
done
for library in glib-2.0 pixman-1; do
    pkg-config --exists $library || fail "Building QEMU takes $library, which isn't installed: brew install glib pixman"
done
# QEMU's build reads TOML, which Python's own library does from 3.11 on.
python=""
for candidate in ${HOMEBREW_PREFIX:-/opt/homebrew}/bin/python3 /usr/bin/python3 ${commands[python3]:-}; do
    if [[ -x $candidate ]] && "$candidate" -c 'import tomllib' 2> /dev/null; then
        python=$candidate
        break
    fi
done
[[ -n $python ]] || fail "Building QEMU takes Python 3.11 or newer: brew install python"

# What the result depends on: QEMU's version, this script, its display patch, and its libraries.
key=$( { print -r -- "$version ${configure_options[*]}"; cat "${0:A}" "$display_patch"; pkg-config --modversion glib-2.0 pixman-1; } | shasum -a 256 | cut -c1-12)
cache=$root/.build/qemu
result=$cache/$version-$key/QEMU
if [[ -x $result/bin/qemu-system-aarch64 && -f $result/share/keymaps/en-us ]]; then
    print -r -- "$result"
    exit 0
fi

mkdir -p "$cache"
work=$(mktemp -d "$cache/work.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM HUP

# The source, once: it is 140 MB.
tarball=$cache/qemu-$version.tar.xz
if [[ ! -f $tarball ]] || [[ $(shasum -a 256 "$tarball" | cut -d' ' -f1) != $checksum ]]; then
    print -u2 "Downloading QEMU $version…"
    curl --fail --silent --show-error --location --retry 3 -o "$work/source.tar.xz" "$source_url" \
        || fail "QEMU's source couldn't be downloaded from $source_url."
    [[ $(shasum -a 256 "$work/source.tar.xz" | cut -d' ' -f1) == $checksum ]] \
        || fail "QEMU's source from $source_url isn't the one this script was written for: its checksum differs."
    mv "$work/source.tar.xz" "$tarball"
fi
tar -xf "$tarball" -C "$work"
source_dir=$work/qemu-$version
patch --batch -d "$source_dir" -p1 < "$display_patch" >&2 \
    || fail "The display refresh patch no longer applies to QEMU $version."

print -u2 "Building QEMU $version…"
mkdir "$source_dir/build"
# Next to the results rather than with the source, which goes once this ends.
configure_log=$cache/configure.log build_log=$cache/build.log
(
    cd "$source_dir/build"
    ../configure --python="$python" --prefix=/ $configure_options > "$configure_log" 2>&1 \
        || fail "QEMU couldn't be configured. What configure said is in $configure_log."$'\n'"$(tail -20 "$configure_log")"
    ninja qemu-system-aarch64 > "$build_log" 2>&1 \
        || fail "QEMU couldn't be built. What the build said is in $build_log."$'\n'"$(tail -30 "$build_log")"
) || exit 1

out=$work/QEMU
mkdir -p "$out/bin" "$out/lib" "$out/share" "$out/licenses"
cp "$source_dir/build/qemu-system-aarch64" "$out/bin/"
strip -x "$out/bin/qemu-system-aarch64" 2> /dev/null

# The libraries QEMU was linked with and those they bring, as far as they aren't the system's. Each is
# told to look for the others next to itself, and QEMU in the folder beside its own.
typeset -A copied
copy_libraries() {
    local file=$1 reference name
    for reference in $(otool -L "$file" | tail -n +2 | awk '{ print $1 }'); do
        [[ $reference == /usr/lib/* || $reference == /System/* || $reference == @* ]] && continue
        name=${reference:t}
        if [[ -z ${copied[$name]:-} ]]; then
            [[ -f $reference ]] || fail "QEMU needs $reference, which isn't there."
            cp "$reference" "$out/lib/$name"
            chmod u+w "$out/lib/$name"
            install_name_tool -id "@loader_path/$name" "$out/lib/$name" 2> /dev/null
            copied[$name]=1
            copy_libraries "$out/lib/$name"
        fi
        if [[ $file == "$out/bin/"* ]]; then
            install_name_tool -change "$reference" "@executable_path/../lib/$name" "$file" 2> /dev/null
        else
            install_name_tool -change "$reference" "@loader_path/$name" "$file" 2> /dev/null
        fi
    done
}
copy_libraries "$out/bin/qemu-system-aarch64"
for library in "$out"/lib/*.dylib(N); do
    if otool -L "$library" | tail -n +2 | awk '{ print $1 }' | grep -q "^${HOMEBREW_PREFIX:-/opt/homebrew}"; then
        fail "${library:t} still looks for a library in Homebrew's folder."
    fi
done
# Homebrew builds its libraries for the macOS it runs on, which may be later than the app's.
for file in "$out/bin/qemu-system-aarch64" "$out"/lib/*.dylib(N); do
    minimum=$(vtool -show-build "$file" | awk '$1 == "minos" { print $2; exit }')
    [[ $(printf '%s\n%s\n' "$minimum" "$MACOSX_DEPLOYMENT_TARGET" | sort -V | tail -1) == "$MACOSX_DEPLOYMENT_TARGET" ]] \
        || fail "${file:t} needs macOS $minimum, and the app runs on $MACOSX_DEPLOYMENT_TARGET."
done

# The firmware comes padded to the 64 MB of the machine's flash, almost all of it zeros. The program
# takes it without the padding; the template for a machine's own variables is padded again by the app,
# as a sparse file, when it makes one.
trimmed() {
    "$python" -c '
import sys
data = open(sys.argv[1], "rb").read().rstrip(b"\0")
open(sys.argv[2], "wb").write(data + b"\0" * (-len(data) % 65536))
' "$1" "$2"
}
bunzip2 -c "$source_dir/pc-bios/edk2-aarch64-code.fd.bz2" > "$work/code.fd"
bunzip2 -c "$source_dir/pc-bios/edk2-arm-vars.fd.bz2" > "$work/vars.fd"
trimmed "$work/code.fd" "$out/share/edk2-aarch64-code.fd"
trimmed "$work/vars.fd" "$out/share/edk2-arm-vars.fd"
# The VNC server won't start without a keyboard layout, although the app hands it keys by their place
# on the keyboard, which no layout changes.
mkdir "$out/share/keymaps"
cp "$source_dir/pc-bios/keymaps/en-us" "$out/share/keymaps/"

cp "$source_dir/COPYING" "$out/licenses/QEMU-COPYING"
cp "$source_dir/COPYING.LIB" "$out/licenses/QEMU-COPYING.LIB"
cp "$source_dir/LICENSE" "$out/licenses/QEMU-LICENSE"
cp "$source_dir/pc-bios/edk2-licenses.txt" "$out/licenses/edk2-licenses.txt"
cp "$display_patch" "$out/licenses/"
brew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}
# gettext's own licence is the GPL of its tools. Its libintl is under the LGPL 2.1 or later, as glib is.
for license in glib/LGPL-2.1-or-later.txt pixman/COPYING pcre2/LICENCE.md; do
    [[ -f $brew_prefix/opt/$license ]] || fail "The licence of ${license%%/*} isn't at $brew_prefix/opt/$license."
    cp "$brew_prefix/opt/$license" "$out/licenses/${license%%/*}-${license:t}"
done
cat > "$out/README.txt" <<EOF
QEMU $version, built for SwiftVM to run Windows guests.

QEMU is free software under the GNU General Public License, version 2. Its source is at
$source_url (SHA-256 $checksum),
and it was configured with:
  ${configure_options[*]}
The script that builds it is scripts/build-qemu.sh in SwiftVM's repository.
The included licenses/qemu-vnc-refresh.patch adjusts VNC's refresh timing for a local
display and wakes it when the guest draws or the client is ready for a frame.

The libraries in lib/ are Homebrew's builds of glib $(pkg-config --modversion glib-2.0), pixman $(pkg-config --modversion pixman-1),
PCRE2 and gettext's libintl, which is under the GNU Lesser General Public License 2.1 or later, as
glib is. The firmware in share/ is EDK II, as it comes with QEMU's source. Their licences are in
licenses/.
EOF

# Signed to run on this Mac, so that it does so by itself. In the app it is signed again.
for library in "$out"/lib/*.dylib(N); do
    codesign --force --sign - "$library" 2> /dev/null
done
print '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>' > "$work/entitlements.plist"
codesign --force --sign - --entitlements "$work/entitlements.plist" "$out/bin/qemu-system-aarch64" 2> /dev/null
"$out/bin/qemu-system-aarch64" --version > /dev/null || fail "The QEMU that was built doesn't run."

# Results of earlier versions of this script are of no use any more.
for earlier in "$cache"/*-*(N/); do
    [[ $earlier == $cache/$version-$key || $earlier == $work ]] || rm -rf "$earlier"
done
mkdir -p "${result:h}"
mv "$out" "$result"
print -r -- "$result"
