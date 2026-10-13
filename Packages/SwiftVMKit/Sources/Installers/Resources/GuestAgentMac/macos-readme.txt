SwiftVM Guest Tools for macOS

One small program, the guest agent, that lets the SwiftVM app on your Mac see this system's
version and addresses, share the clipboard with it, set its clock and time zone, and shut it down
without a question on its screen. With it, the swiftvm command on your Mac can also run commands
here, copy files, see the screen, and use the mouse and the keyboard.

To install, run this in Terminal in the virtual machine:

    @@command@@

macOS then says that a background item was added. That is the agent.

Before the swiftvm command can read what is on this Mac's screen as a tree of its parts, macOS
wants that allowed. On your Mac, this does it:

    swiftvm allow-accessibility <machine> --password <this account's password>

Or turn on swiftvm-agent here, in System Settings, under Privacy & Security, for Device Control
and Data Access, which earlier versions of macOS call Accessibility.

To remove the tools again:

    sudo sh /usr/local/lib/swiftvm/install.sh --remove

Afterwards you can eject this disc from the virtual machine's window on the Mac.
