#!/bin/zsh
# Puts the app together from what `swift build` has made, and signs it. scripts/build.sh and
# scripts/run-dev.sh call this; there is rarely a reason to run it by hand.
#   scripts/bundle-app.sh --products <folder> --helpers <folder> --output <app> [--development]
#
#   --products      where the build put the app's program, SwiftVM, and SwiftVMKit_Installers.bundle
#   --helpers       where the build of Packages/SwiftVMKit put swiftvm and swiftvm-agent
#   --output        the app to make. A copy of SwiftVM that is there is replaced, unless it is running
#   --development   make the development copy, "SwiftVM Dev": an app of its own to macOS, which keeps
#                   its machines apart from the app's (AppIdentity in Packages/SwiftVMKit)
#
# The app is signed with a certificate from the keychain if there is one: Developer ID Application
# before Apple Development, and the other way round for the development copy, which also keeps to the
# certificate it was first signed with (.build/development-signing-identity) so that macOS doesn't ask
# for the microphone again after every build. Without a certificate the app is signed to run on this
# Mac, which is enough to run virtual machines. SWIFTVM_SIGN_IDENTITY picks a certificate by name or
# SHA-1; "-" signs to run on this Mac.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"

products="" helpers="" output="" development=false
while (( $# )); do
    case $1 in
        --products) products=${2:?}; shift 2 ;;
        --helpers) helpers=${2:?}; shift 2 ;;
        --output) output=${2:?}; shift 2 ;;
        --development) development=true; shift ;;
        *) fail "Usage: scripts/bundle-app.sh --products <folder> --helpers <folder> --output <app> [--development]" ;;
    esac
done
[[ -n $products && -n $helpers && $output == *.app ]] \
    || fail "Usage: scripts/bundle-app.sh --products <folder> --helpers <folder> --output <app> [--development]"
for built in "$products/SwiftVM" "$products/SwiftVMKit_Installers.bundle" "$helpers/swiftvm" "$helpers/swiftvm-agent"; do
    [[ -e $built ]] || fail "$built isn't there. Build first: scripts/build.sh, or swift run SwiftVM."
done
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
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources"

cp "$products/SwiftVM" "$contents/MacOS/SwiftVM"
cp "$helpers/swiftvm" "$helpers/swiftvm-agent" "$contents/Helpers/"
# The resources of the package's Installers module, where Bundle.module looks for them in an app.
cp -R "$products/SwiftVMKit_Installers.bundle" "$contents/Resources/"
# The build signed that bundle to run locally. Inside the app it is covered by the app's signature.
rm -rf "$contents/Resources/SwiftVMKit_Installers.bundle/Contents/_CodeSignature"

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

sign() {
    local report
    report=$(codesign --force --sign "$identity" --options runtime --timestamp=none "$@" 2>&1) && return 0
    local hint=""
    if $from_memory; then
        hint=$'\n'"The certificate is the one the development copy was first signed with. If it is gone, delete $remembered to choose again."
    fi
    fail "Signing failed:"$'\n'"$report$hint"
}
# Inside out: what is inside the app has to be signed before the app is.
sign --identifier com.swiftvm.app.swiftvm "$contents/Helpers/swiftvm"
sign --identifier com.swiftvm.app.swiftvm-agent "$contents/Helpers/swiftvm-agent"
sign --entitlements "$stage/entitlements.plist" "$app"
codesign --verify --strict "$app" || fail "The signature of $app doesn't hold."
if $remember; then
    print -r -- "$identity" > "$remembered"
fi

replace_app "$app" "$output"
print -r -- "$output"
