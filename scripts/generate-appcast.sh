#!/bin/zsh
# Writes the list of updates that the app reads (Sparkle's appcast), with one more entry in it: the
# disk image of a release, signed with the key the app checks its updates against.
#   scripts/generate-appcast.sh <disk image> <tag> <build number> [<output>]
#
#   SPARKLE_PRIVATE_KEY   the private half of that key, as scripts/generate-sparkle-key.swift prints it
#   CHANNEL               stable, which is the default, or beta
#   EXISTING_APPCAST      the list as it was. The new entry goes in front of the ones it has
#   DOWNLOAD_URL_PREFIX   where the image is downloaded from, if not from the release of <tag>
#
# The tool that signs comes with Sparkle: `swift package resolve` fetches it.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"

(( $# >= 3 )) || fail "Usage: scripts/generate-appcast.sh <disk image> <tag> <build number> [<output>]"
image=$1 tag=$2 build_number=$3 output=${4:-appcast.xml}
channel=${CHANNEL:-stable}
repository=https://github.com/swiftvm-app/swiftvm
version=${tag#v}

[[ -f $image ]] || fail "$image isn't there."
is_release_version "$version" || fail "“$tag” isn't the tag of a release: v1.2.3, or v1.2.3-beta.45."
[[ -n ${SPARKLE_PRIVATE_KEY:-} ]] || fail "SPARKLE_PRIVATE_KEY isn't set, and an update that isn't signed is one the app turns down."
sign_update=$root/.build/artifacts/sparkle/Sparkle/bin/sign_update
[[ -x $sign_update ]] || fail "$sign_update isn't there. Run swift package resolve first."

signature=$(print -r -- "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - -p "$image")
[[ -n $signature ]] || fail "$image couldn't be signed."
channel_element=""
if [[ $channel != stable ]]; then
    channel_element=$'\n'"      <sparkle:channel>$channel</sparkle:channel>"
fi

item=$(mktemp)
trap 'rm -f "$item"' EXIT
cat > "$item" <<ITEM
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S %z")</pubDate>$channel_element
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$repository/releases/tag/$tag</sparkle:fullReleaseNotesLink>
      <enclosure url="${DOWNLOAD_URL_PREFIX:-$repository/releases/download/$tag/}${image:t}" sparkle:edSignature="$signature" length="$(stat -f%z "$image")" type="application/octet-stream" />
    </item>
ITEM

if [[ -n ${EXISTING_APPCAST:-} && -f $EXISTING_APPCAST ]]; then
    VERSION=$version python3 - "$EXISTING_APPCAST" "$output" "$item" <<'MERGE'
import os, sys
existing, output, item = sys.argv[1:4]
version = os.environ["VERSION"]
with open(existing, encoding="utf-8") as file:
    appcast = file.read()
with open(item, encoding="utf-8") as file:
    entry = file.read()
if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in appcast:
    # Published before: the entry that is there stays, with the signature it was given then.
    sys.stderr.write(f"Version {version} is in the appcast already.\n")
else:
    first = appcast.find("<item>")
    if first == -1:
        end = appcast.find("</channel>")
        if end == -1:
            sys.exit(f"{existing} isn't an appcast.")
        start = appcast.rfind("\n", 0, end) + 1
        appcast = appcast[:start] + entry + appcast[start:]
    else:
        appcast = appcast[:first] + entry.lstrip() + "    " + appcast[first:]
with open(output, "w", encoding="utf-8") as file:
    file.write(appcast)
MERGE
else
    cat > "$output" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>SwiftVM Updates ($channel)</title>
    <link>$repository</link>
    <description>Updates for SwiftVM ($channel channel)</description>
    <language>en</language>
$(<$item)
  </channel>
</rss>
APPCAST
fi

grep -q 'sparkle:edSignature' "$output" || fail "$output has no signed update in it."
print -r -- "$output"
