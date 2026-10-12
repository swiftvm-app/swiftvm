#!/bin/sh
# Runs the setup scripts of a virtual machine that SwiftVM made: the ones that were picked when the
# machine was created, a desktop for example. SwiftVM puts this file and the scripts into a new
# machine, and swiftvm-setup.service runs it once the system is up for the first time.
#
#   The scripts       /usr/local/lib/swiftvm/setup/scripts, by their number: 1, 2, ...
#   What they print   /var/log/swiftvm-setup.log
#   How it went       /var/lib/swiftvm/setup/status
#
# They run one after the other. When one fails, those after it aren't run.
# To carry on after a failure:  sudo systemctl start swiftvm-setup
#
# A setup that is cut short, by the machine being turned off, carries on the next time the system
# starts: the scripts that came to their end stay done, and the one that was cut short is run again
# from its beginning. One that keeps being cut short is given up on.
set -u

home=${SWIFTVM_SETUP_HOME:-/usr/local/lib/swiftvm/setup}
state=${SWIFTVM_SETUP_STATE:-/var/lib/swiftvm/setup}
log=${SWIFTVM_SETUP_LOG:-/var/log/swiftvm-setup.log}
unit=swiftvm-setup.service
# How often a script is started without ever coming to an end, before that is taken for an answer.
attempts_allowed=3

# What SwiftVM knows about the scripts and the machine, one "key=value" to a line: what all of the
# scripts set up, whether any of them wants a restart, and the account. The lines are taken as they
# are and never run, whatever is in them.
name='' restart=no user=''
if [ -r "$home/settings" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case $key in
            name) name=$value ;;
            restart) restart=$value ;;
            user) user=$value ;;
        esac
    done < "$home/settings"
fi

# Says how the setup is doing and what is being set up, for the guest agent to pass on to the app.
# The file is swapped in whole, so that it is never read half written.
write_status() {
    printf 'state=%s\nname=%s\n' "$1" "$2" > "$state/status.new" && mv -f "$state/status.new" "$state/status"
}

if [ "${1:-}" = "--schedule" ]; then
    # Asked for by the machine's first-boot setup. A copy of a machine goes through that once more,
    # on a disk where all of this has happened: there is nothing to set up a second time.
    [ ! -e "$state/status" ] || exit 0
    mkdir -p "$state"
    write_status pending "$name"
    systemctl daemon-reload
    systemctl enable "$unit"
    # Without waiting: the unit starts after the first-boot setup that this is a part of.
    systemctl start --no-block "$unit"
    exit 0
fi

# The scripts are numbered from 1, in the order they run.
total=0
while [ -f "$home/scripts/$((total + 1))" ]; do
    total=$((total + 1))
done
[ "$total" -gt 0 ] || exit 0
mkdir -p "$state/done"
# What a script prints may be for nobody but the administrator.
[ -e "$log" ] || (umask 077 && : > "$log")

say() {
    printf '%s\n' "$*" >> "$log"
}

# The end of a setup, either way: how it went, and what that is said of. The unit is no longer
# started with the system.
finish() {
    write_status "$1" "$2"
    rm -f "$state/attempts"
    systemctl disable "$unit" > /dev/null 2>&1 || true
}

# Until the scripts have come to an end, the unit starts with the system. That is how a run that
# is cut short carries on, also one that was started by hand after a failure.
systemctl enable "$unit" > /dev/null 2>&1 || true

# What a script may count on.
export SWIFTVM_USER="$user"
# Nobody is there to answer a question.
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_SUSPEND=1
[ -n "${HOME:-}" ] || export HOME=/root
# The system's own updates may be at work on a first start. apt waits for them instead of failing.
# A configuration file that was changed on this system is kept when a package brings a new one,
# which dpkg would otherwise stop to ask about.
if [ -z "${APT_CONFIG:-}" ]; then
    printf 'DPkg::Lock::Timeout "900";\nDpkg::Use-Pty "0";\nDPkg::Options { "--force-confdef"; "--force-confold"; };\n' > "$state/apt.conf"
    export APT_CONFIG="$state/apt.conf"
