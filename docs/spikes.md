# Spike results

Findings from the de-risking experiments in the plan. Each entry says what was tried, on what, and the outcome.

## vmnet networks without root — works

- **Tried:** `vmnet_network_configuration_create(.VMNET_SHARED_MODE)` with a fixed /24, one DHCP reservation and
  one TCP port forward, then `vmnet_network_create` and `VZVmnetNetworkDeviceAttachment(network:)`, from a
  command-line binary.
- **Host:** macOS 27.0 (26A428), not root.
- **Outcome:** Succeeds when the binary is signed (ad-hoc is enough) with `com.apple.security.virtualization`.
  Without that entitlement `vmnet_network_create` fails with status 1002. `com.apple.vm.networking` is not needed.
- **Also learned:** A second network on the same subnet fails (status 1001) while the first exists, and works
  again once the first is released. Reservations and forwards can only be set before the network is created,
  so the app creates the network when the first machine starts and drops it when the last one stops.

## vmnet subnet address must be the host address — found the hard way

- **Symptom:** A guest attached to a network with an explicit subnet lost its interface a few seconds after boot:
  `VZErrorDomain Code=1 "Internal Network Error."` via `networkDevice:attachmentWasDisconnectedWithError:`.
  No bridge interface appeared on the host.
- **Cause:** `vmnet_network_configuration_set_ipv4_subnet` was given the network address (`192.168.230.0`).
  It has to be the host's address (`192.168.230.1`); `vmnet_network_get_ipv4_subnet` on a default network
  returns `192.168.64.1` the same way.
- **Checked with:** a minimal command-line VM booting the Ubuntu 26.04 cloud image. With `.0` the attachment
  drops in both shared and host mode; with `.1` the host gets `192.168.233.1` and the guest answers ping on
  its reserved address `192.168.233.10`.

## DHCP reservations only last for the first use of a network object

- **Tried:** One network with a reservation; boot a VM, stop it, boot another VM with the same MAC on the
  *same* network object.
- **Outcome:** Run 1 gets the reserved address. In run 2 the same MAC is handed a dynamic address: once the
  last interface leaves, the host rebuilds its DHCP setup without the reservations.
- **Consequence:** `NetworkManager` releases the network when the last machine detaches and creates a fresh
  one for the next start.

## A network is only released when every attachment to it is gone

- **Symptom:** Re-creating the network right after a machine stopped failed with status 1001, and the app
  hopped to another subnet.
- **Cause:** `VZVmnetNetworkDeviceAttachment` objects still referenced the old network: from the stopped
  `VZVirtualMachine`'s devices and from the `VZVirtualMachineConfiguration` the backend kept.
- **Checked with:** a command-line test. With the attachments still referenced, re-creation kept failing for
  30 s; after setting every `attachment` to `nil` it succeeded on the first try.
- **Consequence:** `VZBackend.invalidate()` clears the attachments when a machine stops, and network creation
  retries for two seconds before moving to another subnet.

## A process that exits with a VM attached leaves its subnet blocked

- **Seen:** After killing the app (or a test tool) while a VM was running, `vmnet_network_create` on that
  subnet kept failing with status 1001 from every process, for at least 20 minutes. Other subnets were fine.
- **Consequence:** The app shuts machines down on quit. If the subnet is unavailable anyway, it moves to the
  next free one and re-maps the reserved addresses, so machines still start.

## Linux guests must identify by MAC for reservations to match

- **Symptom:** An Ubuntu 26.04 cloud guest got a dynamic address instead of its reserved one.
- **Cause:** systemd-networkd sends a generated DHCP client identifier, so the host's lease is keyed by that
  identifier (`hw_address=ff,…` in `/var/db/dhcpd_leases`) and the MAC-based reservation never matches.
- **Fix:** The cloud-init network config sets `dhcp-identifier: mac`. A machine created after the fix came up
  on its reserved address (`192.168.232.11`) with no dynamic lease recorded.
- **Fallback:** For guests that still don't match, the app collects candidate addresses (leases by MAC or
  host name, plus the reservation) and uses the one that accepts a connection on the SSH port.

## macOS guests install and set themselves up unattended — works

- **Tried:** `swiftvm create macos`, twice, with the 27.0.1 restore image (26A434; 26.6 GB, which the app
  shows as 24.81 GB because it counts in binary units) already downloaded:
  `VZMacOSInstaller` onto a blank 128 GB ASIF disk, then a first start with
  `VZMacGuestProvisioningOptions` (account, automatic login, Remote Login).
- **Host:** macOS 27.0 (26A428), M5 Pro.
- **Outcome:** Creating the machine took 3 min 0 s and 2 min 44 s, nearly all of it the installation. On
  the first start the guest creates the account and logs in by itself; key sign-in over SSH worked 26 s
  and 32 s after the start. A later start answered after 7 s. Both guests took their reserved address
  without help (macOS identifies itself to DHCP by MAC address).
