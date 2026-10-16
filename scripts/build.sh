#!/bin/zsh
# Builds the app, with the swiftvm command-line tool and the guest agent for macOS guests inside it.
#   scripts/build.sh                    optimized, at build/SwiftVM.app
#   scripts/build.sh debug              the same app, not optimized
#   scripts/build.sh --output <app>     somewhere else, e.g. while SwiftVM is running from build/
#
# This is the app with your machines in it. For a copy to try changes in, with machines of its own,
# use `swift run SwiftVM`. How the app is signed is described in scripts/bundle-app.sh.
#
# The QEMU that runs Windows guests and Linux guests with graphics acceleration is built too, by
# scripts/build-qemu.sh, which says what it needs. SWIFTVM_QEMU=- builds the app without it.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"

configuration=release
app=$root/build/SwiftVM.app
while (( $# )); do
    case ${1:l} in
        debug | release) configuration=${1:l}; shift ;;
        --output) app=${${2:?}:a}; shift 2 ;;
        *) fail "Usage: scripts/build.sh [debug] [--output <app>]" ;;
    esac
done
# A relative path would be one file here and another once this script has moved to the repository.
if [[ ${SWIFTVM_PROVISIONING_PROFILE:--} != - ]]; then
    export SWIFTVM_PROVISIONING_PROFILE=${SWIFTVM_PROVISIONING_PROFILE:a}
fi
cd "$root"
# Said now rather than after minutes of building.
check_replaceable "$app"

swift build -c $configuration --product SwiftVM
swift build -c $configuration --package-path Packages/SwiftVMKit --product swiftvm
swift build -c $configuration --package-path Packages/SwiftVMKit --product swiftvm-agent
qemu=()
if [[ ${SWIFTVM_QEMU:-} != - ]]; then
    qemu_folder=$("$root/scripts/build-qemu.sh")
    qemu=(--qemu "$qemu_folder")
fi
"$root/scripts/bundle-app.sh" --output "$app" $qemu \
    --products "$(swift build -c $configuration --show-bin-path)" \
    --helpers "$(swift build -c $configuration --package-path Packages/SwiftVMKit --show-bin-path)" > /dev/null

print "App: $app"
print "CLI: $app/Contents/Helpers/swiftvm"
