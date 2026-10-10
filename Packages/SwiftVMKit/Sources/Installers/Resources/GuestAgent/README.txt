SwiftVM Guest Tools for Linux

One small program, the guest agent, that lets the SwiftVM app on your Mac see this system's
version and addresses, set its clock after the virtual machine was suspended, mount the folders
you share with it under /mnt/shared, and shut it down. It needs systemd and Python 3, which
nearly every Linux system has, and nothing else.

To install, run this in a terminal in the virtual machine:

    @@command@@

To remove the tools again:

    sudo sh /usr/local/lib/swiftvm/install.sh --remove

Afterwards you can eject this disc from the virtual machine's window on the Mac.