- **Also learned:**
  - In Swift the setter is `VZMacOSVirtualMachineStartOptions.setGuestProvisioning(_:)`; the Objective-C
    name `setGuestProvisioningOptions:` doesn't compile.
  - `VZMacGuestProvisioningOptions.validate()` works on its own, so an account can be checked before the
    installation rather than at the first start, when it is too late to change it.
  - The installer reports no progress for the first 30 s or so (it stays at 0), then moves steadily.
  - Suspending a macOS guest takes about 2 s and resuming about 3 s; the saved state of an 8 GB guest that
    has just started is 2.8 GB.
  - Shared folders show up at `/Volumes/My Shared Files/<name>` as soon as they are added, in both directions.

## Remote Login comes up with password sign-in only

- **Seen:** Provisioning with `enablesRemoteLogin` turns on SSH, but there is no way to hand over a public key.
- **Fix:** Once the guest answers on port 22 the app signs in once with the password and appends the key to
  `~/.ssh/authorized_keys`. `ssh` gets the password from a helper named in `SSH_ASKPASS` (with
  `SSH_ASKPASS_REQUIRE=force`, because the app has no terminal); the helper prints an environment variable,
  so the password is never written to disk or put on a command line. Checked with a password containing a
  space, a double quote and a dollar sign.

## An unattended macOS guest stays on Pacific time

- **Seen:** `readlink /etc/localtime` in a freshly provisioned guest gives `US/Pacific`, whatever the host
  uses: nobody was asked, and location services are off.
- **Fix:** After installing the key the app runs `sudo -S systemsetup -settimezone <host zone>` over SSH,
  with the password on standard input. `systemsetup` prints an `Error:-99` line and still succeeds; the
  symlink changes a moment later. A guest created after the fix came up on `Europe/Berlin`.

## macOS guests ask before they shut down

- **Symptom:** `swiftvm stop` on a macOS guest timed out and the machine stayed in "Shutting Down" for good.
- **Cause:** `VZVirtualMachine.requestStop()` acts like the power button. With a user logged in, macOS puts
  up its shutdown confirmation and waits; the guest was still up 105 s later. Listing on-screen windows in
  the guest shows no `loginwindow` window before the request and one (267×334 points, layer 1000) after it.
- **Consequence:** A shutdown request now expires after 60 s and the machine counts as running again. For
  macOS guests the app brings the machine's window forward so the question is seen, and `swiftvm stop`
  explains what happened. Shutting down without anyone at the screen needs root in the guest
  (`shutdown -h now`), so it is a job for the guest agent or a `sudoers` rule installed during setup.
- **Note:** A guest that shuts itself down is noticed right away (`guestDidStop`).

## Cancelling a macOS installation

- **Tried:** A signed command-line harness that starts `MacOSInstaller.install` and cancels the task before
  the installation starts, 12 s in and 50 s in.
- **Outcome:** No crash in any of the three. Cancelling `VZMacOSInstaller.progress` after the installation
  has started ends it within milliseconds with `VZErrorDomain` code 9 ("The installation was cancelled").
  The header warns that cancelling *before* it has started raises an exception, so an early cancellation
  is only remembered and the installation is never started.

## Interrupted downloads can be picked up again

- **Tried:** A local HTTP server that promises a 6 MB file, sends 2 MB and hangs up; later requests are
  answered in full and honor `Range`.
- **Outcome:** `URLSession` fails the download task with resume data in the error
  (`URLError.downloadTaskResumeData`), and a task made from that data asks for the remainder only
  (`Range: bytes=…`). The server has to send `Accept-Ranges: bytes` and an `ETag` (Apple's CDN does both for
  restore images). The stitched file matches the original.
- **Consequence:** `ImageDownloader` carries on after a dropped connection instead of starting a 25 GB
  download over. The same data also carries a download across a quit: see "Resume data outlives the
  process that got it" below.

## Disc and disk images can be plugged in while a guest runs — works

- **Tried:** `swiftvm attach` and `swiftvm eject` on running Ubuntu 26.04 and macOS 27.0.1 guests:
  `VZUSBMassStorageDevice(configuration:)` handed to `VZUSBController.attach(device:)`, and `detach(device:)`
  for the drive with the matching `uuid`. A 900 KB ISO (read-only) and a 64 MB raw image (writable).
- **Outcome:** The drive shows up within a second or two: `sda`/`sdb` with `TRAN usb` in Linux, an external
  disk that macOS mounts under `/Volumes` by itself. Writing a file system to the raw image, ejecting it and
  attaching it again at the next boot gives the file back.
- **Suspend:** A guest suspended with drives plugged in resumes with them, mounted file system included, as
  long as the configuration it is restored with lists the same drives with the same `uuid`
  (`VZUSBDeviceConfiguration.uuid` is generated otherwise). The app uses the image's own identifier for it.
  A drive that was ejected before suspending must not be in that configuration, and wasn't: both ways resume.
- **Consequence:** Drives can change while a machine is running or shut down, but not while it is
  suspended, because the saved memory expects the drives it was saved with.
