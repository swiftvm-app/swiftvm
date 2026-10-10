import Compression
import Foundation

/// Reads a QCOW2 disk image (the format most Linux cloud images ship in) and converts it to a raw image.
///
/// Supports versions 2 and 3 with zlib-compressed clusters. Images that depend on a backing file, an
/// external data file, encryption, extended L2 entries or zstd compression are rejected.
public struct QCOW2Image: Sendable {
    public enum FormatError: Error, LocalizedError, Equatable {
        case notQCOW2
        case unsupportedVersion(UInt32)
        case unsupportedFeature(String)
        case corrupt(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .notQCOW2: "The file isn't a QCOW2 disk image."
            case .unsupportedVersion(let version): "QCOW2 version \(version) isn't supported."
            case .unsupportedFeature(let feature): "This QCOW2 image uses \(feature), which isn't supported."
            case .corrupt(let reason): "The QCOW2 image is damaged: \(reason)."
            case .io(let reason): reason
            }
        }
    }

    static let magic: UInt32 = 0x5146_49FB  // "QFI\xfb"

    public let url: URL
    /// Size of the virtual disk in bytes.
    public let virtualSize: UInt64
    let clusterBits: Int
    let l1Size: Int
    let l1TableOffset: UInt64

    var clusterSize: Int { 1 << clusterBits }

    /// Whether the file at `url` starts with the QCOW2 magic number.
    public static func isQCOW2(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data.readBigEndian(UInt32.self, at: 0) == magic
    }

    public init(url: URL) throws {
        self.url = url
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FormatError.io("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 112), header.count >= 72 else {
            throw FormatError.notQCOW2
        }
        guard header.readBigEndian(UInt32.self, at: 0) == Self.magic else {
            throw FormatError.notQCOW2
        }
        let version = header.readBigEndian(UInt32.self, at: 4)
        guard version == 2 || version == 3 else {
            throw FormatError.unsupportedVersion(version)
        }
        guard header.readBigEndian(UInt64.self, at: 8) == 0 else {
            throw FormatError.unsupportedFeature("a backing file")
        }
        let clusterBits = Int(header.readBigEndian(UInt32.self, at: 20))
        guard (9...21).contains(clusterBits) else {
            throw FormatError.corrupt("invalid cluster size")
        }
        guard header.readBigEndian(UInt32.self, at: 32) == 0 else {
            throw FormatError.unsupportedFeature("encryption")
        }
        if version == 3 {
            guard header.count >= 104 else { throw FormatError.corrupt("truncated header") }
            let incompatible = header.readBigEndian(UInt64.self, at: 72)
            if incompatible & (1 << 2) != 0 { throw FormatError.unsupportedFeature("an external data file") }
            if incompatible & (1 << 4) != 0 { throw FormatError.unsupportedFeature("extended L2 entries") }
            if incompatible & (1 << 3) != 0 {
                let headerLength = Int(header.readBigEndian(UInt32.self, at: 100))
                let compressionType = headerLength > 104 && header.count > 104 ? header[header.startIndex + 104] : 0
                if compressionType != 0 { throw FormatError.unsupportedFeature("zstd compression") }
            }
            let known: UInt64 = 0b11111
            if incompatible & ~known != 0 { throw FormatError.unsupportedFeature("an unknown incompatible feature") }
        }
        self.clusterBits = clusterBits
        self.virtualSize = header.readBigEndian(UInt64.self, at: 24)
        self.l1Size = Int(header.readBigEndian(UInt32.self, at: 36))
        self.l1TableOffset = header.readBigEndian(UInt64.self, at: 40)
    }

    /// Writes the image's contents as a sparse raw image at `destination`.
    ///
    /// - Parameter progress: Called with a fraction between 0 and 1 as conversion advances.
    public func convertToRaw(at destination: URL, progress: (@Sendable (Double) -> Void)? = nil) throws {
        let source = open(url.path, O_RDONLY)
        guard source >= 0 else {
            throw FormatError.io("Couldn't open \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(source) }

        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else {
            throw FormatError.io("Couldn't create \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(output) }
        guard ftruncate(output, off_t(virtualSize)) == 0 else {
            throw FormatError.io("Couldn't size \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }

        let clusterSize = self.clusterSize
        let l2EntryCount = clusterSize / 8
        let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
        let compressedFlag: UInt64 = 1 << 62
        let zeroFlag: UInt64 = 1

        // Compressed cluster descriptor layout depends on the cluster size.
        let offsetBits = UInt64(62 - (clusterBits - 8))
        let compressedOffsetMask: UInt64 = (1 << offsetBits) - 1
        let sectorCountMask: UInt64 = (1 << UInt64(clusterBits - 8)) - 1

        let l1Table = try Self.read(source, offset: l1TableOffset, count: l1Size * 8)
        var cluster = [UInt8](repeating: 0, count: clusterSize)
        var compressed = [UInt8](repeating: 0, count: clusterSize + 1024)

        for l1Index in 0..<l1Size {
            progress?(Double(l1Index) / Double(max(l1Size, 1)))
            let l2Offset = l1Table.readBigEndian(UInt64.self, at: l1Index * 8) & offsetMask
            guard l2Offset != 0 else { continue }
            let l2Table = try Self.read(source, offset: l2Offset, count: clusterSize)

            for l2Index in 0..<l2EntryCount {
                let entry = l2Table.readBigEndian(UInt64.self, at: l2Index * 8)
                guard entry != 0 else { continue }
                let guestOffset = (UInt64(l1Index) * UInt64(l2EntryCount) + UInt64(l2Index)) << UInt64(clusterBits)
                guard guestOffset < virtualSize else { continue }
                let length = Int(min(UInt64(clusterSize), virtualSize - guestOffset))

                if entry & compressedFlag != 0 {
                    let hostOffset = entry & compressedOffsetMask
                    let sectors = (entry >> offsetBits) & sectorCountMask
                    let compressedLength = Int((sectors + 1) * 512 - (hostOffset & 511))
                    guard compressedLength <= compressed.count else {
                        throw FormatError.corrupt("oversized compressed cluster")
                    }
                    let readCount = compressed.withUnsafeMutableBytes { pread(source, $0.baseAddress, compressedLength, off_t(hostOffset)) }
                    guard readCount > 0 else { throw FormatError.corrupt("unreadable compressed cluster") }
                    let decoded = cluster.withUnsafeMutableBufferPointer { destinationBuffer in
                        compressed.withUnsafeBufferPointer { sourceBuffer in
                            compression_decode_buffer(
                                destinationBuffer.baseAddress!, clusterSize,
                                sourceBuffer.baseAddress!, readCount,
                                nil, COMPRESSION_ZLIB
                            )
                        }
                    }
                    guard decoded == clusterSize else {
                        throw FormatError.corrupt("compressed cluster didn't decode")
                    }
                } else {
                    if entry & zeroFlag != 0 { continue }
                    let hostOffset = entry & offsetMask
                    guard hostOffset != 0 else { continue }
                    let readCount = cluster.withUnsafeMutableBytes { pread(source, $0.baseAddress, clusterSize, off_t(hostOffset)) }
                    guard readCount == clusterSize else { throw FormatError.corrupt("truncated data cluster") }
                }

                // Leave all-zero clusters as holes so the raw image stays sparse.
                if cluster.allSatisfy({ $0 == 0 }) { continue }
                let written = cluster.withUnsafeBytes { pwrite(output, $0.baseAddress, length, off_t(guestOffset)) }
                guard written == length else {
                    throw FormatError.io("Couldn't write \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
                }
            }
        }
        progress?(1)
    }

    private static func read(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        guard readCount == count else { throw FormatError.corrupt("truncated metadata table") }
        return data
    }
}

extension Data {
    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        let size = MemoryLayout<T>.size
        precondition(offset + size <= count, "read past end of data")
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: (startIndex + offset)..<(startIndex + offset + size))
        }
        return T(bigEndian: value)
    }
}
