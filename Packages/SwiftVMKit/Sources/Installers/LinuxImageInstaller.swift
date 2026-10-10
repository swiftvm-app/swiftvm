import DiskTools
import Foundation
import VMCore

/// Turns a downloaded Linux cloud image into a machine's system disk.
public enum LinuxImageInstaller {
    public enum InstallError: Error, LocalizedError {
        case imageLargerThanDisk(imageSize: UInt64, capacity: UInt64)

        public var errorDescription: String? {
            switch self {
            case .imageLargerThanDisk(let imageSize, let capacity):
                "The image needs \(imageSize) bytes but the disk is only \(capacity) bytes."
            }
        }
    }

    /// Writes `image` (QCOW2 or raw) as a sparse raw disk of `capacity` bytes at `destination`.
    ///
    /// The guest grows its root partition into the extra space on first boot.
    public static func install(
        image: URL,
        to destination: URL,
        capacity: UInt64,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)

        if QCOW2Image.isQCOW2(at: image) {
            let qcow = try QCOW2Image(url: image)
            guard qcow.virtualSize <= capacity else {
                throw InstallError.imageLargerThanDisk(imageSize: qcow.virtualSize, capacity: capacity)
            }
            try qcow.convertToRaw(at: destination, progress: progress)
        } else {
            let size = try DiskService.fileSize(of: image)
            guard size <= capacity else {
                throw InstallError.imageLargerThanDisk(imageSize: size, capacity: capacity)
            }
            // APFS clones the file, so this is instant and shares storage with the cached download.
            try fileManager.copyItem(at: image, to: destination)
            progress?(1)
        }
        try DiskService.growRawImage(at: destination, to: capacity)
    }
}
