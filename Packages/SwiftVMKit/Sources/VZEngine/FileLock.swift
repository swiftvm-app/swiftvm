import Foundation

/// The lock that Virtualization holds on a running machine's files, seen from outside.
enum FileLock {
    /// Waits until nobody holds a lock on the file at `url`, and says whether that happened within
    /// `timeout`. A file that can't be opened has no lock to wait for. Throws if the task is cancelled.
    static func waitUntilFree(_ url: URL, timeout: Duration, interval: Duration = .milliseconds(100)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            guard let isHeld = isHeld(url) else { return true }
            if !isHeld { return true }
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: interval)
        }
    }

    /// Whether another open file holds a lock on it, `nil` if it can't be opened.
    static func isHeld(_ url: URL) -> Bool? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // Taken and given back at once: only to learn whether it could be.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(descriptor, LOCK_UN)
        return false
    }
}
