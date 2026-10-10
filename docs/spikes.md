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
