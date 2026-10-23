#!/bin/zsh
# Builds the QEMU that runs Windows guests and Linux guests with graphics acceleration, with what it
# needs to run from inside the app, and prints the folder it is in. scripts/bundle-app.sh copies that
# folder into the app. The other build scripts run this; there is rarely a reason to run it by hand.
#   scripts/build-qemu.sh
#
# Only what a Mac needs is built: the one machine for 64-bit ARM, run on Apple's Hypervisor framework
# with no emulator, CoreAudio, 9p shared folders, a VNC server for the app to show the screen through,
# and SPICE with OpenGL for machines with graphics acceleration. Their OpenGL is replayed on the Mac's
# GPU by virglrenderer through ANGLE, which draws with Metal, and the app shows it with CocoaSpice. The
# patches in Native/QEMU carry what that takes on macOS, after UTM's.
#
# Experimental Direct3D for Windows guests is included by default: DXMT turns it into Metal, and its
# shader translator is built with LLVM 15, which makes the first build far longer. Set
# SWIFTVM_QEMU_DIRECT3D=0 to leave it out while keeping Linux graphics acceleration.
#
# Every source is pinned in Native/QEMU/sources.tsv by its checksum. The libraries the build doesn't
# make itself are Homebrew's, and so are the tools to build with:
#   brew install cmake ninja meson pkgconf glib pixman openssl@3 python
# and Xcode's Metal toolchain: xcodebuild -downloadComponent MetalToolchain
#
# QEMU is GPL. What goes into the app carries the licences and says where the source is, which is also
# what the README in the result is for. The result is kept in .build/qemu and used again until this
# script, what is in Native/QEMU or Homebrew's libraries change.
set -euo pipefail
script=${0:A}
root=${script:h:h}
source "$root/scripts/common.sh"

qemu_version=11.1.2
native=$root/Native/QEMU
bridge=$root/Packages/SwiftVMKit/Sources/GuestDisplayBridge/include
direct3d=$([[ ${SWIFTVM_QEMU_DIRECT3D:-1} == 1 ]] && print yes || print no)
# The app runs on macOS 27 and later, as its packages say, and so has what it brings.
export MACOSX_DEPLOYMENT_TARGET=27.0
# Everything that isn't asked for here is left out.
configure_options=(
    --target-list=aarch64-softmmu --without-default-features
    --enable-hvf --disable-tcg --enable-coreaudio --enable-pixman --enable-fdt=internal --enable-virtfs
    --enable-vnc --enable-spice --enable-opengl --enable-virglrenderer
    --disable-docs --disable-tools --disable-werror --enable-trace-backends=nop
)

brew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}
for tool in cmake ninja meson pkg-config clang xcrun; do
    (( $+commands[$tool] )) || fail "Building QEMU takes $tool, which isn't installed: brew install cmake ninja meson pkgconf glib pixman openssl@3 python"
done
export PKG_CONFIG_PATH=$brew_prefix/opt/openssl@3/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
for library in glib-2.0 pixman-1 openssl; do
    pkg-config --exists $library || fail "Building QEMU takes $library, which isn't installed: brew install glib pixman openssl@3"
done
xcrun -sdk macosx metal --version > /dev/null 2>&1 || fail "Building QEMU's display takes Xcode's Metal toolchain: xcodebuild -downloadComponent MetalToolchain"
# QEMU's build reads TOML, which Python's own library does from 3.11 on, and the sources are unpacked
# with tarfile's safe filter, from 3.11.4 on.
python=""
for candidate in $brew_prefix/bin/python3 /usr/bin/python3 ${commands[python3]:-}; do
    if [[ -x $candidate ]] && "$candidate" -c 'import tomllib, tarfile; tarfile.data_filter' 2> /dev/null; then
        python=$candidate
        break
    fi
done
[[ -n $python ]] || fail "Building QEMU takes Python 3.11.4 or newer: brew install python"

