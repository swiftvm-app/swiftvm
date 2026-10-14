#!/bin/zsh
# Puts the app together from what `swift build` has made, and signs it. scripts/build.sh and
# scripts/run-dev.sh call this; there is rarely a reason to run it by hand.
#   scripts/bundle-app.sh --products <folder> --helpers <folder> --output <app> [--development]
#
#   --products      where the build put the app's program, SwiftVM, with SwiftVMKit_Installers.bundle
#                   and Sparkle.framework
#   --helpers       where the build of Packages/SwiftVMKit put swiftvm and swiftvm-agent
#   --output        the app to make. A copy of SwiftVM that is there is replaced, unless it is running
#   --development   make the development copy, "SwiftVM Dev": an app of its own to macOS, which keeps
#                   its machines apart from the app's (AppIdentity in Packages/SwiftVMKit)
#   --qemu          the QEMU that scripts/build-qemu.sh made, which runs Windows guests. Without it the
#                   app runs every other guest, and says so when a Windows one is to start
#
# For a release, which scripts/build-release.sh makes:
#   --version             what the app calls its version, in place of the one in Config/Info.plist
#   --build-number        what tells a newer build from an older one
#   --sparkle-feed-url    where the app looks for updates of itself. Without it and the key, as in
#   --sparkle-public-key  every other build, the app doesn't update
#   --timestamp           sign with a timestamp from Apple, which notarization asks for
#
# The app is signed with a certificate from the keychain if there is one: Developer ID Application
# before Apple Development, and the other way round for the development copy, which also keeps to the
# certificate it was first signed with (.build/development-signing-identity) so that macOS doesn't ask
# for the microphone again after every build. Without a certificate the app is signed to run on this
# Mac, which is enough to run virtual machines. SWIFTVM_SIGN_IDENTITY picks a certificate by name or
# SHA-1; "-" signs to run on this Mac.
#
# Handing USB devices to guests takes more: an entitlement that macOS only honours together with a
# provisioning profile, made in an Apple Developer account for this app's identifier with the capability
# "Claim USB Accessory", and for the certificate the app is signed with. When there is such a profile
# where Xcode keeps profiles, it goes into the app with the entitlement. When there is none the app is
# built without both and does everything but USB. SWIFTVM_PROVISIONING_PROFILE names a profile to use
# instead of looking for one; "-" builds without.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"

products="" helpers="" output="" qemu="" development=false
version="" build_number="" sparkle_feed_url="" sparkle_public_key="" timestamp=--timestamp=none
while (( $# )); do
    case $1 in
        --products) products=${2:?}; shift 2 ;;
        --helpers) helpers=${2:?}; shift 2 ;;
        --output) output=${2:?}; shift 2 ;;
        --development) development=true; shift ;;
        --qemu) qemu=${2:?}; shift 2 ;;
        --version) version=${2:?}; shift 2 ;;
        --build-number) build_number=${2:?}; shift 2 ;;
        --sparkle-feed-url) sparkle_feed_url=${2:?}; shift 2 ;;
        --sparkle-public-key) sparkle_public_key=${2:?}; shift 2 ;;
        --timestamp) timestamp=--timestamp; shift ;;
        *) fail "Usage: scripts/bundle-app.sh --products <folder> --helpers <folder> --output <app> [--development]" ;;
    esac
done
[[ -z $sparkle_feed_url$sparkle_public_key || ( -n $sparkle_feed_url && -n $sparkle_public_key ) ]] \
    || fail "--sparkle-feed-url and --sparkle-public-key go together: an app that knows where its updates are has to be able to check them."
[[ -n $products && -n $helpers && $output == *.app ]] \
    || fail "Usage: scripts/bundle-app.sh --products <folder> --helpers <folder> --output <app> [--development]"
for built in "$products/SwiftVM" "$products/SwiftVMKit_Installers.bundle" "$products/Sparkle.framework" "$helpers/swiftvm" "$helpers/swiftvm-agent"; do
    [[ -e $built ]] || fail "$built isn't there. Build first: scripts/build.sh, or swift run SwiftVM."