- **Also learned:** A drive configured on the USB controller (`VZXHCIControllerConfiguration.usbDevices`)
  rather than among the storage devices still boots: a machine with the Ubuntu desktop ISO attached that way
  came up in the live session.

## Snapshots are copies of the disk, not layers on top of it

- **Considered:** DiskImageKit overlay layers (`.asifLayer(url:type: .overlay)`). They can only be stacked
  and dropped from the top: there is no call to merge a layer into the one below, so deleting an old
  snapshot could neither free its space nor shorten the stack, and every layer costs a lookup on each read.
  They also only apply to ASIF disks, and Quick Create machines have raw ones.
- **Tried instead:** Copying the disk, the firmware variables or auxiliary storage, and the saved memory with
  `FileManager.copyItem`, which clones on APFS.
- **Outcome:** A 31 GB macOS bundle was duplicated in 24 ms, a 26 GB Linux disk in under 0.2 s. Going back to
  a snapshot took 0.1 s (Linux) and 0.16 s (macOS). Disks of either format work, and a snapshot can be
  deleted without touching the others.
- **A running guest** is suspended, copied and resumed: 0.85 s in all for a 2 GB Ubuntu guest, 4.6 s for an
  8 GB macOS guest. That detour is deliberate. Copying the image of a paused guest would be faster, but the
  disk image is only known to be complete on the host once the machine has let go of it, and a snapshot
  whose memory and disk disagree corrupts the guest. Reverting brings back the same processes (a `sleep`
  started before the snapshot was still running under the same PID) and the same plugged-in drives.
- **Cost:** A snapshot of a running guest keeps the saved memory (302 MB for the idle 2 GB Ubuntu guest,
  2.6 GB for the 8 GB macOS guest). On a volume that isn't APFS every copy is a full copy.

## A copy of a Mac starts with a new machine identifier — works

- **Tried:** Duplicating a shut-down macOS 27.0.1 machine: clone the disk and the auxiliary storage, keep the
  hardware model, write a new `VZMacMachineIdentifier`, new MAC address.
- **Outcome:** The copy booted and answered SSH in 13 s while the original was running next to it. The two
  report different serial numbers, and the copy renamed itself with a "(2)" when it found the original on
  the network.
- **Linux copies** need more than a new MAC address when cloud-init set them up: the network configuration
  it wrote matches the old MAC, so the copy would come up without a network. The copy's seed image gets a
  new instance ID, host name and MAC address, which makes cloud-init treat the next start as a first boot.
  A copy made that way came up with its own host name, reserved address and SSH host keys.

## A macOS guest can't grow its startup volume

- **Tried:** Growing the ASIF disk of a shut-down macOS guest from 64 to 80 GB with
  `DiskImage.truncate(blockCount:)`, then `diskutil apfs resizeContainer disk1s2 0` in the guest.
- **Outcome:** The guest boots and sees the larger disk, with the new space at the end. The container
  can't take it (error -69519): the recovery container (`Apple_APFS_Recovery`, 5.4 GB) sits between them.
  Removing that is refused while System Integrity Protection is on.
- **What works:** `diskutil addPartition disk1s3 APFS <name> 0` (or Disk Utility) turns the new space into a
  second volume.
- **Linux guests set up from a cloud image** grow their root file system by themselves at the next start
  (16 GB to 24 GB: `/dev/vda1` went from 15G to 23G).
- **Consequence:** Resizing says per guest what happens next, and the default macOS disk stays generous
  (128 GB, sparse).

## vmnet can forward ports, but only decides once

- **Tried:** `vmnet_network_configuration_add_port_forwarding_rule` for TCP 2222 → 22 and 8088 → 8000 of a
  guest with a reserved address.
- **Outcome:** Both work, from `127.0.0.1` and from the host's LAN address (so other devices can get in as
  well), though not from the bridge address. No listening socket shows up in `lsof` or `netstat`. The guest
  sees the connections coming from the host's address on the virtual network.
- **Problem:** Like reservations, the rules are fixed when the network is created, and the network only goes
  away when the last machine stops. Adding a forward to one machine would mean shutting down all of them.
- **Consequence:** Forwarded ports are relayed by the app (`PortRelay`, on Network.framework): they open and
  close while the machine runs, listen on the loopback interface only unless asked otherwise, and a port
  that is taken is retried. A 512 MB download through a relay arrived intact at 3.9 GB/s (7.5 GB/s direct).

## A finished connection reports failure before its last bytes

- **Symptom:** Large transfers through the relay sometimes lost their last 3 to 400 KB.
- **Cause:** When one side has sent everything and the other then closes, `NWConnection` moves to
  `.failed(ENETDOWN)` while received data is still waiting to be read. The relay treated that state as the
  end and dropped the rest.
- **Fix:** Once a connection has been ready, its state is ignored. The end of a conversation is found by
  reading until the receive call says complete or fails.

## A resumed guest thinks no time has passed

- **Seen:** After 25 s suspended, an Ubuntu guest's clock was 24 s behind; after 30 s a macOS guest's was
  33 s behind. A guest that goes back to a snapshot is behind by the snapshot's age.
