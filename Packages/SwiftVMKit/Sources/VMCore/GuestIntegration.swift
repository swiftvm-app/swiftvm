import Foundation
import GuestChannel

/// Where a guest's agent is told to find the shared folders, and where to put them.
public struct SharedFoldersPlace: Sendable, Hashable {
    /// The tag of a file-sharing device, or for a Windows guest the address of the folders over WebDAV.
    public var tag: String
    /// The folder to mount them at, or for a Windows guest the drive.
    public var mountPoint: String
    /// The folders with a device each, as a Linux guest on QEMU has them. Empty where one device
    /// carries them all.
    public var folders: [SharedFolderDevice]

    public init(tag: String, mountPoint: String, folders: [SharedFolderDevice] = []) {
        self.tag = tag
        self.mountPoint = mountPoint
        self.folders = folders
    }
}

/// Names shared between the host-side device configuration and guest-side setup.
public enum GuestIntegration {
    /// virtio-fs tag of the device that carries the machine's shared folders (Linux guests).
    public static let sharedFoldersTag = "swiftvm"
    /// Where Linux guests mount the shared folders; each folder appears as a subdirectory.
    public static let sharedFoldersMountPoint = "/mnt/shared"
    /// The drive Windows guests map the shared folders to; each folder appears as a folder on it.
    public static let windowsSharedFoldersDrive = "Z:"
    /// Mounts the shared folders in a Linux guest that SwiftVM didn't set up (an ISO install or live session).
    public static var linuxMountCommand: String {
        "sudo mkdir -p \(sharedFoldersMountPoint) && sudo mount -t virtiofs \(sharedFoldersTag) \(sharedFoldersMountPoint)"
    }

    /// Makes a Linux guest mount the shared folders at every start.
    public static var linuxPersistentMountCommand: String {
        "echo '\(sharedFoldersTag) \(sharedFoldersMountPoint) virtiofs rw,nofail 0 0' | sudo tee -a /etc/fstab"
    }

    /// The tag of a shared folder's own 9p device, in a Linux guest on QEMU, which has a device for each
    /// folder. It comes from the folder's identifier, so that a folder keeps its tag whatever is shared
    /// besides it. QEMU takes 31 characters at most.
    public static func folderDeviceTag(for folder: SharedFolder) -> String {
        "swiftvm-" + folder.id.uuidString.lowercased().prefix(8)
    }

    /// The folders of a Linux guest on QEMU, each with its device and the name it has in the guest.
    /// Two of the same name are told apart by a number.
    public static func folderDevices(of folders: [SharedFolder]) -> [SharedFolderDevice] {
        var taken: Set<String> = []
        return folders.map { folder in
            // A name is one folder's, printable, and short enough for any file system.
            let printable = String(String.UnicodeScalarView(folder.name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            let cleaned = String(printable.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            let base = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Shared" : cleaned
            var name = base
            var counter = 2
            while taken.contains(name) {
                name = "\(base) \(counter)"
                counter += 1
            }
            taken.insert(name)
            return SharedFolderDevice(tag: folderDeviceTag(for: folder), name: name, readOnly: folder.readOnly)
        }
    }

    /// What a guest has to do before it can use space that was added to its disk.
    public static func diskGrowthNote(for configuration: VMConfiguration) -> String {
        switch configuration.os.family {
        case .linux where configuration.installation.attachesSeedImage:
            "This system grows into the new space by itself the next time it starts."
        case .linux:
            "Afterwards, grow the partition and the file system inside the guest, for example with growpart and resize2fs."
        case .macOS:
            // The recovery system sits right behind the startup volume and macOS won't move or remove it.
            "macOS can't grow its startup volume into the new space. Afterwards, add a volume there with Disk Utility in the guest."
        case .windows:
            "Afterwards, extend the volume inside the guest in Disk Management."
        }
    }

    /// Where a Linux guest writes down everything its setup script prints.
    public static let setupLogPath = "/var/log/swiftvm-setup.log"
    /// What a person runs in a Linux guest to have a setup script that failed run again.
    public static let setupRetryCommand = "sudo systemctl start swiftvm-setup"

    /// virtio-fs tag of the Rosetta share.
    public static let rosettaTag = "rosetta"
    public static let rosettaMountPoint = "/media/rosetta"
}