done
[[ -z $qemu || -x $qemu/bin/qemu-system-aarch64 ]] || fail "$qemu isn't a QEMU that scripts/build-qemu.sh made."
# The disk takes swiftvm and SwiftVM for one name. The swiftvm tool, built at the repository's root, lands
# in the folder of the app's program and replaces it, and the next build of the app doesn't notice.
built=("$products"/*(N:t))
(( ${built[(Ie)SwiftVM]} )) || fail "$products/SwiftVM isn't the app's program but the swiftvm tool, which was built at the repository's root. Delete that file and build again. The tool on its own is built with: swift build --package-path Packages/SwiftVMKit --product swiftvm"

if $development; then
    identifier=com.swiftvm.app.dev
    name="SwiftVM Dev"
    certificates=("Apple Development" "Developer ID Application")
else
    identifier=com.swiftvm.app
    name=SwiftVM
    certificates=("Developer ID Application" "Apple Development")
fi

# Said now rather than after the work is done.
check_replaceable "$output"

mkdir -p "$root/.build"
stage=$(mktemp -d "$root/.build/bundle.XXXXXX")
trap 'rm -rf "$stage"' EXIT
# zsh skips the line above when a signal ends the script, unless the signal is turned into an exit.
trap 'exit 130' INT TERM HUP
app=$stage/${output:t}
contents=$app/Contents
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources" "$contents/Frameworks"

cp "$products/SwiftVM" "$contents/MacOS/SwiftVM"
cp "$helpers/swiftvm" "$helpers/swiftvm-agent" "$contents/Helpers/"
if [[ -n $qemu ]]; then
    # Code in Helpers, where only code may be; the firmware and the licences with the resources.
    mkdir -p "$contents/Helpers/QEMU" "$contents/Resources/QEMU"
    cp -R "$qemu/bin" "$qemu/lib" "$contents/Helpers/QEMU/"
    cp -R "$qemu/share" "$qemu/licenses" "$qemu/README.txt" "$contents/Resources/QEMU/"
fi
# The resources of the package's Installers module, where Bundle.module looks for them in an app.
cp -R "$products/SwiftVMKit_Installers.bundle" "$contents/Resources/"
# The build signed that bundle to run locally. Inside the app it is covered by the app's signature.
rm -rf "$contents/Resources/SwiftVMKit_Installers.bundle/Contents/_CodeSignature"

# Sparkle, which updates the app. The build left it next to the program; in an app its place is
# Contents/Frameworks, and the program has to be told to look there.
cp -R "$products/Sparkle.framework" "$contents/Frameworks/"
report=$(install_name_tool -add_rpath @executable_path/../Frameworks "$contents/MacOS/SwiftVM" 2>&1) \
    || fail "The app's program couldn't be told where Sparkle is:"$'\n'"$report"

# The icon and the asset catalog, compiled the way Xcode would. That takes a second or two, so the
# result is kept until one of them changes, or this script does.
assets=$root/.build/app-assets
if [[ ! -f $assets/Assets.car || ! -f $assets/AppIcon.icns
    || -n $(find "$root/App/Assets.xcassets" "$root/App/AppIcon.icon" "${0:A}" -newer "$assets/Assets.car" -print -quit) ]]; then
    mkdir "$stage/assets"
    report=$(xcrun actool "$root/App/Assets.xcassets" "$root/App/AppIcon.icon" --compile "$stage/assets" \
        --app-icon AppIcon --accent-color AccentColor --platform macosx --minimum-deployment-target 27.0 \
        --output-partial-info-plist "$stage/assets/partial.plist" --output-format human-readable-text 2>&1) \
        || fail "The icon and the assets couldn't be compiled:"$'\n'"$report"
    [[ -f $stage/assets/Assets.car && -f $stage/assets/AppIcon.icns ]] \
        || fail "The icon and the assets couldn't be compiled:"$'\n'"$report"
    rm -rf "$assets"
    mv "$stage/assets" "$assets"
fi
cp "$assets/Assets.car" "$assets/AppIcon.icns" "$contents/Resources/"

cp "$root/Config/Info.plist" "$contents/Info.plist"
cp "$root/Config/SwiftVM.entitlements" "$stage/entitlements.plist"
if $development; then
    plutil -replace CFBundleIdentifier -string "$identifier" "$contents/Info.plist"
    plutil -replace CFBundleName -string "$name" "$contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "$name" "$contents/Info.plist"
    # The development copy doesn't offer itself for machines: one that is opened from the Finder goes to
    # the app, and is never added to the development copy's library by a double click.
    plutil -remove CFBundleDocumentTypes "$contents/Info.plist"
    # Lets a debugger attach, which the hardened runtime otherwise forbids.
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$stage/entitlements.plist"
fi
if [[ -n $version ]]; then
    plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
fi
if [[ -n $build_number ]]; then
    plutil -replace CFBundleVersion -string "$build_number" "$contents/Info.plist"
fi
if [[ -n $sparkle_feed_url ]]; then
    plutil -replace SUFeedURL -string "$sparkle_feed_url" "$contents/Info.plist"
    plutil -replace SUPublicEDKey -string "$sparkle_public_key" "$contents/Info.plist"
fi
print -n 'APPL????' > "$contents/PkgInfo"

remembered=$root/.build/development-signing-identity
identity=${SWIFTVM_SIGN_IDENTITY:-}
remember=false
from_memory=false
if [[ -z $identity ]]; then
    if $development && [[ -s $remembered ]]; then
        identity=$(<$remembered)
        from_memory=true
    else
        available=$(security find-identity -v -p codesigning 2>/dev/null || true)
        for certificate in $certificates; do
            identity=$(print -r -- "$available" | awk -v name="\"$certificate: " 'index($0, name) { print $2; exit }')
            [[ -z $identity ]] || break
        done
        if [[ -n $identity ]]; then
            remember=$development
        else
            identity=-
            print -u2 "No signing certificate in the keychain: signing $name to run on this Mac."
        fi
    fi
fi

# The hardened runtime only loads libraries that are signed by the app's own team, and a signature to
# run on this Mac names no team at all: Sparkle wouldn't load, and the app wouldn't start.
if [[ $identity == - ]]; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$stage/entitlements.plist"
fi

# The certificate's SHA-1, which is how a provisioning profile names the certificates it goes with.
certificate=""
if [[ $identity =~ '^[0-9A-Fa-f]{40}$' ]]; then
    certificate=$identity
elif [[ $identity != - ]]; then
    certificate=$(security find-identity -v -p codesigning 2> /dev/null | awk -v name="$identity" 'index($0, name) { print $2; exit }' || true)
fi

# The entitlement for USB devices and the profile that grants it go in together or not at all: an app
# with the entitlement and no profile to go with it is ended by macOS the moment it starts.
profile=${SWIFTVM_PROVISIONING_PROFILE:-}
if [[ $profile == - ]]; then
    profile=""
elif [[ -n $profile ]]; then
    [[ -f $profile ]] || fail "SWIFTVM_PROVISIONING_PROFILE: $profile isn't there."
    [[ -n $certificate ]] || fail "SWIFTVM_PROVISIONING_PROFILE: a provisioning profile goes with a signing certificate, and $name is being signed to run on this Mac."
    decode_profile "$profile" "$stage/profile.plist" || fail "SWIFTVM_PROVISIONING_PROFILE: $profile isn't a provisioning profile."
    problem=$(profile_problem "$stage/profile.plist" "$identifier" "$certificate")
    [[ -z $problem ]] || fail "SWIFTVM_PROVISIONING_PROFILE: the profile $problem."
elif [[ -n $certificate ]]; then
    find_usb_profile "$identifier" "$certificate" $profile_folders
    profile=${reply[1]:-}
    if [[ -z $profile ]]; then
        print -u2 -r -- "No provisioning profile for $identifier that goes with this certificate${REPLY:+ (the profile $REPLY)}: building $name without USB passthrough."
    fi
elif [[ $identity != - ]]; then
    print -u2 -r -- "Couldn't tell which certificate “$identity” is, so no provisioning profile goes with it: building $name without USB passthrough."
else
    print -u2 -r -- "A provisioning profile goes with a signing certificate, and $name is signed to run on this Mac: building it without USB passthrough."
fi
if [[ -n $profile ]]; then
    decode_profile "$profile" "$stage/profile.plist" || fail "$profile isn't a provisioning profile."
    cp "$profile" "$contents/embedded.provisionprofile"
    # What says to macOS that this is the app the profile was made for.
    for key in com.apple.application-identifier com.apple.developer.team-identifier; do
        value=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$stage/profile.plist" 2> /dev/null) \
            || fail "The provisioning profile $profile doesn't say $key, which the app's signature has to repeat."
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$stage/entitlements.plist"
    done
    /usr/libexec/PlistBuddy -c "Add :$usb_entitlement bool true" "$stage/entitlements.plist"
fi

sign() {
    local report
    report=$(codesign --force --sign "$identity" --options runtime $timestamp "$@" 2>&1) && return 0
    local hint=""
    if $from_memory; then
        hint=$'\n'"The certificate is the one the development copy was first signed with. If it is gone, delete $remembered to choose again."
    fi
    fail "Signing failed:"$'\n'"$report$hint"
}
# Inside out: what is inside the app has to be signed before the app is. Sparkle comes signed to run
# locally, and its parts are signed over one by one, the way its own instructions have it.
sparkle=$contents/Frameworks/Sparkle.framework/Versions/B
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$contents/Frameworks/Sparkle.framework"
sign --identifier com.swiftvm.app.swiftvm "$contents/Helpers/swiftvm"
sign --identifier com.swiftvm.app.swiftvm-agent "$contents/Helpers/swiftvm-agent"
if [[ -n $qemu ]]; then
    for library in "$contents"/Helpers/QEMU/lib/*.dylib(N); do
        sign "$library"
    done
    # QEMU runs guests on the Hypervisor framework, which takes an entitlement of its own. Its libraries
    # are signed as the app's are, so the same holds for loading them.
    print '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>' > "$stage/qemu-entitlements.plist"
    if [[ $identity == - ]]; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$stage/qemu-entitlements.plist"
    fi
    sign --identifier com.swiftvm.app.qemu --entitlements "$stage/qemu-entitlements.plist" "$contents/Helpers/QEMU/bin/qemu-system-aarch64"
fi
sign --entitlements "$stage/entitlements.plist" "$app"
codesign --verify --deep --strict "$app" || fail "The signature of $app doesn't hold."
if $remember; then
    print -r -- "$identity" > "$remembered"
fi

replace_app "$app" "$output"
print -r -- "$output"
