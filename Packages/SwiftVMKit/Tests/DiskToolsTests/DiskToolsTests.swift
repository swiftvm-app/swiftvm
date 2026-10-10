import Compression
import Foundation
import Testing
import VMCore
@testable import DiskTools

/// Builds a small QCOW2 v3 image with one cluster of each kind the converter handles.
private enum QCOW2Fixture {
    static let clusterBits = 16
    static let clusterSize = 1 << clusterBits
    static let virtualSize = 4 * clusterSize

    static let plainCluster = Data((0..<clusterSize).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
    static let compressibleCluster = Data((0..<clusterSize).map { UInt8(truncatingIfNeeded: ($0 / 512) &+ 1) })

    static func make(at url: URL, backingFileOffset: UInt64 = 0) throws {
        var compressed = [UInt8](repeating: 0, count: clusterSize)
        let compressedLength = compressibleCluster.withUnsafeBytes { source in
            compression_encode_buffer(&compressed, compressed.count, source.bindMemory(to: UInt8.self).baseAddress!, clusterSize, nil, COMPRESSION_ZLIB)
        }
        precondition(compressedLength > 0 && compressedLength < clusterSize)

        var header = Data()
        header.appendBigEndian(UInt32(0x5146_49FB))             // magic
        header.appendBigEndian(UInt32(3))                       // version
        header.appendBigEndian(backingFileOffset)               // backing file offset
        header.appendBigEndian(UInt32(0))                       // backing file size
        header.appendBigEndian(UInt32(clusterBits))
        header.appendBigEndian(UInt64(virtualSize))
        header.appendBigEndian(UInt32(0))                       // crypt method
        header.appendBigEndian(UInt32(1))                       // L1 size
        header.appendBigEndian(UInt64(1 * clusterSize))         // L1 table offset
        header.appendBigEndian(UInt64(0))                       // refcount table offset
        header.appendBigEndian(UInt32(0))                       // refcount table clusters
        header.appendBigEndian(UInt32(0))                       // snapshot count
        header.appendBigEndian(UInt64(0))                       // snapshots offset
        header.appendBigEndian(UInt64(0))                       // incompatible features
        header.appendBigEndian(UInt64(0))                       // compatible features
        header.appendBigEndian(UInt64(0))                       // autoclear features
        header.appendBigEndian(UInt32(4))                       // refcount order
        header.appendBigEndian(UInt32(104))                     // header length

        let copied: UInt64 = 1 << 63
        var l1 = Data()
        l1.appendBigEndian(UInt64(2 * clusterSize) | copied)

        let compressedOffset = UInt64(4 * clusterSize)
        let offsetBits = UInt64(62 - (clusterBits - 8))
        let additionalSectors = UInt64((compressedLength + 511) / 512 - 1)
        var l2 = Data()
        l2.appendBigEndian(UInt64(3 * clusterSize) | copied)                                // guest cluster 0: plain data
        l2.appendBigEndian(UInt64(0))                                                       // guest cluster 1: unallocated
        l2.appendBigEndian((UInt64(1) << 62) | (additionalSectors << offsetBits) | compressedOffset)  // guest cluster 2: compressed
        l2.appendBigEndian(UInt64(1))                                                       // guest cluster 3: reads as zeros

        var file = Data()
        file.append(header.padded(to: clusterSize))
        file.append(l1.padded(to: clusterSize))
        file.append(l2.padded(to: clusterSize))
        file.append(plainCluster)
        file.append(Data(compressed[..<compressedLength]).padded(to: clusterSize))
        try file.write(to: url)
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func padded(to length: Int) -> Data {
        self + Data(count: Swift.max(0, length - count))
    }
}

@Suite struct QCOW2ImageTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-qcow2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func convertsEveryClusterKind() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "image.qcow2")
        let destination = directory.appending(path: "image.raw")
        try QCOW2Fixture.make(at: source)

        #expect(QCOW2Image.isQCOW2(at: source))
        let image = try QCOW2Image(url: source)
        #expect(image.virtualSize == UInt64(QCOW2Fixture.virtualSize))
        try image.convertToRaw(at: destination)

