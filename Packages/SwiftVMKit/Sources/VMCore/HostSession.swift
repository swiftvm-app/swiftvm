import CoreGraphics
import Foundation

/// What the login session on this Mac is doing.
public enum HostSession {
    /// Whether the screen is locked.
    ///
    /// It matters because the Virtualization framework can't read a guest's saved memory back while it
    /// is: restoring fails with "permission denied" until the Mac is unlocked. Saving works either way.
    public static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
