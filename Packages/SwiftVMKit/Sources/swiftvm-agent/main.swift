import Foundation
import GuestAgentMac

// swiftvm-agent: the SwiftVM guest agent for macOS guests. It runs inside a virtual machine, not on the
// Mac that runs SwiftVM, and is put there by the guest tools installer.

exit(AgentCommand.run(Array(CommandLine.arguments.dropFirst())))
