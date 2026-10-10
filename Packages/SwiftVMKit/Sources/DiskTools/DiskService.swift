import DiskImageKit
import Foundation
import VMCore

/// Creates and resizes the disk images inside a machine bundle.
public enum DiskService {
    public enum DiskError: Error, LocalizedError {
        case capacityTooSmall
        case cannotShrink(current: UInt64, requested: UInt64)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .capacityTooSmall:
                "The disk size is too small."
            case .cannotShrink(let current, let requested):
                "A disk can't be made smaller (\(current) → \(requested) bytes)."
            case .io(let reason):
                reason
            }
        }
    }

    static let blockSize = 512

    /// Creates an empty sparse disk image of the given virtual size.
    public static func createBlankDisk(at url: URL, capacity: UInt64, format: DiskConfiguration.Format) throws {
        guard capacity >= 1 << 20 else { throw DiskError.capacityTooSmall }
        switch format {
        case .asif:
            let blockCount = Int(capacity / UInt64(blockSize))
            _ = try DiskImage(creating: .asif(url: url, blockCount: blockCount, blockSize: .bytes512))
        case .raw:
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw DiskError.io("Couldn't create \(url.lastPathComponent).")
            }
            try setRawImageSize(at: url, to: capacity)
        }
    }

    /// Grows a raw image to `capacity` bytes. The added space is sparse.
    public static func growRawImage(at url: URL, to capacity: UInt64) throws {
        let current = try fileSize(of: url)
        guard capacity >= current else {
            throw DiskError.cannotShrink(current: current, requested: capacity)
        }
        guard capacity > current else { return }
        try setRawImageSize(at: url, to: capacity)
    }

    /// Grows the image at `url` to `capacity` bytes. The added space is sparse and costs nothing on the host
    /// until the guest uses it. The machine the disk belongs to must be shut down.
    public static func growDisk(at url: URL, format: DiskConfiguration.Format, to capacity: UInt64) throws {
        switch format {
        case .raw:
            try growRawImage(at: url, to: capacity)
        case .asif:
            let image = try DiskImage(opening: .open(url: url, mode: .readWrite))
            let current = UInt64(image.size)
            guard capacity >= current else {
                throw DiskError.cannotShrink(current: current, requested: capacity)
            }
            guard capacity > current, image.blockCount > 0 else { return }
            let bytesPerBlock = current / UInt64(image.blockCount)
            try image.truncate(blockCount: Int((capacity + bytesPerBlock - 1) / bytesPerBlock))
        }
    }

    /// Virtual size in bytes of the image at `url`.
    public static func capacity(of url: URL, format: DiskConfiguration.Format) throws -> UInt64 {
        switch format {
        case .asif:
            let image = try DiskImage(opening: .open(url: url, mode: .readOnly))
            return UInt64(image.size)
        case .raw:
            return try fileSize(of: url)
        }
    }

    /// Current size of the file on disk. Read through `FileManager` because `URL` caches resource values.
    public static func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func setRawImageSize(at url: URL, to capacity: UInt64) throws {
        // Round up to a whole number of blocks.
        let block = UInt64(blockSize)
        let rounded = (capacity + block - 1) / block * block
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else {
            throw DiskError.io("Couldn't open \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(rounded)) == 0 else {
            throw DiskError.io("Couldn't resize \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }
}