        let raw = try Data(contentsOf: destination)
        let size = QCOW2Fixture.clusterSize
        #expect(raw.count == QCOW2Fixture.virtualSize)
        #expect(raw[0..<size] == QCOW2Fixture.plainCluster)
        #expect(raw[size..<(2 * size)] == Data(count: size))
        #expect(raw[(2 * size)..<(3 * size)] == QCOW2Fixture.compressibleCluster)
        #expect(raw[(3 * size)..<(4 * size)] == Data(count: size))
    }

    @Test func rejectsOtherFilesAndBackingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = directory.appending(path: "plain.img")
        try Data(count: 4096).write(to: plain)
        #expect(!QCOW2Image.isQCOW2(at: plain))
        #expect(throws: QCOW2Image.FormatError.notQCOW2) { try QCOW2Image(url: plain) }

        let backed = directory.appending(path: "backed.qcow2")
        try QCOW2Fixture.make(at: backed, backingFileOffset: 200)
        #expect(throws: QCOW2Image.FormatError.unsupportedFeature("a backing file")) { try QCOW2Image(url: backed) }
    }
}

@Suite struct DiskServiceTests {
    @Test func createsSparseRawDiskAndGrowsIt() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-disk-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        let gibibyte: UInt64 = 1 << 30
        try DiskService.createBlankDisk(at: url, capacity: gibibyte, format: .raw)
        #expect(try DiskService.capacity(of: url, format: .raw) == gibibyte)
        let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        #expect(allocated < 1 << 20)

        try DiskService.growRawImage(at: url, to: 2 * gibibyte)
        #expect(try DiskService.capacity(of: url, format: .raw) == 2 * gibibyte)
        #expect(throws: DiskService.DiskError.self) { try DiskService.growRawImage(at: url, to: gibibyte) }
    }

    @Test func createsSparseASIFDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-disk-\(UUID().uuidString).asif")
        defer { try? FileManager.default.removeItem(at: url) }
        let capacity: UInt64 = 64 << 30
        try DiskService.createBlankDisk(at: url, capacity: capacity, format: .asif)
        #expect(try DiskService.capacity(of: url, format: .asif) == capacity)
        let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        #expect(allocated < 64 << 20)
    }

    @Test func growsDisksOfBothFormats() throws {
        let gibibyte: UInt64 = 1 << 30
        for format in [DiskConfiguration.Format.raw, .asif] {
            let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-disk-\(UUID().uuidString).\(format.rawValue)")
            defer { try? FileManager.default.removeItem(at: url) }
            try DiskService.createBlankDisk(at: url, capacity: 2 * gibibyte, format: format)

            try DiskService.growDisk(at: url, format: format, to: 8 * gibibyte)
            #expect(try DiskService.capacity(of: url, format: format) == 8 * gibibyte)
            let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
            #expect(allocated < 64 << 20)

            // Asking for the size it already has is fine; asking for less is refused.
            try DiskService.growDisk(at: url, format: format, to: 8 * gibibyte)
            #expect(throws: DiskService.DiskError.self) { try DiskService.growDisk(at: url, format: format, to: 4 * gibibyte) }
            #expect(try DiskService.capacity(of: url, format: format) == 8 * gibibyte)
        }
    }
}

@Suite struct ISOImageBuilderTests {
    @Test func buildsLabelledISO() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-seed-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try ISOImageBuilder.makeISO(
            volumeName: "cidata",
            files: ["meta-data": Data("instance-id: test\n".utf8), "user-data": Data("#cloud-config\n".utf8)],
            at: url
        )
        let data = try Data(contentsOf: url)
        // The primary volume descriptor starts at sector 16: type 1, then "CD001".
        let descriptor = 16 * 2048
        #expect(String(decoding: data[(descriptor + 1)..<(descriptor + 6)], as: UTF8.self) == "CD001")
        let label = String(decoding: data[(descriptor + 40)..<(descriptor + 72)], as: UTF8.self).trimmingCharacters(in: CharacterSet.whitespaces.union(.controlCharacters))
        #expect(label.lowercased() == "cidata")
    }
}