- **macOS** puts this right by itself: 5 s after resuming the difference was gone.
- **Ubuntu** (chrony) only nudges the clock, which for a large difference takes a very long time. The
  guest's hardware clock is the host's clock, though, so `sudo hwclock --hctosys` fixes it at once.
- **Consequence:** After resuming a Linux guest the app runs that over SSH where it can (key sign-in and
  `sudo` without a password, as in guests it set up). The difference was gone within 2 s of resuming.

## What Linux puts on the serial port

- **Seen:** Ubuntu 26.04 starts a login prompt on `/dev/hvc0`, the port behind
  `VZVirtioConsoleDeviceSerialPortConfiguration`, without being asked (systemd does that for the first
  hypervisor console). Kernel messages don't go there by themselves: the cloud image boots with
  `console=tty1 console=ttyAMA0`. Quick Create machines are now set up to send them: see "Kernel messages
  on the serial console" below.
- **Why the log looked empty:** It was started over at every start, and a guest that is resumed prints
  nothing new. The login prompt of a cold boot was always there.
- **Now:** The port is attached to pipes (`VZFileHandleSerialPortAttachment`) instead of a file, so it can be
  typed into: `swiftvm console <machine>` logs in on `hvc0`. The terminal's size is picked up through the
  escape-sequence query systemd sends, which is also why the recent output isn't replayed to a terminal
  that connects later: it would answer queries nobody is waiting for any more.
- **Also seen:** The login banner says `Try contacting this VM's SSH server via 'ssh vsock%3' from host`.
  systemd already makes sshd listen on the vsock device, which is what SSH without a network (planned for
  the guest tools phase) needs.

## A terminal view inside the app — put off

- **Considered:** SwiftTerm for a serial console window.
- **Found:** Its 1.99.0 release of 8 October 2026 is a preview of 2.0 with changed APIs, and the package
  now brings build-tool plug-ins (which `xcodebuild` won't run without a flag or a click in Xcode) and a
  dependency of its own.
- **Consequence:** For now the console opens in the user's terminal app through the `swiftvm` tool, which is
  therefore built into the app (`Contents/Helpers/swiftvm`). Worth another look when SwiftTerm 2.0 is out.

## A shutdown request during startup is lost

- **Seen:** `swiftvm stop` three seconds after `swiftvm start` on an Ubuntu guest gave up after 90 s with the
  guest still up. The request is the virtual power button, and nothing in the guest listens for it until
  the system is far enough along.
- **Fix:** While a machine is shutting down the request is repeated every 5 s. A system that is already
  shutting down ignores the extra presses. The same stop now takes 8.5 s.
- **Not for macOS guests:** they answer the first press with a confirmation on their screen. What further
  presses would do to it wasn't tried, so they are asked once.

## A suspended guest can't be resumed while the Mac is locked

- **Symptom:** Resuming suddenly failed for every guest, Linux and macOS: `VZErrorDomain`, "The virtual
  machine failed to restore with error “permission denied”". Suspending still worked and wrote its file.
- **Cause:** The Mac's screen had locked two minutes earlier (`CGSSessionScreenIsLocked` in
  `CGSessionCopyCurrentDictionary()`; nobody had touched the Mac for a while). The saved memory can't be
  read back while the session is locked.
- **Checked with:** The last committed build, in a data folder of its own: a new Ubuntu guest, suspended and
  resumed, failed the same way while the screen was locked. With the screen unlocked, that build and
  the current one had both resumed guests earlier in the day. So it isn't something this code does.
- **After unlocking:** Guests suspended and resumed again as before, in the same build. Whether memory
  that was saved *while* the Mac was locked resumes after unlocking wasn't seen: those files were gone by
  then.
- **Consequence:**
  - A failed resume on a locked Mac says so, and doesn't suggest discarding the saved state.
  - A snapshot of a *running* guest is refused while the Mac is locked: the guest would be suspended for
    it and then stay down until someone unlocks. Snapshots of machines that are shut down or already
    suspended don't need a resume and still work.
  - `swiftvm suspend` works either way.

## The disk copy of a live snapshot holds up under load

- **Question:** A live snapshot copies the disk image right after the machine is stopped. For ASIF, is
  everything the guest wrote in the file by then, or could the framework still be holding some of it?
- **Tried:** A macOS guest writing 48 MB files in a loop (random data, a checksum file after each, `sync`),
  snapshotted in the middle of that through the normal path. Later the machine was put back on the
  snapshot's disk and booted from it cold, as after a power cut at that moment.
- **Outcome:** 24 rounds on record, all six data files matched their checksum files, a 200 MB file written
  before the load matched its checksum, and `diskutil verifyVolume` passed for the data and system volumes.
- **With its memory:** The first run couldn't resume the snapshot, because the Mac was locked by then (see
  above). Run again on an unlocked Mac: the snapshot took 5 s with the loop writing, and after going back
  to it and resuming, the loop carried on from the round it had been in. Stopped a few rounds later, all
  six files matched their checksums and the data volume verified.

