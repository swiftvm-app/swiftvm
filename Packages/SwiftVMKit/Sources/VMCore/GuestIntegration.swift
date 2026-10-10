import Foundation

/// Names shared between the host-side device configuration and guest-side setup.
public enum GuestIntegration {
    /// virtio-fs tag of the device that carries the machine's shared folders (Linux guests).
    public static let sharedFoldersTag = "swiftvm"
    /// Where Linux guests mount the shared folders; each folder appears as a subdirectory.
    public static let sharedFoldersMountPoint = "/mnt/shared"
    /// Mounts the shared folders in a Linux guest that SwiftVM didn't set up (an ISO install or live session).
    public static var linuxMountCommand: String {
        "sudo mkdir -p \(sharedFoldersMountPoint) && sudo mount -t virtiofs \(sharedFoldersTag) \(sharedFoldersMountPoint)"
    }

    /// Makes a Linux guest mount the shared folders at every start.
    public static var linuxPersistentMountCommand: String {
        "echo '\(sharedFoldersTag) \(sharedFoldersMountPoint) virtiofs rw,nofail 0 0' | sudo tee -a /etc/fstab"
    }

    /// virtio-fs tag of the Rosetta share.
    public static let rosettaTag = "rosetta"
    public static let rosettaMountPoint = "/media/rosetta"
}
