import Foundation
import VMCore

/// Puts a Linux guest's clock right over SSH after it has been resumed.
///
/// A guest that is resumed from saved memory carries on believing it is still the moment it was suspended:
/// a few seconds ago, or last week if it comes from a snapshot. Its time service only nudges the clock
/// towards the truth, which can take days. The guest's hardware clock, however, is the host's clock, so
/// setting the system time from it fixes this at once.
public enum GuestClock {
    /// The `ssh` arguments that set the system time of `alias` from its hardware clock. Needs key sign-in
    /// and `sudo` without a password, which guests set up by SwiftVM have.
    static func arguments(alias: String, configURL: URL) -> [String] {
        [
            "-F", configURL.path,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            alias,
            "sudo -n hwclock --hctosys",
        ]
    }

    /// Blocks until `ssh` exits; call it off the main thread. Throws when the guest can't be reached or
    /// doesn't allow it.
    public static func setFromHardwareClock(on alias: String, configURL: URL) throws {
        try ProcessRunner.run("/usr/bin/ssh", arguments(alias: alias, configURL: configURL))
    }
}