## What a snapshot leaves out, and the order things go back in

- **A drive the guest can write to** is an image file outside the machine, and it keeps changing after a
  snapshot. A guest brought back with its memory would still have that drive mounted as it was and write
  old bookkeeping over newer contents. So a snapshot that would hold memory is refused while such a drive
  is attached. Read-only images are fine, and so is a snapshot of a machine that is shut down.
- **Going back** first copies the snapshot's files next to the machine's (the guest, if running, is still
  untouched, so a snapshot that turns out to be unusable costs nothing), then stops the guest, removes the
  machine's own saved memory, swaps in disks and firmware with `rename(2)`, and the snapshot's saved
  memory last. If that is cut short, the machine ends up shut down on some disk; it never ends up with
  memory saved next to a disk it doesn't belong to. For the same reason a cold boot deletes saved memory
  it isn't resuming.

## A copy of a cloud-init guest keeps its account as it is

- **Seen coming:** The copy's seed gets a new instance ID so that cloud-init redoes the network and host
  name. Left as it was, the seed would also redo the account: the password and sign-in rules of the day
  the original was created, over whatever they are now.
- **Fix:** The copy's seed has `users: []` and no password sections. The account is on the copied disk.
- **Checked with:** An Ubuntu guest created without a password, given one later with `chpasswd`. Its copy
  had the same password hash, `sudo` without a password, key sign-in, and no extra default account.

## Kernel messages on the serial console

- **Tried:** cloud-init writes `/etc/default/grub.d/99-swiftvm-console.cfg` with
  `GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 console=tty1"` and runs
  `update-grub`, in new Quick Create machines of all three distributions. The first boot is unchanged; the
  second has the new command line.

  | | Kernel | Command line before | Kernel lines in `console.log`, second boot | After a shutdown, the log ends with |
  |---|---|---|---|---|
  | Ubuntu 26.04 | 7.0.0-34 | `console=tty1 console=ttyAMA0` | about 150 | the login prompt |
  | Ubuntu 24.04 | 6.8.0-142 | `console=tty1 console=ttyAMA0` | about 200 | `reboot: Power down` |
  | Debian 13 | 6.12.111 | none | 135 when SSH answers, more as it runs | `systemd-shutdown[1]: Powering off.` and `reboot: Power down` |

- **The display stays the system console.** `tty1` is named again after `hvc0`, and the console named last
  is the one behind `/dev/console`: `/proc/consoles` marks `tty1` with `C` on all three, and
  `/sys/class/tty/console/active` reads `hvc0 tty1`. systemd's status lines and an emergency shell go
  there. Both keep their login prompt, and no unit failed.
- **The log starts when the console does.** Its first line is the one after
  `printk: legacy console [hvc0] enabled`, 0.06 s into the boot on Ubuntu and 0.15 s on Debian. What the
  kernel printed before that is not repeated on `hvc0`.
- **Ubuntu goes quiet on purpose.** It sets `kernel.printk = 4 4 1 7` early in the boot (the log's last
  kernel line is systemd applying the kernel variables, at 0.2 s). From then on only errors and worse reach
  any console: a line written to `/dev/kmsg` at level 0 showed up in the log, one at level 6 didn't. Debian
  leaves the level at 7 and logs everything. That setting is the guest's and is left alone: raising it would
  flood the display as well.
- **Ubuntu 26.04 doesn't say `Power down` on `hvc0`**, although that message is an emergency-level one and
  the two older kernels print it. Not looked into.
- **Copies.** A duplicate's seed is the original's without the account, so it writes the file and runs
  `update-grub` again on its first boot. A copy of an Ubuntu 24.04 machine came up with its own host name,
  the console settings from the copied disk, and no errors from cloud-init.
- **Not covered:** machines created before this, and machines installed from an ISO. Nothing sets them up.

## The last lines before a stop were lost

- **Cause:** `SerialConsole.disconnect` stopped listening to the pipe from the guest and closed the log.
  What the engine had written to the pipe and nobody had read yet was dropped, and so was a chunk that was
  being read at that moment: it went to the listeners but found the log closed.
- **Fix:** The pipe is read without blocking, under the console's lock, both when it has something and
  once more when the guest is unplugged. Whichever gets there first takes what is there, in order.
- **Checked with:** a script in `/usr/lib/systemd/system-shutdown/` of an Ubuntu 26.04 guest that prints
  41 lines to `/dev/hvc0`. systemd runs it as the last thing before it asks the kernel to power off. Five
  shutdowns with `swiftvm stop`: all 41 lines in the log every time, the last one last. On Debian 13 and
  Ubuntu 24.04 the kernel's own last line, `reboot: Power down`, ends the log.
- **Not done:** the same five shutdowns with the build from before the fix. The unit test that writes and
  unplugs 200 times in a row loses lines on the old code and none on the new.

## Resume data outlives the process that got it

