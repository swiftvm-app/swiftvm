#!/bin/zsh
# Runs a development copy of the app: "SwiftVM Dev", an app of its own to macOS, which keeps its
# machines in a folder of its own in Application Support and never sees the app's. `swift run SwiftVM`
# ends up here too, once it has built the app's program.
#   scripts/run-dev.sh [--background] [arguments for the app]
#
#   --background   open the copy behind the other windows and return as soon as it answers the
#                  swiftvm tool, instead of staying with it
#   --products     the folder with a program that is built already; `swift run SwiftVM` passes it
#
# Without --background the script stays until the copy quits, and shows what it prints. Control-C asks
# the copy to quit the way `swiftvm quit` does, which it refuses while a machine is running; a second
# Control-C leaves it running.
#
# The copy is at ".build/SwiftVM Dev.app", with its swiftvm tool in Contents/Helpers. A copy that is
# still running from there is asked to quit once the new one is ready to take its place. SWIFTVM_HOME
# gives the copy another data directory; for SWIFTVM_SIGN_IDENTITY see scripts/bundle-app.sh. The QEMU
# that runs Windows guests is built the first time, by scripts/build-qemu.sh; SWIFTVM_QEMU=- leaves it out.
set -euo pipefail
root=${0:A:h:h}
source "$root/scripts/common.sh"
# A relative path would be one folder to this script and another to the copy, which doesn't start here.
if [[ -n ${SWIFTVM_HOME:-} ]]; then
    export SWIFTVM_HOME=${SWIFTVM_HOME:a}
fi
# The same for a profile that is named, once this script has moved to the repository.
if [[ ${SWIFTVM_PROVISIONING_PROFILE:--} != - ]]; then
    export SWIFTVM_PROVISIONING_PROFILE=${SWIFTVM_PROVISIONING_PROFILE:a}
fi
cd "$root"

products="" background=false
while (( $# )); do
    case $1 in
        --products) products=${2:?}; shift 2 ;;
        --background) background=true; shift ;;
        *) break ;;
    esac
done

if [[ -z $products ]]; then
    swift build --product SwiftVM
    products=$(swift build --show-bin-path)
fi
swift build --quiet --package-path Packages/SwiftVMKit --product swiftvm
swift build --quiet --package-path Packages/SwiftVMKit --product swiftvm-agent
helpers=$(swift build --package-path Packages/SwiftVMKit --show-bin-path)
qemu=()
if [[ ${SWIFTVM_QEMU:-} != - ]]; then
    qemu_folder=$("$root/scripts/build-qemu.sh")
    qemu=(--qemu "$qemu_folder")
fi

app="$root/.build/SwiftVM Dev.app"
tool=$app/Contents/Helpers/swiftvm

# The new copy is put together before the old one is asked to leave. If that fails, over a certificate
# that has run out for one, the copy that is open stays open.
staged="$root/.build/staged/${app:t}"
"$root/scripts/bundle-app.sh" --products "$products" --helpers "$helpers" --output "$staged" --development $qemu > /dev/null

running_from "$app"
if (( ${#reply} )); then
    print "Asking the SwiftVM Dev that is running to quit…"
    # It says why if it won't.
    "$tool" quit || fail "SwiftVM Dev is running and didn't quit, so the new build can't take its place. If it has machines running or being created, see to those first. If it was started with another SWIFTVM_HOME than this command, quit it from its menu."
    for attempt in {1..100}; do
        running_from "$app"
        (( ${#reply} )) || break
        sleep 0.2
    done
fi
replace_app "$staged" "$app"

# The development copy of another checkout keeps its data in the same place, and so does any copy that
# was given the same SWIFTVM_HOME. Two copies on one set of machines undo each other's work.
if "$tool" list > /dev/null 2>&1; then
    fail "Another copy of SwiftVM is already running with the machines this one would use. Quit that one first."
fi

# What the copy prints. Launch Services starts it, so it doesn't have this terminal by itself.
output=$root/.build/swiftvm-dev.out.log
errors=$root/.build/swiftvm-dev.err.log
: > "$output"
: > "$errors"
opener=(/usr/bin/open -n --stdout "$output" --stderr "$errors")
if [[ -n ${SWIFTVM_HOME:-} ]]; then
    opener+=(--env "SWIFTVM_HOME=$SWIFTVM_HOME")
fi

if $background; then
    "${opener[@]}" -g "$app" --args "$@"
    for attempt in {1..150}; do
        if "$tool" list > /dev/null 2>&1; then
            exit 0
        fi
        sleep 0.2
    done
    fail "SwiftVM Dev was opened but doesn't answer its swiftvm tool. What it printed is in $errors."
fi

# Control-C reaches every program this terminal is running. Only this script is to act on it, so the
# others are told to ignore it.
(trap '' INT; exec "${opener[@]}" -W "$app" --args "$@") &
waiter=$!
(trap '' INT; exec tail -n +1 -f "$output") &
followers=($!)
(trap '' INT; exec tail -n +1 -f "$errors" >&2) &
followers+=($!)

leave() {
    # The last lines the copy printed are still on their way.
    sleep 0.3
    kill $followers $waiter 2> /dev/null || true
    exit $1
}

interruptions=0
interrupted() {
    (( interruptions += 1 ))
    if (( interruptions > 1 )); then
        print -u2 "\nSwiftVM Dev keeps running. \"$tool\" quit ends it."
        leave 130
    fi
    print -u2 "\nAsking SwiftVM Dev to quit…"
    "$tool" quit || print -u2 "Control-C again leaves it running."
}
trap interrupted INT
trap 'leave 143' TERM HUP

print "Opening SwiftVM Dev. Control-C asks it to quit. Its command-line tool: \"$tool\""
opened=0
while kill -0 $waiter 2> /dev/null; do
    # Without a redirection: it would also swallow what is said when Control-C arrives during the wait.
    wait $waiter && opened=0 || opened=$?
done
# A wait that Control-C cut short says nothing about how opening went.
if (( interruptions )); then
    opened=0
fi
leave $opened