fi

# Runs one script and returns its exit status. Everything it prints is taken down, and the last
# line that starts with "==> " is remembered: that is the step the script says it is at.
run_script() {
    pipe=$state/output
    rm -f "$pipe"
    if ! mkfifo "$pipe"; then
        say "==== Couldn't make $pipe. ===="
        return 1
    fi
    (
        while IFS= read -r line || [ -n "$line" ]; do
            printf '%s\n' "$line"
            case $line in
                "==> "*) printf '%s\n' "${line#==> }" > "$state/step.new" && mv -f "$state/step.new" "$state/step" ;;
            esac
        done < "$pipe" >> "$log"
    ) &
    reader=$!

    chmod u+x "$1" 2> /dev/null
    case $(head -c 2 "$1") in
        '#!') "$1" > "$pipe" 2>&1 < /dev/null ;;
        *) sh "$1" > "$pipe" 2>&1 < /dev/null ;;
    esac
    result=$?

    # The script has come to its end. What it left running may hold on to the pipe for good, so the
    # reader gets a moment for what is still on its way and is then stopped.
    waited=0
    while kill -0 "$reader" 2> /dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    kill "$reader" 2> /dev/null
    wait "$reader" 2> /dev/null
    rm -f "$pipe"
    return "$result"
}

number=0
ran=no
while [ "$number" -lt "$total" ]; do
    number=$((number + 1))
    # It came to its end on an earlier start, before the machine was turned off or a later one failed.
    [ ! -e "$state/done/$number" ] || continue
    script=$home/scripts/$number
    # What this one sets up, as it calls itself, and its place among the others.
    title=''
    if [ -r "$script.name" ]; then
        IFS= read -r title < "$script.name" || true
    fi
    [ -n "$title" ] || title="Script $number"
    [ "$total" -eq 1 ] || title="$title ($number of $total)"

    attempts=0
    if [ -r "$state/attempts" ]; then
        read -r attempts < "$state/attempts" || true
    fi
    case $attempts in
        '' | *[!0-9]*) attempts=0 ;;
    esac
    if [ "$attempts" -ge "$attempts_allowed" ]; then
        say "==== $title was started $attempts times and never came to its end. It isn't started again by itself. ===="
        finish failed "$title"
        exit 1
    fi
    attempts=$((attempts + 1))
    echo "$attempts" > "$state/attempts"

    # A script that was started before and didn't come to a good end, cut short or failed, may have
    # stopped the package manager in the middle of its work, and it takes on nothing new before that
    # is finished. Unlike apt, dpkg doesn't wait for its lock.
    if [ -e "$state/begun" ] && command -v dpkg > /dev/null 2>&1; then
        tries=0
        until dpkg --force-confdef --force-confold --configure -a >> "$log" 2>&1 < /dev/null; do
            tries=$((tries + 1))
            [ "$tries" -lt 18 ] || break
            sleep 10
        done
    fi
    : > "$state/begun"
    # On the disk before the script starts: these notes are for the start after a power cut.
    sync

    ran=yes
    : > "$state/step"
    write_status running "$title"
    say ""
    say "==== $(date '+%Y-%m-%d %H:%M:%S'): $title, attempt $attempts ===="
    run_script "$script"
    status=$?
    if [ "$status" -ne 0 ]; then
        say "==== $title stopped with an error (exit status $status). To run it again: sudo systemctl start swiftvm-setup ===="
        finish failed "$title"
        exit "$status"
    fi
    say "==== $title ran to its end. ===="
    : > "$state/done/$number"
    rm -f "$state/attempts" "$state/begun"
    sync
done

finish finished "$name"
# Started by hand when everything was done already, there is nothing to restart for.
if [ "$restart" = yes ] && [ "$ran" = yes ]; then
    say "==== Restarting. ===="
    sync
    systemctl --no-block reboot
fi
exit 0
