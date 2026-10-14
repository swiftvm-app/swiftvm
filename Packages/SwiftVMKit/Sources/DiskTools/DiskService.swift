import DiskImageKit
import Foundation
import os
import VMCore

/// Creates and resizes the disk images inside a machine bundle.
public enum DiskService {
    public enum DiskError: Error, LocalizedError {
        case capacityTooSmall
        case cannotShrink(current: UInt64, requested: UInt64)
        case cannotConvert(from: DiskConfiguration.Format, to: DiskConfiguration.Format)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .capacityTooSmall:
                "The disk size is too small."
            case .cannotShrink(let current, let requested):
                "A disk can't be made smaller (\(current) → \(requested) bytes)."
            case .cannotConvert(let from, let to):
                "A disk can't be converted from \(from.rawValue) to \(to.rawValue)."
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
        case .compressed:
            try CompressedDisk.create(at: url, capacity: roundedToBlocks(capacity))
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
        case .compressed:
            let disk = try CompressedDisk(url: url)
            do {
                guard capacity >= disk.capacity else {
                    throw DiskError.cannotShrink(current: disk.capacity, requested: capacity)
                }
                try disk.grow(to: roundedToBlocks(capacity))
            } catch {
                try? disk.close()
                throw error
            }
            try disk.close()
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
        case .compressed:
            return try CompressedDisk.capacity(of: url)
        case .raw:
            return try fileSize(of: url)
        }
    }

    // MARK: Converting

    /// Writes what the disk at `source` holds into a new disk at `destination`, in another format:
    /// raw into compressed, or back. The new disk is in its file for good when this returns, and gone
    /// again if it doesn't get that far. The machine the disk belongs to must be shut down.
    ///
    /// - Parameters:
    ///   - progress: Called on the converting threads with how far it has come, from 0 to 1.
    ///   - isCancelled: Asked while converting. Once it says yes the work stops with a `CancellationError`.
    public static func convertDisk(
        at source: URL, format: DiskConfiguration.Format, to destination: URL, format newFormat: DiskConfiguration.Format,
        progress: (@Sendable (Double) -> Void)? = nil, isCancelled: @Sendable () -> Bool = { false }
    ) throws {
        do {
            switch (format, newFormat) {
            case (.raw, .compressed):
                try compress(rawImageAt: source, to: destination, progress: progress, isCancelled: isCancelled)
            case (.compressed, .raw):
                try expand(compressedDiskAt: source, to: destination, progress: progress, isCancelled: isCancelled)
            default:
                throw DiskError.cannotConvert(from: format, to: newFormat)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// How much is read and written in one go, by each of the threads that share the work.
    private static let pieceSize = 4 << 20

    private static func compress(
        rawImageAt source: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?, isCancelled: @Sendable () -> Bool
    ) throws {
        let descriptor = open(source.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw DiskError.io("Couldn't open \(source.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        let size = UInt64(lseek(descriptor, 0, SEEK_END))

        // Only what the image holds is read: the empty space of a sparse image stays out of it.
        var ranges: [Range<UInt64>] = []
        var position: off_t = 0
        while UInt64(position) < size {
            let data = lseek(descriptor, position, SEEK_DATA)
            guard data >= 0 else {
                // Past the last of the data. Anything else means that the file system can't say where
                // an image holds something, and then all of the rest is taken to.
                if errno != ENXIO { ranges.append(UInt64(position)..<size) }
                break
            }
            var hole = lseek(descriptor, data, SEEK_HOLE)
            if hole <= data { hole = off_t(size) }
            ranges.append(UInt64(data)..<UInt64(hole))
            position = hole
        }

        try CompressedDisk.create(at: destination, capacity: roundedToBlocks(size))
        let disk = try CompressedDisk(url: destination)
        do {
            try copy(pieces(of: ranges), progress: progress, isCancelled: isCancelled) { piece, buffer in
                let count = Int(piece.upperBound - piece.lowerBound)
                var done = 0
                while done < count {
                    let got = pread(descriptor, buffer + done, count - done, off_t(piece.lowerBound) + off_t(done))
                    if got < 0, errno == EINTR { continue }
                    guard got > 0 else {
                        throw DiskError.io("Couldn't read \(source.lastPathComponent): \(got < 0 ? String(cString: strerror(errno)) : "it is cut short")")
                    }
                    done += got
                }
                try disk.write(at: piece.lowerBound, from: UnsafeRawBufferPointer(start: buffer, count: count))
            }
        } catch {
            try? disk.close()
            throw error
        }
        try disk.close()
    }

    private static func expand(
        compressedDiskAt source: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?, isCancelled: @Sendable () -> Bool
    ) throws {
        let disk = try CompressedDisk(url: source, readOnly: true)
        defer { try? disk.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DiskError.io("Couldn't create \(destination.lastPathComponent).")
        }
        try setRawImageSize(at: destination, to: disk.capacity)
        let descriptor = open(destination.path, O_WRONLY)
        guard descriptor >= 0 else {
            throw DiskError.io("Couldn't open \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        let stored = disk.storedRanges()
        try copy(pieces(of: stored), progress: progress, isCancelled: isCancelled) { piece, buffer in
            let count = Int(piece.upperBound - piece.lowerBound)
            try disk.read(at: piece.lowerBound, into: UnsafeMutableRawBufferPointer(start: buffer, count: count))
            var done = 0
            while done < count {
                let put = pwrite(descriptor, buffer + done, count - done, off_t(piece.lowerBound) + off_t(done))
                if put < 0, errno == EINTR { continue }
                guard put > 0 else {
                    throw DiskError.io("Couldn't write \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
                }
                done += put
            }
        }
        // The original is about to be removed.
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw DiskError.io("Couldn't finish \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        // APFS has filled the smaller gaps between what was written by now: it only keeps space empty
        // that is large, or that it is told to let go of. So it is told, for all that the disk doesn't hold.
        let block: UInt64 = 4096
        var gapStart: UInt64 = 0
        for range in stored + [disk.capacity..<disk.capacity] {
            let end = range.lowerBound / block * block
            if end > gapStart {
                var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(gapStart), fp_length: off_t(end - gapStart))
                _ = fcntl(descriptor, F_PUNCHHOLE, &hole)
            }
            gapStart = (range.upperBound + block - 1) / block * block
        }
        _ = fcntl(descriptor, F_FULLFSYNC)
    }

    /// Cuts `ranges` into pieces of at most ``pieceSize``. Inside a range they begin where a compressed
    /// disk's clusters do, so that a cluster is written once, as a whole.
    private static func pieces(of ranges: [Range<UInt64>]) -> [Range<UInt64>] {
        let size = UInt64(pieceSize)
        var pieces: [Range<UInt64>] = []
        for range in ranges {
            var start = range.lowerBound
            while start < range.upperBound {
                let end = min((start / size + 1) * size, range.upperBound)
                pieces.append(start..<end)
                start = end
            }
        }
        return pieces
    }

    /// Runs `body` for every piece, on as many threads as the Mac has cores, each with a buffer of its own.
    private static func copy(
        _ pieces: [Range<UInt64>], progress: (@Sendable (Double) -> Void)?, isCancelled: @Sendable () -> Bool,
        _ body: @Sendable (Range<UInt64>, UnsafeMutableRawPointer) throws -> Void
    ) throws {
        struct Outcome {
            var next = 0
            var done: UInt64 = 0
            var failure: (any Error)?
        }
        let total = max(pieces.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) }, 1)
        let outcome = OSAllocatedUnfairLock(uncheckedState: Outcome())
        DispatchQueue.concurrentPerform(iterations: ProcessInfo.processInfo.activeProcessorCount) { _ in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: pieceSize, alignment: 16384)
            defer { buffer.deallocate() }
            while true {
                let index: Int? = outcome.withLockUnchecked { outcome in
                    guard outcome.failure == nil, outcome.next < pieces.count else { return nil }
                    outcome.next += 1
                    return outcome.next - 1
                }
                guard let index else { return }
                do {
                    if isCancelled() { throw CancellationError() }
                    try body(pieces[index], buffer)
                    let piece = pieces[index]
                    let done = outcome.withLockUnchecked { outcome in
                        outcome.done += piece.upperBound - piece.lowerBound
                        return outcome.done
                    }
                    progress?(Double(done) / Double(total))
                } catch {
                    outcome.withLockUnchecked { $0.failure = $0.failure ?? error }
                    return
                }
            }
        }
        if let failure = outcome.withLockUnchecked({ $0.failure }) { throw failure }
    }

    /// A guest counts a disk in blocks of 512 bytes.
    private static func roundedToBlocks(_ capacity: UInt64) -> UInt64 {
        let block = UInt64(blockSize)
        return (capacity + block - 1) / block * block
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
