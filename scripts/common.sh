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

# The entitlement that lets the app hand USB devices to its guests. macOS honours it only in an app that
# carries a provisioning profile which grants it to that app; an app that claims it without one is
# ended the moment it starts.
usb_entitlement=com.apple.developer.accessory-access.usb

# Where provisioning profiles are kept on a Mac: the ones Xcode makes and the ones that were opened.
profile_folders=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
)

# Prints the identifier by which a development profile lists this Mac among the Macs it is good for.
provisioning_udid() {
    system_profiler SPHardwareDataType 2> /dev/null | awk -F': ' '/Provisioning UDID/ { print $2; exit }'
}

# Writes what the provisioning profile at $1 says to $2, as a property list. A profile is that list in
# a signed envelope.
decode_profile() {
    security cms -D -i "$1" -o "$2" 2> /dev/null
}

# Prints why the decoded profile at $1 doesn't let the app with the bundle identifier $2, signed with the
# certificate whose SHA-1 is $3, take USB devices on this Mac. Prints nothing when it does.
profile_problem() {
    local decoded=$1 identifier=$2 certificate=${3:u}
    local name application expiry count index devices
    name=$(/usr/libexec/PlistBuddy -c "Print :Name" "$decoded" 2> /dev/null || true)
    name="“${name:-without a name}”"

    # The app's identifier with the team's in front.
    application=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2> /dev/null || true)
    if [[ ${application#*.} != $identifier ]]; then
        print -r -- "$name is for another app"
        return 0
    fi
    if [[ $(/usr/libexec/PlistBuddy -c "Print :Entitlements:$usb_entitlement" "$decoded" 2> /dev/null || true) != true ]]; then
        print -r -- "$name doesn't grant $usb_entitlement"
        return 0
    fi
    # Both are written the same way, so that the later one sorts last.
    expiry=$(plutil -extract ExpirationDate raw -o - "$decoded" 2> /dev/null || true)
    if [[ -z $expiry || ! $expiry > $(date -u +%Y-%m-%dT%H:%M:%SZ) ]]; then
        print -r -- "$name ran out${expiry:+ on ${expiry%%T*}}"
        return 0
    fi
    count=$(plutil -extract DeveloperCertificates raw -o - "$decoded" 2> /dev/null || true)
    for (( index = 0; index < ${count:-0}; index++ )); do
        if [[ $(plutil -extract DeveloperCertificates.$index raw -o - "$decoded" | base64 -d | shasum -a 1 | awk '{ print toupper($1) }') == $certificate ]]; then
            break
        fi
    done
    if (( index >= ${count:-0} )); then
        print -r -- "$name is for another signing certificate than this one"
        return 0
    fi
    # A profile for distribution is good on any Mac. One for development lists its Macs.
    if [[ $(plutil -extract ProvisionsAllDevices raw -o - "$decoded" 2> /dev/null || true) != true ]]; then
        devices=$(plutil -extract ProvisionedDevices xml1 -o - "$decoded" 2> /dev/null || true)
        if ! print -r -- "$devices" | grep -Fq -- "<string>$(provisioning_udid)</string>"; then
            print -r -- "$name isn't for this Mac"
            return 0
        fi
    fi
}

# Sets `reply` to the provisioning profile that lets the app with the bundle identifier $1, signed with
# the certificate whose SHA-1 is $2, take USB devices: among the profiles in the folders that follow,
# the one that lasts longest. Leaves `reply` empty when none does, and then `REPLY` says what is wrong
# with a profile that was made for this app, if there is one.
find_usb_profile() {
    local identifier=$1 certificate=$2
    shift 2
    local scratch folder candidate problem expiry best="" best_expiry=""
    reply=()
    REPLY=""
    scratch=$(mktemp -d)
    {
        for folder in "$@"; do
            for candidate in "$folder"/*.(provisionprofile|mobileprovision)(N); do
                # A developer's Mac holds profiles for every app they work on. The list inside the
                # envelope is readable as it is, which tells the few for this app without opening them all.
                grep -q -a -F -- ".$identifier</string>" "$candidate" || continue
                decode_profile "$candidate" "$scratch/profile.plist" || continue
                problem=$(profile_problem "$scratch/profile.plist" "$identifier" "$certificate")
                if [[ -n $problem ]]; then
                    # A profile for an app whose identifier only ends like this one's is nobody's problem.
                    [[ $problem == *"is for another app" ]] || REPLY=$problem
                    continue
                fi
                expiry=$(plutil -extract ExpirationDate raw -o - "$scratch/profile.plist" 2> /dev/null || true)
                if [[ $expiry > $best_expiry ]]; then
                    best=$candidate
                    best_expiry=$expiry
                fi
            done
        done
    } always {
        # Also when the script is stopped half-way: what a profile says isn't left lying about.
        rm -rf "$scratch"
    }
    if [[ -n $best ]]; then
        reply=("$best")
        REPLY=""
    fi
    return 0
}

# Whether $1 is a version a release can have: 1.2.3, or 1.2.3-beta.45 for a beta.
is_release_version() {
    [[ $1 =~ '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' ]]
}
