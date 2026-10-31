#!/bin/sh
# Installs the pinned native agent-desktop release and its helper together, without Node.
# Called by the guest tools installer under its installation lock. Nothing runs on the host.
set -eu
umask 022
directory=/usr/local/lib/swiftvm
version=1.0.2
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin; digest=7bee385196d7b478de80cf05ca4304aaa38f0eba593b3406ad3c247c1773be19; helper=agent-desktop-macos-helper ;;
    Darwin:x86_64) target=x86_64-apple-darwin; digest=8edda6df17eafc042395502a823dbb8415bc8ac14835a6731e4d8becc9cb4121; helper=agent-desktop-macos-helper ;;
    Linux:aarch64) target=aarch64-unknown-linux-gnu; digest=864cb782e0afc8bf0df19622016b24bdbd1a83fc7749f784ee82aa49a7f845eb; helper=agent-desktop-linux-clipboard-owner ;;
    Linux:x86_64) target=x86_64-unknown-linux-gnu; digest=ad661b7a3fd8f990a769243f4889a240ca0e2c8dab3ef5bddd6019086c71e0b4; helper=agent-desktop-linux-clipboard-owner ;;
    *) echo 'agent-desktop has no native release for this system.' >&2; exit 1 ;;
esac
installed="$directory/agent-desktop"
# Reinstall from the verified archive, never by executing a possibly altered installed copy as root.
work=$(mktemp -d "$directory/.agent-desktop.XXXXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
url="https://github.com/vercel-labs/agent-desktop/releases/download/v$version/agent-desktop-v$version-$target.tar.gz"
if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 "$url" -o "$work/archive.tar.gz"
else
    # Python is already required by the Linux guest tools; minimal cloud images need no extra downloader.
    /usr/bin/python3 - "$url" "$work/archive.tar.gz" <<'PY'
import signal
import sys
import urllib.request
signal.alarm(60)
with urllib.request.urlopen(sys.argv[1], timeout=15) as response, open(sys.argv[2], "wb") as output:
    while True:
        chunk = response.read(65536)
        if not chunk:
            break
        output.write(chunk)
PY
fi
if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$work/archive.tar.gz" | cut -d ' ' -f 1)
else
    actual=$(sha256sum "$work/archive.tar.gz" | cut -d ' ' -f 1)
fi
[ "$actual" = "$digest" ] || { echo 'agent-desktop download failed its SHA-256 check.' >&2; exit 1; }
mkdir "$work/new"
tar --no-same-owner -xzf "$work/archive.tar.gz" -C "$work/new"
[ -x "$work/new/$helper" ] || { echo 'agent-desktop is missing its platform helper.' >&2; exit 1; }
# The version command starts a per-user host on macOS; the flag only checks the executable.
"$work/new/agent-desktop" --version
printf '%s\n' "$version" > "$work/new/.swiftvm-version"
chmod 755 "$work/new"
if [ -e "$installed" ]; then mv "$installed" "$work/previous"; fi
if ! mv "$work/new" "$installed"; then
    if [ -d "$work/previous" ]; then mv "$work/previous" "$installed"; fi
    exit 1
fi
