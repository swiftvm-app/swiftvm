#!/bin/sh
# The system manager, not the agent being replaced, owns the installer.
set -eu
umask 077
d=/run/swiftvm-reinstall-@@token@@
mkdir "$d"
mkdir "$d/disc"
# udev may still be naming the newly attached device.
tries=0
while [ ! -e /dev/disk/by-label/SWIFTVM ] && [ "$tries" -lt 50 ]; do
    sleep 0.2
    tries=$((tries + 1))
done
mount -o ro /dev/disk/by-label/SWIFTVM "$d/disc"
trap 'umount "$d/disc" 2>/dev/null || true' EXIT
cp "$d/disc/install.sh" "$d/install.sh"
umount "$d/disc"
trap - EXIT
cat > "$d/run.sh" <<'SWIFTVM_RUNNER'
#!/bin/sh
cd /run/swiftvm-reinstall-@@token@@ || exit 1
# A timed-out host may try again while its detached installer still runs.
if flock -n /run/swiftvm-reinstall.lock /bin/sh ./install.sh > install.log 2>&1; then
    echo ok > status.new
else
    printf 'failed: ' > status.new
    tail -c 2000 install.log >> status.new
fi
mv status.new status
SWIFTVM_RUNNER
systemd-run --quiet --collect --unit=swiftvm-reinstall-@@token@@ --property=RuntimeMaxSec=150 /bin/sh "$d/run.sh"