- **Tried:** A command-line tool that downloads a 40 MB file from a slow local server, calls
  `cancel(byProducingResumeData:)` after three seconds, writes the data to a file and exits. A second
  process makes a task from that file with `downloadTask(withResumeData:)`.
- **Outcome:** The second process asked for `Range: bytes=10682368-` with `If-Range: "v1"`, and the finished
  file matched. The resume data is a 7.8 KB keyed archive that names a file in the temporary folder
  (`$TMPDIR/CFNetworkDownload_XXXXXX.tmp`), where the bytes received so far stay after the process is gone.
- **Also learned:**
  - The error the cancelled task ends with (`NSURLErrorCancelled`) carries the same resume data as the
    completion handler of `cancel(byProducingResumeData:)`. A plain `cancel()` leaves none.
  - If the temporary file is gone, the task quietly downloads everything again, without a `Range`.
  - Resume data that isn't any fails at once with error -1002, without a request to the server.
  - With nobody listening at the address, a task made from resume data fails with -1004, and that error
    carries resume data again; the temporary file is untouched. A dead network costs nothing.
  - A server that answers the request for the rest with an error costs everything: given a 503,
    URLSession reported the download finished, with the 20 bytes of the error page in the temporary file
    where 10 MB had been. Resuming from the same data afterwards started over. The downloader can only
    notice (the status isn't 2xx) and start from the beginning.
  - macOS clears the temporary folder of files that haven't been used for three days (the
    `com.apple.bsd.dirhelper` job runs daily with `CLEAN_FILES_OLDER_THAN_DAYS=3`). Whether restarting the
    Mac empties it was not tried.
- **Checked for real:** `swiftvm create ubuntu-24.04`, and four seconds later `swiftvm quit
  --cancel-creations`, with 193 MB of 620 MB received. The app left an 8.5 KB
  `ubuntu-24.04-server-cloudimg-arm64.img.resume` in the download cache. After a relaunch the same command
  carried on in the same temporary file, from 193,380,352 bytes to the end, and the image has the SHA-256
  that Ubuntu publishes.
- **Consequence:** `ImageDownloader` cancels with resume data, writes it next to the cache together with the
  address it is for, and tries it first the next time. On its way out the app waits, three seconds at most,
  for downloads to have done that. A cancelled download therefore leaves its bytes in the temporary folder
  until they are used or macOS clears them, also when the user cancelled because they changed their mind.
  Moving the temporary file into the cache as well, so that it would outlive the three days, would mean
  rewriting the name inside an archive whose format isn't documented; left alone.

## A quit that is asked for inside a task can't be answered later

- **Tried:** A window-less AppKit program whose delegate answers `applicationShouldTerminate` with
  `.terminateLater` and replies from a `Task` a moment later, with `NSApp.terminate(nil)` called three ways.
- **Outcome:** Called from a `Task` on the main actor, the app never quits: the reply never runs. Called
  from a `Timer` or from a block handed to the run loop, it quits.
- **Cause:** Tasks on the main actor are run one at a time by the main dispatch queue. `terminate` waits in
  a run loop of its own for the reply, inside the first task, and the queue hands out nothing more until
  that task has returned.
- **Where it mattered:** The app called `terminate` from a task in two places: after waiting for a snapshot
  or a copy to finish before quitting, and for `swiftvm quit`. With a machine running by then, the quit
  dialog would have come up and "Suspend and Quit" would have hung. Not seen in use; found by reading.
- **Consequence:** Both now go through `AppDelegate.terminate(after:)`, which uses a timer. `swiftvm quit`
  also can't meet a running machine any more: once the app has agreed to quit, nothing starts
  (`VMLibrary.allowsStarting`) and further requests are answered with "SwiftVM is quitting." Three rounds
  of `swiftvm quit` followed at once by two `swiftvm start`: both starts refused, the app gone within half
  a second, every machine still shut down.

## ssh waits for good for a guest that has gone

- **Seen:** An `ssh … sudo -n hwclock --hctosys` from an earlier session, 76 minutes old, its parent gone,
  holding an established connection to an address that had since been given to another guest. It is the
  command that sets a Linux guest's clock after a resume; its guest was stopped under it.
- **Tried:** Two `ssh <guest> "sleep 300"` to an Ubuntu guest, then `swiftvm force-stop`. The one with
  `-o ServerAliveInterval=5 -o ServerAliveCountMax=2` ended after 12 s with "Timeout, server not
  responding". The one without was still there.
- **Consequence:** `GuestClock` passes both options. The two commands that finish setting up a macOS guest
  (`SSHKeyInstaller`, `GuestTimeZone`) don't yet.

## A line to the guest that needs no network (virtio-vsock) — works

- **Tried:** `VZVirtioSocketDevice.connect(toPort:)` on the socket device every machine already has, from
  the app, with the descriptor it returns handed to `swiftvm vsock <machine> <port>` through the control
  socket. `ssh` uses that as its `ProxyCommand`.
