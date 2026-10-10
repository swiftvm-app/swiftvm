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
  download over. Resume data is kept in memory only, so quitting the app still loses a partial download.

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
  hypervisor console). Kernel messages don't go there: the cloud image boots with
  `console=tty1 console=ttyAMA0`.
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
