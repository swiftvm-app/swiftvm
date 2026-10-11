# What the scripts in this folder share. To be sourced, not run.

fail() {
    print -u2 -r -- "$1"
    exit 1
}

# Sets `reply` to the process IDs of the copies of the app that are running from the app at $1.
#
# Call it as it is, not inside $( ): when there is no telling, it stops the script. Taking "can't tell"
# for "none" would have an app replaced under a copy that runs.
running_from() {
    local program=${1:A}/Contents/MacOS/SwiftVM listing pid command files
    reply=()
    listing=$(ps -axww -o pid=,comm=) || fail "Couldn't list the running programs, so there is no telling whether ${1:t:r} is running."
    while read -r pid command; do
        [[ ${command:t} == SwiftVM ]] || continue
        # ps names a program the way it was started: by a relative path, or through a link. lsof names
        # the file itself.
        if files=$(lsof -a -p $pid -d txt -Fn 2> /dev/null); then
            if print -r -- "$files" | grep -Fxq -- "n$program"; then
                reply+=($pid)
            fi
        elif kill -0 $pid 2> /dev/null; then
            fail "Couldn't look at process $pid ($command), so there is no telling whether ${1:t:r} is running."
        fi
    done <<< "$listing"
    return 0
}

# Stops the script if a copy of the app is running from the app at $1. Replacing an app under a copy
# that runs takes away what it has yet to read from there, and a copy that is then closed by force takes
# its machines down with it.
refuse_if_running() {
    running_from "$1"
    (( ${#reply} == 0 )) || fail "${1:t:r} is running from $1 (process ${(j:, :)reply}). Quit it first, then try again."
}

# Stops the script unless the app at $1 may be replaced: there is nothing there, or a copy of SwiftVM
# that these scripts made and that isn't running.
check_replaceable() {
    [[ $1 == *.app ]] || fail "$1 has to be an app: a folder whose name ends in .app."
    [[ -e $1 || -L $1 ]] || return 0
    local existing
    existing=$(plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2> /dev/null || true)
    [[ $existing == com.swiftvm.app(|.dev) ]] || fail "$1 isn't a copy of SwiftVM that these scripts made. Move it away first."
    refuse_if_running "$1"
}

# Puts the app at $1 in the place of the one at $2. The old one is moved aside first and deleted once
# the new one is there, so that a failure half-way doesn't leave the place empty.
replace_app() {
    local new=$1 destination=$2 aside=""
    check_replaceable "$destination"
    mkdir -p "${destination:h}"
    if [[ -e $destination || -L $destination ]]; then
        aside=$(mktemp -d "${destination:h}/.replaced.XXXXXX")
        mv "$destination" "$aside/"
    fi
    if ! mv "$new" "$destination"; then
        if [[ -n $aside ]]; then
            # What is there now is the part of the new app that made it across.
            rm -rf "$destination"
            mv "$aside/${destination:t}" "$destination"
            rmdir "$aside"
        fi
        fail "The new ${destination:t:r} couldn't be put at $destination."
    fi
    if [[ -n $aside ]]; then
        rm -rf "$aside"
    fi
}