- **Guests:** Ubuntu 26.04 (systemd 259), Ubuntu 24.04 (systemd 255), Debian 13 (systemd 257).
- **Outcome:** `swiftvm ssh <machine> --vsock` signs in on Ubuntu 26.04 and Debian 13 as they come: systemd
  from version 256 on has a generator that puts the SSH server on port 22 of the socket device
  (`sshd-vsock.socket`). The session's `SSH_CONNECTION` reads `UNKNOWN 65535 UNKNOWN 65535`. With the
  machine's cable pulled, `ssh` to the address times out and the one over the socket device still works.
  512 MB of random data through it arrived with the right checksum in 1.1 s.
- **Ubuntu 24.04** has no such generator, and nothing listens: the connect fails with "Connection reset by
  peer". The guest tools add a socket unit that does the same (`ListenStream=vsock::22`, one `sshd -i` per
  connection), which stands back where systemd's generator exists. With it, 24.04 signs in too.
- **Also learned:**
  - The connection object closes its descriptor when it is released. A `dup` of the descriptor keeps the
    line open after that, so the app holds plain descriptors and no framework objects.
  - A connect to a port nobody listens on fails within 30 ms, also in the first second of a boot, before
    the guest has a driver for the device. Asking again and again is cheap.
  - The descriptor is a socket that can be closed in one direction: a guest program that reads to the end
    of its input and then answers got 300,006 bytes and its answer came back.

## The Linux guest agent is a Python script

- **The choice:** a static Swift binary would share the protocol's code with the app, but needs the Swift
  Static Linux SDK on the Mac, and a toolchain from swift.org next to Xcode's, for everyone who builds the
  app. A script needs nothing on the Mac. The user chose the script.
- **Checked on the three cloud images:** `python3` is there (cloud-init needs it) and its `socket` module
  has `AF_VSOCK`, its `time` module `clock_settime`:

  | | Python | systemd | `hwclock` |
  |---|---|---|---|
  | Ubuntu 26.04 | 3.14.4 | 259 | present |
  | Ubuntu 24.04 | 3.12.3 | 255 | missing |
  | Debian 13 | 3.13.5 | 257 | missing |

- **Hence the clock is set from the Mac's time**, sent in the request, rather than from the guest's
  hardware clock: `hwclock` moved to a package of its own that two of the three images don't have. That
  also means the SSH way of setting the clock (`sudo hwclock --hctosys`) never worked on those two.
- **The agent** listens on port 717 of the socket device and the app connects, which it does afresh
  whenever a guest comes up: connections don't survive a suspend, the agent's listening socket does. The
  agent serves the newest connection and drops the one before.
- **Who may give it orders:** only root can listen below port 1024, so the app knows who answers. In the
  other direction the agent only takes connections that come from the host (peer CID 2). Tried from
  inside a guest: without the `vsock_loopback` module a local connect to port 717 fails; with it loaded
  the connect succeeds, the agent hangs up at once, and the shutdown that was sent with it didn't happen.
  On the Mac, `swiftvm vsock <machine> 717` is refused by the app: the agent serves one connection, and a
  second one would take the app's place. What the agent will do is kept narrow all the same: it mounts
  shared folders under `/mnt` or `/media` only, and a device name can't pass for an option to `mount`.
- **Not covered:** guests without systemd or without Python 3 at `/usr/bin/python3`. The installer says so
  and stops.

## The agent across a machine's life

All through `swiftvm`, on Ubuntu 26.04, Ubuntu 24.04 and Debian 13 unless it says otherwise.

- **First boot of a new Quick Create machine** (the installer arrives through cloud-init): the agent was
  connected 8.5 s, 6.2 s and 6.5 s after the first start, and `swiftvm info` then shows what the guest calls
  itself (`Ubuntu 26.04.1 LTS`, `Ubuntu 24.04.5 LTS`, `Debian GNU/Linux 13 (trixie)`), its kernel and the
  address it holds.
- **A later cold start:** connected after 4.5 to 5.5 s.
- **Existing machines** got it with `swiftvm install-tools` over SSH in 0.6 to 0.7 s each.
- **Resume:** connected again at once. A guest with its cable pulled, so that nothing could reach it over
  SSH, suspended for 30.3 s: the resume took 0.51 s, and its clock, read between 0.02 and 0.23 s after
  that, was between 0.02 s behind and 0.19 s ahead of the Mac's (the spread is the time the reading took).
  The agent's log says `The clock was 31.125 s behind and has been set.` The same on Debian with the
  standard kernel and on Ubuntu 24.04.
- **Pause:** a guest paused for 20 s is 19.6 s behind when it carries on. Ubuntu 24.04's own time service
  put that right within five seconds; with the agent it is right in the first reading (−0.03 to +0.14 s).
- **Snapshot of a running guest:** the agent was back as the guest was (the snapshot took 0.8 s, the clock
  was set by 0.86 s). **Revert** to it 20 s later and start: connected 0.6 s after the start, the file
  changed after the snapshot had its old contents, the clock was set by 21.9 s.
- **Restart:** `swiftvm restart` took 3.5 to 8.6 s, the agent was back about 5 s later, three times of three.
- **Duplicate:** the copy has the agent from the copied disk; connected 5.4 s after its first start, with
  its own address.
