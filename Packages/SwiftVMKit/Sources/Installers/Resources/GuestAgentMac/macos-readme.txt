SwiftVM Guest Tools for macOS

One small program, the guest agent, that lets the SwiftVM app on your Mac see this system's
version and addresses, share the clipboard with it, set its clock and time zone, and shut it down
without a question on its screen.

To install, run this in Terminal in the virtual machine:

    @@command@@

macOS then says that a background item was added. That is the agent.

To remove the tools again:

    sudo sh /usr/local/lib/swiftvm/install.sh --remove

Afterwards you can eject this disc from the virtual machine's window on the Mac.