# What the result depends on: this script, Native/QEMU, the display's interface, whether Direct3D is
# in, and Homebrew's libraries.
key=$( { cat "$script" "$native"/* "$bridge"/*; print -r -- "$direct3d"; pkg-config --modversion glib-2.0 pixman-1 openssl; } | shasum -a 256 | cut -c1-12)
cache=$root/.build/qemu
result=$cache/$qemu_version-$key/QEMU
if [[ -x $result/bin/qemu-system-aarch64 && -f $result/lib/libSwiftVMDisplay.dylib ]]; then
    print -r -- "$result"
    exit 0
fi

# The sources stay, unpacked, and the libraries made from them, for the next build to go faster. The
# rest of a build goes when it ends.
sources=$cache/sources prefix=$cache/prefix
mkdir -p "$sources" "$prefix"
work=$(mktemp -d "$cache/work.XXXXXX")
log=$cache/build.log
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM HUP

fetch_sources() {
    local name checksum url part archive
    while IFS=$'\t' read -r name checksum url part; do
        [[ $part == all || $direct3d == yes ]] || continue
        archive=$sources/$name
        if [[ ! -f $archive || $(shasum -a 256 "$archive" | cut -d' ' -f1) != $checksum ]]; then
            print -u2 "Downloading $name…"
            curl --fail --silent --show-error --location --retry 3 -o "$archive.download" "$url" \
                || fail "$name couldn't be downloaded from $url."
            [[ $(shasum -a 256 "$archive.download" | cut -d' ' -f1) == $checksum ]] \
                || fail "$name from $url isn't the one Native/QEMU/sources.tsv names: its checksum differs."
            mv "$archive.download" "$archive"
        fi
    done < "$native/sources.tsv"
}

# Unpacks the archive $1 into the sources, as $2, with the patches after it applied. A source whose
# archive or patches have changed since it was unpacked is unpacked again.
unpack() {
    local archive=$sources/$1 directory=$sources/$2 stamp
    shift 2
    stamp=$( { shasum -a 256 "$archive"; (( $# == 0 )) || cat "$@"; } | shasum -a 256 | cut -d' ' -f1)
    [[ -f $directory/.swiftvm-stamp && $(<"$directory/.swiftvm-stamp") == $stamp ]] && return 0
    rm -rf "$directory" "$sources/.unpacking"
    mkdir "$sources/.unpacking"
    # Python's safe filter, except that links out of the tree are left out rather than failing the
    # whole archive: QEMU's carries one for a firmware build this doesn't make.
    "$python" - "$archive" "$sources/.unpacking" <<'PY'
import sys, tarfile
def keep(member, path):
    if member.issym() and member.linkname.startswith('/'):
        return None
    return tarfile.data_filter(member, path)
with tarfile.open(sys.argv[1]) as source:
    source.extractall(sys.argv[2], filter=keep)
PY
    local unpacked=("$sources/.unpacking"/*(N))
    (( ${#unpacked} == 1 )) || fail "${archive:t} doesn't unpack into one folder."
    mv "$unpacked[1]" "$directory"
    rmdir "$sources/.unpacking"
    local patch_file
    for patch_file in "$@"; do
        patch --batch --forward -d "$directory" -p1 < "$patch_file" > /dev/null \
            || fail "${patch_file:t} doesn't apply to ${archive:t}."
    done
    print -r -- "$stamp" > "$directory/.swiftvm-stamp"
}

meson_build() {
    local directory=$1
    shift
    local reconfigure=()
    # Meson keeps the dependencies it found from one setup to the next, and with them Homebrew's
    # versioned folders, which go when Homebrew moves to another version.
    [[ ! -f $directory/build/build.ninja ]] || reconfigure=(--reconfigure --clearcache)
    meson setup $reconfigure "$directory/build" "$directory" --prefix="$prefix" --libdir=lib --buildtype=release -Dauto_features=disabled "$@"
    meson compile -C "$directory/build"
    meson install -C "$directory/build"
}

build_libraries() {
    if [[ ! -x $cache/tools/bin/python3 ]]; then "$python" -m venv "$cache/tools"; fi
    "$cache/tools/bin/python3" -m pip install --quiet PyYAML==6.0.3 pyparsing==3.2.3 six==1.17.0
    # Some of the projects run their generators with Meson's own Python, which needs these too.
    export PYTHONPATH=$("$cache/tools/bin/python3" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
    export PKG_CONFIG_PATH=$prefix/lib/pkgconfig:$prefix/share/pkgconfig:$PKG_CONFIG_PATH
    export PATH=$cache/tools/bin:$brew_prefix/opt/gettext/bin:$PATH

    unpack spice-protocol-0.14.5.tar.xz spice-protocol
    meson_build "$sources/spice-protocol"
    unpack libjpeg-turbo-3.1.2.tar.gz libjpeg-turbo
    cmake -S "$sources/libjpeg-turbo" -B "$sources/libjpeg-turbo/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
    cmake --build "$sources/libjpeg-turbo/build"
    # CMake's install edits the library's search paths in place, even when it is up to date already.
    rm -f "$prefix"/lib/libjpeg*.dylib(N)
    cmake --install "$sources/libjpeg-turbo/build"
    unpack json-glib-1.10.0.tar.xz json-glib
    meson_build "$sources/json-glib" -Dintrospection=disabled -Dtests=false
    unpack libucontext.tar.gz libucontext
    meson_build "$sources/libucontext" -Ddefault_library=static -Dfreestanding=true
    # The display needs neither video pipelines nor SPICE's audio: QEMU plays through CoreAudio.
    unpack gstreamer-1.19.1.tar.xz gstreamer
    meson_build "$sources/gstreamer" -Dgst_parse=false -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled -Dtools=disabled -Dintrospection=disabled
    unpack gst-plugins-base-1.19.1.tar.xz gst-plugins-base "$sources/gst-plugins-base-1.19.1.patch"
    meson_build "$sources/gst-plugins-base" -Dtests=disabled -Dexamples=disabled -Dtools=disabled -Dgl=disabled -Dintrospection=disabled
    unpack spice-0.16.0.tar.bz2 spice "$native/spice-server.patch" "$native/spice-input-lifetime.patch"
    meson_build "$sources/spice" -Dlz4=false -Dsasl=false -Dgstreamer=no -Dmanual=false -Dtests=false
    unpack spice-gtk-0.42.tar.xz spice-gtk "$sources/spice-gtk-0.42.patch"
    meson_build "$sources/spice-gtk" -Dcoroutine=libucontext -Dintrospection=disabled -Dgtk=disabled -Dwebdav=disabled -Dusbredir=disabled -Dwayland-protocols=disabled

    # ANGLE as UTM's WebKit carries it, which shares its textures with Metal. A sparse checkout leaves
    # the rest of WebKit out.
    if [[ ! -d $sources/WebKit/.git ]]; then
        git clone --quiet --filter=tree:0 --no-checkout https://github.com/utmapp/WebKit.git "$sources/WebKit"
        git -C "$sources/WebKit" sparse-checkout set Source/ThirdParty/ANGLE Configurations Tools/ccache
    fi
    local angle=$sources/WebKit/Source/ThirdParty/ANGLE angle_patch=$native/angle-dylibs.patch
    if [[ $(git -C "$sources/WebKit" rev-parse HEAD 2> /dev/null) != ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10 || ! -f $angle/.swiftvm-patched ]]; then
        git -C "$sources/WebKit" checkout --quiet --force ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10
        patch --batch -d "$angle" -p1 < "$angle_patch" > /dev/null || fail "${angle_patch:t} doesn't apply to ANGLE."
        touch "$angle/.swiftvm-patched"
    fi
    local angle_build=(xcodebuild archive -archivePath "$prefix/ANGLE" -scheme ANGLE -sdk macosx -arch arm64 -configuration Release
        WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR= CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO
        MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET 'WK_LIBCPP_ASSERTIONS_CFLAGS_MACOS_SINCE_1400=-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE')
    # Xcode keeps what it built outside the cache, so ANGLE is built again only when what goes into it
    # changes, rather than from the start whenever anything else does.
    local angle_stamp=$( { print -r -- "${angle_build[*]}"; git -C "$sources/WebKit" rev-parse HEAD; cat "$angle_patch"; xcodebuild -version; } | shasum -a 256 | cut -d' ' -f1)
    if [[ ! -f $prefix/ANGLE.xcarchive/.swiftvm-stamp || $(<"$prefix/ANGLE.xcarchive/.swiftvm-stamp") != $angle_stamp ]]; then
        (cd "$angle" && $angle_build)
        print -r -- "$angle_stamp" > "$prefix/ANGLE.xcarchive/.swiftvm-stamp"
    fi
    cp -R "$prefix/ANGLE.xcarchive/Products/usr/local/lib/" "$prefix/lib/"
    cp -R "$angle/include/" "$prefix/include/"
    unpack epoxy.tar.gz epoxy "$native/epoxy-dylibs.patch"
    meson_build "$sources/epoxy" -Dtests=false -Dglx=no -Degl=yes -Dx11=false "-Dc_args=-I$prefix/include"
    unpack virglrenderer.tar.gz virglrenderer
    meson_build "$sources/virglrenderer" -Dtests=false -Dvtest=false -Dvenus=false -Dneptune=true -Dcheck-gl-errors=false \
        -Drender-server-mode=process "-Dc_args=-I$prefix/include"

    [[ $direct3d == yes ]] || return 0
    # DXMT's shader translator takes LLVM 15: its libraries alone, apart from any LLVM on this Mac.
    unpack llvm-project-15.0.7.src.tar.xz llvm-project
    cmake -S "$sources/llvm-project/llvm" -B "$sources/llvm-project/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix/llvm15" -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_TARGETS_TO_BUILD= -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=OFF
    cmake --build "$sources/llvm-project/build"
    cmake --install "$sources/llvm-project/build"
    unpack directx.tar.gz directx-headers
    unpack dxmt.tar.gz dxmt "$native/dxmt-shared-resource-initialization.patch" "$native/dxmt-shared-resource-tests.patch"
    if [[ ! -e $sources/dxmt/include/native/directx/d3d11.h ]]; then
        rmdir "$sources/dxmt/include/native/directx"
        ln -s ../../../directx-headers "$sources/dxmt/include/native/directx"
    fi
    meson_build "$sources/dxmt" -Dnative_llvm_path="$prefix/llvm15"
}

# The library the app shows a machine's screen with: CocoaSpice, UTM's SPICE client for Metal, and
# SpiceDisplay.m, which gives it the interface in GuestDisplayBridge.
build_display() {
    unpack cocoaspice-pinned.tar.gz cocoaspice "$native/cocoaspice-renderer.patch" "$native/cocoaspice-screenshot.patch" \
        "$native/cocoaspice-seamless.patch"
    local cocoa=$sources/cocoaspice
    local renderer=$cocoa/Sources/CocoaSpiceRenderer client=$cocoa/Sources/CocoaSpice module=$work/display-module objects=$work/display-objects
    mkdir -p "$module/CocoaSpiceRenderer" "$objects" "$prefix/share/CocoaSpice_CocoaSpiceRenderer.bundle"
    cp "$renderer"/include/*.h "$module/CocoaSpiceRenderer/"
    print 'module CocoaSpiceRenderer { umbrella header "CocoaSpiceRenderer.h" export * }' > "$module/CocoaSpiceRenderer/module.modulemap"
    local flags=(-fobjc-arc -fmodules -O2 -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -I"$module" -I"$client" -I"$client/include" -I"$renderer/include" -I"$bridge")
    flags+=(${(z)$(pkg-config --cflags spice-client-glib-2.0 gstreamer-1.0)})
    local compiled=() file
    for file in "$client"/*.m "$renderer/CSMetalRenderer.m" "$native/SpiceDisplay.m"; do
        case ${file:t} in gst_ios_init.m|CSUSBDevice.m|CSUSBManager.m) continue ;; esac
        clang $flags -c "$file" -o "$objects/${file:t:r}.o"
        compiled+=("$objects/${file:t:r}.o")
    done
    clang -dynamiclib -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -install_name @rpath/libSwiftVMDisplay.dylib $compiled \
        -framework AppKit -framework Metal -framework MetalKit -framework IOSurface -framework QuartzCore -framework CoreGraphics \
        ${(z)$(pkg-config --libs spice-client-glib-2.0 gstreamer-1.0)} -o "$prefix/lib/libSwiftVMDisplay.dylib"
    xcrun -sdk macosx metal -c "$renderer/CSShaders.metal" -I"$renderer/include" -o "$objects/CSShaders.air"
    xcrun -sdk macosx metallib "$objects/CSShaders.air" -o "$prefix/share/CocoaSpice_CocoaSpiceRenderer.bundle/default.metallib"
}

build_qemu() {
    # Its build stays with the sources, and goes with them when its patches change, so that the next
    # compiles only what changed. configure sets Meson up afresh each time.
    unpack qemu-$qemu_version.tar.xz qemu "$native"/qemu-*.patch
    mkdir -p "$sources/qemu/build"
    (
        cd "$sources/qemu/build"
        ../configure --python="$python" --prefix=/ --extra-cflags="-I$prefix/include" $configure_options
        ninja qemu-system-aarch64
    )
}

typeset -A copied
# Copies the libraries $1 loads into lib/, as far as they aren't the system's, and the ones those load
# in turn. Each is found by its name next to the others, wherever the result goes.
copy_libraries() {
    local file=$1 reference original name
    for reference in $(otool -L "$file" | tail -n +2 | awk '{ print $1 }'); do
        [[ $reference == /usr/lib/* || $reference == /System/* ]] && continue
        name=${reference:t}
        [[ $name == ${file:t} ]] && continue
        original=$reference
        [[ $reference != @* ]] || original=$prefix/lib/$name
        if [[ -z ${copied[$name]:-} ]]; then
            [[ -f $original ]] || fail "QEMU needs $original, which isn't there."
            cp -L "$original" "$out/lib/$name"
            chmod u+w "$out/lib/$name"
            copied[$name]=1
            install_name_tool -id "@rpath/$name" "$out/lib/$name" 2> /dev/null
            copy_libraries "$out/lib/$name"
        fi
        install_name_tool -change "$reference" "@rpath/$name" "$file" 2> /dev/null
    done
}

package() {
    local source_dir=$sources/qemu
    out=$work/QEMU
    mkdir -p "$out/bin" "$out/lib" "$out/share/keymaps" "$out/licenses"
    cp "$source_dir/build/qemu-system-aarch64" "$out/bin/"
    cp "$prefix/libexec/virgl_render_server" "$out/bin/"
    # What nothing links, as these are opened while QEMU runs: ANGLE by epoxy, and DXMT by virglrenderer.
    local name file search_path minimum
    local opened=(libSwiftVMDisplay.dylib libEGL.dylib libGLESv2.dylib)
    [[ $direct3d != yes ]] || opened+=(libdxmt-native.dylib)
    for name in $opened; do
        cp -L "$prefix/lib/$name" "$out/lib/$name"
        chmod u+w "$out/lib/$name"
        copied[$name]=1
        install_name_tool -id "@rpath/$name" "$out/lib/$name"
        copy_libraries "$out/lib/$name"
    done
    for file in "$out"/bin/*; do copy_libraries "$file"; done
    for file in "$out"/bin/* "$out"/lib/*.dylib; do
        # The build's own search paths go; what is left is the place the libraries are in.
        for search_path in $(otool -l "$file" | awk '/cmd LC_RPATH/ { found=1; next } found && $1 == "path" { print $2; found=0 }'); do
            install_name_tool -delete_rpath "$search_path" "$file" 2> /dev/null
        done
        if [[ $file == "$out/bin/"* ]]; then
            install_name_tool -add_rpath @executable_path/../lib "$file" 2> /dev/null
            strip -x "$file" 2> /dev/null
        else
            install_name_tool -add_rpath @loader_path "$file" 2> /dev/null
        fi
        if otool -L "$file" | tail -n +2 | awk '{ print $1 }' | grep -q -e "^$brew_prefix" -e "^$cache"; then
            fail "${file:t} still looks for a library in Homebrew's folder or the build's."
        fi
        # Homebrew builds its libraries for the macOS it runs on, which may be later than the app's.
        minimum=$(vtool -show-build "$file" | awk '$1 == "minos" { print $2; exit }')
        [[ $(printf '%s\n%s\n' "$minimum" "$MACOSX_DEPLOYMENT_TARGET" | sort -V | tail -1) == "$MACOSX_DEPLOYMENT_TARGET" ]] \
            || fail "${file:t} needs macOS $minimum, and the app runs on $MACOSX_DEPLOYMENT_TARGET."
    done

    # The firmware comes padded to the 64 MB of the machine's flash, almost all of it zeros. The program
    # takes it without the padding; the template for a machine's own variables is padded again by the
    # app, as a sparse file, when it makes one.
    for name in edk2-aarch64-code.fd edk2-arm-vars.fd; do
        bunzip2 -c "$source_dir/pc-bios/$name.bz2" > "$work/$name"
        "$python" -c '
import sys
data = open(sys.argv[1], "rb").read().rstrip(b"\0")
open(sys.argv[2], "wb").write(data + b"\0" * (-len(data) % 65536))
' "$work/$name" "$out/share/$name"
    done
    # The VNC server won't start without a keyboard layout, although the app hands it keys by their
    # place on the keyboard, which no layout changes.
    cp "$source_dir/pc-bios/keymaps/en-us" "$out/share/keymaps/"
    # CocoaSpice looks for its Metal shaders in a bundle of this name.
    cp -R "$prefix/share/CocoaSpice_CocoaSpiceRenderer.bundle" "$out/share/"
    # Windows' 3D driver, which its guest tools install.
    [[ $direct3d != yes ]] || cp "$sources/viogpu3d-arm64x-signed.zip" "$out/share/"

    cp "$source_dir/COPYING" "$out/licenses/QEMU-COPYING"
    cp "$source_dir/COPYING.LIB" "$out/licenses/QEMU-COPYING.LIB"
    cp "$source_dir/LICENSE" "$out/licenses/QEMU-LICENSE"
    cp "$source_dir/pc-bios/edk2-licenses.txt" "$out/licenses/"
    cp "$native"/*.patch "$native/sources.tsv" "$out/licenses/"
    cp "$script" "$out/licenses/build-qemu.sh"
    [[ $direct3d != yes ]] || cp "$sources"/triton-*LICENSE "$sources"/mesa-* "$out/licenses/"
    "$python" - "$sources" "$out/licenses" "$direct3d" <<'PY'
import pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:3])
direct3d = sys.argv[3] == 'yes'
for component in source.iterdir():
    if not component.is_dir() or component.name in ('WebKit', 'llvm-project', 'qemu'):
        continue
    if not direct3d and component.name in ('dxmt', 'directx-headers'):
        continue
    for pattern in ('COPYING*', 'LICENSE*', 'LICENCE*'):
        for path in component.glob(pattern):
            dest = target / component.name
            dest.mkdir(exist_ok=True)
            if path.is_file():
                shutil.copy2(path, dest / path.name)
            elif path.is_dir():
                shutil.copytree(path, dest / path.name, dirs_exist_ok=True)
angle = source / 'WebKit/Source/ThirdParty/ANGLE'
for pattern in ('LICENSE*', 'COPYING*'):
    for path in angle.rglob(pattern):
        if path.is_file():
            dest = target / 'ANGLE' / path.relative_to(angle)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
if direct3d:
    shutil.copy2(source / 'llvm-project/llvm/LICENSE.TXT', target / 'LLVM-LICENSE.TXT')
    shutil.copy2(source / 'dxmt/src/util/dxvk.LICENSE', target / 'DXVK-LICENSE')
PY
    local license
    # gettext's own licence is the GPL of its tools. Its libintl is under the LGPL 2.1 or later, as glib is.
    # glib's libffi is the system's.
    for license in glib/LGPL-2.1-or-later.txt pixman/COPYING pcre2/LICENCE.md openssl@3/LICENSE.txt gettext/COPYING; do
        [[ -f $brew_prefix/opt/$license ]] || fail "The licence of ${license%%/*} isn't at $brew_prefix/opt/$license."
        cp "$brew_prefix/opt/$license" "$out/licenses/${license%%/*}-${license:t}"
    done
    cat > "$out/README.txt" <<EOF
QEMU $qemu_version, built for SwiftVM to run Windows guests and Linux guests with graphics
acceleration.

QEMU is free software under the GNU General Public License, version 2. Its source is at
https://download.qemu.org/qemu-$qemu_version.tar.xz, with the patches in licenses/, and it was
configured with:
  ${configure_options[*]}
licenses/build-qemu.sh, which is scripts/build-qemu.sh in SwiftVM's repository, builds it and
everything else here. licenses/sources.tsv names every source that went in, with its checksum.

qemu-graphics.patch and qemu-hvf-ipa-granule.patch carry graphics acceleration on macOS
over from UTM's QEMU (github.com/utmapp/qemu). qemu-vnc-refresh.patch adjusts VNC's
refresh timing for a local display.

The libraries in lib/ are SPICE, GStreamer, json-glib, libjpeg-turbo, libepoxy,
virglrenderer and ANGLE, built from those sources, and Homebrew's builds of glib $(pkg-config --modversion glib-2.0),
pixman $(pkg-config --modversion pixman-1), OpenSSL, PCRE2 and gettext's libintl. SPICE, GStreamer, glib and
libintl are under the GNU Lesser General Public License 2.1 or later. libSwiftVMDisplay is
CocoaSpice (Apache 2.0) with SwiftVM's display code. The firmware in share/ is EDK II, as it
comes with QEMU's source. The licences are in licenses/.
EOF
    [[ $direct3d != yes ]] || print -r -- "
lib/libdxmt-native.dylib is DXMT (LGPL 2.1), built with LLVM 15. share/viogpu3d-arm64x-signed.zip
is the Windows driver from github.com/osy/kvm-guest-drivers-windows v0.3." >> "$out/README.txt"

    # Signed to run on this Mac, so that it does so by itself. In the app it is signed again.
    for file in "$out"/lib/*.dylib "$out/bin/virgl_render_server"; do
        codesign --force --sign - "$file" 2> /dev/null
    done
    print '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>' > "$work/entitlements.plist"
    codesign --force --sign - --entitlements "$work/entitlements.plist" "$out/bin/qemu-system-aarch64" 2> /dev/null
    "$out/bin/qemu-system-aarch64" --version > /dev/null || fail "The QEMU that was built doesn't run."
}

print -u2 "Building QEMU $qemu_version and its graphics (the first build takes a while)…"
fetch_sources
# zsh leaves errexit off in a subshell whose failure is handled, so it is turned on in there, with the
# failure handled outside.
set +e
(
    set -e
    build_libraries
    build_display
    build_qemu
) > "$log" 2>&1
built=$?
set -e
(( built == 0 )) || fail "QEMU couldn't be built. What the build said is in $log."$'\n'"$(tail -30 "$log")"
package

# Results of earlier versions of this script are of no use any more.
for earlier in "$cache"/*-*(N/); do
    [[ $earlier == $cache/$qemu_version-$key ]] || rm -rf "$earlier"
done
mkdir -p "${result:h}"
mv "$out" "$result"
print -r -- "$result"