- **Shutdown** through the agent took 0.5 to 1.5 s from `swiftvm stop` to stopped, and the console logs
  end with `reboot: Power down` as they do after the power button.
- **A guest SwiftVM didn't set up** (an Ubuntu 24.04 copy with the agent, the shared-folder entry in
  `/etc/fstab` and cloud-init taken out, `sudo` asking for a password): installing over SSH is refused with
  sudo's own words; `swiftvm install-tools --disc` plugs in a 900 KB disc that the guest sees as `sda`
  with the label `SWIFTVM`; the one command printed, run there, installs; the agent connects and mounts
  the shared folders at `/mnt/shared`, where the file put there on the Mac could be read.
- **A guest installed from an ISO** (Ubuntu 26.04.1 desktop, which brings no SSH server): port 22 refuses
  on the network and on the socket device alike, so `swiftvm install-tools` fails with ssh's "Connection
  refused" and points at `--disc`. From the disc, with the command run in the guest's terminal, the tools
  installed; `swiftvm info` then showed them (1.0, kernel 7.0.0-38, `Ubuntu 26.04.1 LTS`) and the shared
  folder was there in the guest.
- **A guest that restarts by itself** (`sudo systemctl reboot` in it) keeps its machine running: the
  framework reports no stop. Its uptime went from 3 s to 8 s with the machine's state unchanged, the
  agent was gone and back, and the shared folders, which nothing mounts in that guest but the agent,
  were mounted again.
- **A guest started with its cable out** is slow to finish starting: Ubuntu 24.04 waits up to two minutes
  for a network before it lets anyone but root sign in ("System is booting up", also over the socket
  device), and a `swiftvm stop` during that wait gave up after 90 s with the guest still going down.
- **A stale journal:** what the guest logs between waking up and the clock being set carries the time of
  the suspend. In the journal a resume therefore looks as if the network took 31 s to come back; it took
  0.3 s.

## Leases on the books are not addresses

- **Seen:** a machine created while another one runs gets a dynamic address, because reservations are
  fixed when the network is made. The lease for it stays in `/var/db/dhcpd_leases` until it runs out,
  about an hour going by the expiry it is listed with. Once all
  machines have stopped and the network is made anew, the same machine gets its reserved address, and for
  the first seconds of every start, until it answers on the SSH port, the app listed it at the old one.
  `ssh` right after a resume went to an address nobody holds.
- **With the agent** the app is told. The address monitor takes the agent's word as soon as it is
  connected, looks again the moment the agent reports a change, and while the guest holds no address (its
  cable is out, or it is still asking) lists it where it was last known to be for certain, or at its
  reserved address. Checked with such leases present for two machines: at the moment the agent connected
  and one second later both were listed where they really were, and `ssh` worked right after a resume.
- **Without the agent** the first seconds of a start are as before.

## Debian's cloud image can't be resumed, and sees no USB drives

- **Symptom:** a Debian 13 Quick Create machine suspends, and then fails to resume, every time:
  `The virtual machine failed to restore with error “invalid argument”.` The build from before this work
  does the same, so it is not the agent.
- **Cause:** the image (`debian-13-genericcloud-arm64`) boots a kernel made for cloud servers
  (`6.12…-cloud-arm64`) that has no driver for the display. In `/sys/bus/virtio/devices` the display
  device (ID `0x0010`) has no driver there, where Ubuntu has `virtio_gpu`. The same kernel has no USB
  storage driver: a plugged-in disc or disk image never shows up in `lsblk`.
- **Checked with:** `sudo apt install linux-image-arm64`, removing the cloud kernel and restarting. The
  display device then has its driver, the guest suspends and resumes (0.47 s), the agent is back and the
  clock right, and a plugged-in disc is there as `sda`.
- **Not done:** changing the catalog to Debian's `generic` image, which has the standard kernel. It is
  the fix, and a decision for the user: the download is larger, and existing machines stay as they are.

## A resumed guest with its cable out reports a lost network

- **Seen:** resuming a machine whose network cable had been pulled before it was suspended made
  `swiftvm start` fail with "Network disconnected … Internal Network Error", although the guest was
  running: the framework tells its delegate that the attachment was disconnected, which for a cable the
  user pulled is no news.
- **Fix:** the backend knows which cables are out and lets those reports pass.

## Quitting and opening the app at once left it without its control socket

- **Seen:** a copy of the app launched while the previous one was still on its way out ran, but
  `swiftvm` said the app wasn't running. The old copy removes the socket file when it has finished
  leaving, by its path, and by then the file was the new copy's.
- **Fix:** a server remembers which file it made (device and inode) and only removes that one.

## A restart can be over between two looks

- **Seen:** `swiftvm restart` returned after 90 s although the guest had been back for 85. It waited for
  the machine to be seen stopped, looking five times a second, and a guest that shuts down through the
  agent and starts again can do both between two looks.
- **Fix:** the machine counts its starts, and a restart waits for the next one.
