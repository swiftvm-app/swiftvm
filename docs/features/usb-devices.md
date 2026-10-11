# USB Devices

SwiftVM can hand a USB device of your Mac to a running guest: a drive, a
security key, a serial adapter. The guest sees the real device and uses its own
driver for it.

USB devices need a build with a provisioning profile. Releases have one. If
you build SwiftVM yourself, see [Building](../tech/building.md#usb-devices).

## Give the device to SwiftVM

Which app uses a USB device is decided in macOS, not in SwiftVM. While SwiftVM
runs, the menu bar has a **Virtual Machine Accessories** menu that lists your
Mac's USB devices, each used with **This Mac** or with an app.

Set a device to SwiftVM there. macOS remembers the choice.

## Attach it to a machine

Open **USB Devices** in the machine's toolbar and turn the device on, or use
the command line:

```bash
swiftvm usb                                    # the devices SwiftVM has
swiftvm usb attach web-server "SanDisk Ultra"
swiftvm usb detach web-server "SanDisk Ultra"
```

Name a device by its name, its `vendor:product`, its serial number, or its
number in the list.

## Attach it automatically

Turn on **Attach whenever it is plugged in**, or run:

```bash
swiftvm usb auto web-server 0781:5581 on
```

The machine then takes the device by itself whenever both are there.

- The rule goes by the device's make, so two sticks of the same model are one
  to it.
- A device you detach by hand is left alone until it is plugged in again or
  the machine starts again.
- When two running machines would take the same device, it goes to the one
  that had it last.
- A [copy](virtual-machines.md#duplicating) of a machine takes none by itself
  until you say so.

## Good to know

- An attached device is gone from your Mac until it is detached or pulled out,
  or the machine stops.
- A device belongs to one guest at a time.
- Detaching is like pulling the device out of the guest. Eject a drive in the
  guest first.
- Suspending a machine gives its devices back to your Mac. The guest finds
  them unplugged when it resumes, so eject drives in the guest before you
  suspend.
- A running machine with a USB device can't be
  [snapshotted](snapshots.md). Detach the device or shut the machine down
  first.
