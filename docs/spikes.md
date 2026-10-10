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
