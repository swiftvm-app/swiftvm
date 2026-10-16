#!/bin/zsh
# Builds the app the way it is released: under a version of its own, able to update itself, signed with
# a timestamp so that Apple will notarize it, and packed into a disk image. The release workflows in
# .github/workflows run this; docs/tech/releasing.md says what they do with the result.
#   scripts/build-release.sh --version <X.Y.Z or X.Y.Z-beta.N> [options]
#
#   --version             what the app calls its version
#   --build-number        what tells a newer build from an older one: by default the number of commits
#   --sparkle-public-key  the public half of the key that updates are signed with, and
#   --sparkle-feed-url    where the app looks for updates. Without the two the app doesn't update
#   --output              the folder for the app and its disk image: build/release by default
#
# A release is signed with a Developer ID Application certificate and carries the provisioning profile
# that goes with it, for USB devices: scripts/bundle-app.sh finds both, or is told with
# SWIFTVM_SIGN_IDENTITY and SWIFTVM_PROVISIONING_PROFILE. Notarizing is the workflow's part.
#
# A release always carries the QEMU that runs Windows guests and Linux guests with graphics
# acceleration: scripts/build-qemu.sh says what building it takes.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"

usage="Usage: scripts/build-release.sh --version <X.Y.Z or X.Y.Z-beta.N> [--build-number <n>] [--sparkle-public-key <key> --sparkle-feed-url <url>] [--output <folder>]"
version="" build_number="" sparkle_public_key="" sparkle_feed_url="" output=$root/build/release
while (( $# )); do
    case $1 in
        --version) version=${2:?}; shift 2 ;;
        --build-number) build_number=${2:?}; shift 2 ;;
        --sparkle-public-key) sparkle_public_key=${2:?}; shift 2 ;;
        --sparkle-feed-url) sparkle_feed_url=${2:?}; shift 2 ;;
        --output) output=${${2:?}:a}; shift 2 ;;
        *) fail "$usage" ;;
    esac
done
is_release_version "$version" || fail "$usage"
if [[ ${SWIFTVM_PROVISIONING_PROFILE:--} != - ]]; then
    export SWIFTVM_PROVISIONING_PROFILE=${SWIFTVM_PROVISIONING_PROFILE:a}
fi
cd "$root"
if [[ -z $build_number ]]; then
    build_number=$(git rev-list --count HEAD)
fi
[[ $build_number == <1-> ]] || fail "--build-number has to be a number above zero, and “$build_number” isn't."

app=$output/SwiftVM.app
image=$output/SwiftVM-$version.dmg
check_replaceable "$app"

swift build -c release --product SwiftVM
swift build -c release --package-path Packages/SwiftVMKit --product swiftvm
swift build -c release --package-path Packages/SwiftVMKit --product swiftvm-agent
qemu=$("$root/scripts/build-qemu.sh")

bundle_options=(--version "$version" --build-number "$build_number" --timestamp --qemu "$qemu")
if [[ -n $sparkle_public_key || -n $sparkle_feed_url ]]; then
    bundle_options+=(--sparkle-public-key "$sparkle_public_key" --sparkle-feed-url "$sparkle_feed_url")
fi
"$root/scripts/bundle-app.sh" --output "$app" \
    --products "$(swift build -c release --show-bin-path)" \
    --helpers "$(swift build -c release --package-path Packages/SwiftVMKit --show-bin-path)" \
    $bundle_options > /dev/null

# The disk image holds the app and a way to the Applications folder, to drag the one onto the other.
rm -f "$image"
stage=$(mktemp -d "$root/.build/image.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' INT TERM HUP
if (( $+commands[create-dmg] )); then
    # It names the image after the app and its version, and tries to sign it with whatever certificate
    # it finds, which is this script's to do: what counts is that the image is there.
    create-dmg --overwrite "$app" "$stage" > /dev/null 2>&1 || true
    made=("$stage"/*.dmg(N))
    (( ${#made} == 1 )) || fail "create-dmg made no disk image of $app."
    mv "$made[1]" "$image"
else
    mkdir "$stage/SwiftVM"
    cp -R "$app" "$stage/SwiftVM/"
    ln -s /Applications "$stage/SwiftVM/Applications"
    hdiutil create -quiet -volname SwiftVM -srcfolder "$stage/SwiftVM" -format UDZO -ov "$image" \
        || fail "The disk image couldn't be made."
fi

# The image is signed like the app, so that it says who it is from before it is opened.
# The first authority codesign lists is the certificate itself. awk reads on to the end: leaving at the
# first line would cut codesign off in mid-sentence, which counts as a failure.
identity=$(codesign --display --verbose=2 "$app" 2>&1 | awk -F= '$1 == "Authority" && !found { print $2; found = 1 }')
if [[ -n $identity ]]; then
    codesign --force --sign "$identity" --timestamp "$image" || fail "The disk image couldn't be signed."
else
    print -u2 "SwiftVM is signed to run on this Mac, so the disk image isn't signed: it is no release."
fi

print "App: $app"
print "Disk image: $image"
